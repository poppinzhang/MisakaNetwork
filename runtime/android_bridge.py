"""Serialized in-process client adapter for Android's embedded Python runtime.

The shared protocol and upstream interface functions are identical to desktop.
Only account, catalog, task-configuration and local QR-encoding operations are
allowed here; Sisters executes purchases on a remote machine.
"""
from __future__ import annotations

from contextlib import contextmanager, redirect_stderr, redirect_stdout
import importlib
import io
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
import threading
from typing import Any

import bridge

CLIENT_OPERATIONS = bridge.OPERATIONS - {"run"}
_LOCK = threading.Lock()


def load_client_engine(resources: list[Any]) -> Any:
    # Deployment stages the verified upstream source at the Python source root.
    # Catalog requests use the same standard HTTP/2 transport as desktop, even
    # though this client never imports or starts the buying engine.
    engine = importlib.import_module("interface")
    request_type = importlib.import_module("util.request.BiliRequest").BiliRequest

    initialize = request_type.__init__
    build_headers = request_type._build_h2_headers

    def tracked_init(self, *args, **kwargs):
        # Register before initialization so partial construction is cleaned up.
        resources.append(self)
        initialize(self, *args, **kwargs)

    def client_headers(self, **kwargs):
        headers = build_headers(self, **kwargs)
        # Android deliberately ships no native Brotli/Zstandard extensions.
        # Never advertise encodings which this dependency set cannot decode.
        headers["accept-encoding"] = "gzip, deflate"
        return headers

    request_type.__init__ = tracked_init
    request_type._build_h2_headers = client_headers
    main_request = sys.modules["util"].main_request
    resources.append(main_request)
    # Imports alone don't load lazy HTTP/2 dependencies or the CA bundle. Make
    # ping check the actual transport configuration, without making a request.
    main_request._h2_client = main_request._build_h2_client()
    import qrcode.image.pure
    import png
    return engine


def _is_upstream_module(name: str) -> bool:
    return name.split(".", 1)[0] in {"interface", "util", "task", "app_cmd", "app_version", "cptoken"}


def _collect_partial_requests(resources: list[Any], error: BaseException | None) -> None:
    # A failed import removes util from sys.modules; its traceback still owns
    # globals and partially constructed request instances which need closing.
    pending = [error] if error is not None else []
    visited: set[int] = set()
    requests = {id(request): request for request in resources}
    module = sys.modules.get("util")
    if module is not None and getattr(module, "main_request", None) is not None:
        requests[id(module.main_request)] = module.main_request
    while pending:
        current = pending.pop()
        if id(current) in visited:
            continue
        visited.add(id(current))
        pending.extend(nested for nested in (current.__cause__, current.__context__) if nested is not None)
        traceback = current.__traceback__
        while traceback is not None:
            frame = traceback.tb_frame
            name = frame.f_globals.get("__name__")
            request = None
            if name == "util":
                request = frame.f_globals.get("main_request")
            elif name == "util.request.BiliRequest":
                request = frame.f_locals.get("self")
            if request is not None:
                requests[id(request)] = request
            traceback = traceback.tb_next
    resources[:] = requests.values()


@contextmanager
def client_engine():
    """Give each serialized invocation fresh upstream state and close it all.

    Android keeps one interpreter alive. Upstream module globals otherwise keep
    the first request's deleted state directory and open databases forever.
    Restoring pre-existing modules also keeps this adapter isolated in tests or
    when another embedded consumer has imported the desktop engine.
    """
    previous = {name: module for name, module in list(sys.modules.items()) if _is_upstream_module(name)}
    for name in previous:
        sys.modules.pop(name, None)
    resources: list[Any] = []
    initialization_error = None
    try:
        try:
            engine = load_client_engine(resources)
        except BaseException as exc:
            initialization_error = exc
            raise
        yield engine
    finally:
        failed = False
        try:
            _collect_partial_requests(resources, initialization_error)
            for request in resources:
                for resource in (
                    getattr(request, "_h2_client", None),
                    getattr(request, "session", None),
                    getattr(getattr(request, "cookieManager", None), "db", None),
                ):
                    if resource is not None:
                        try:
                            resource.close()
                        except Exception:
                            failed = True
            try:
                # Also finds databases in tracebacks of partially failed imports.
                bridge.close_upstream_databases(initialization_error)
            except Exception:
                failed = True
        finally:
            for name in list(sys.modules):
                if _is_upstream_module(name):
                    sys.modules.pop(name, None)
            sys.modules.update(previous)
        if failed:
            raise RuntimeError("embedded client resource cleanup failed")


def _failure(code: str, message: str) -> str:
    return json.dumps({"type": "result", "ok": False, "error": {"code": code, "message": message}}, ensure_ascii=False)


def invoke(raw: str, cache_directory: str) -> str:
    """Return one JSON result, with no sensitive stdout, logcat or disk state."""
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > bridge.MAX_REQUEST_BYTES:
        return _failure("invalid_request", "请求为空或超过大小限制")
    try:
        request = bridge.read_request(io.BytesIO(raw.encode("utf-8")))
        # Unlike the JSONL process, the channel accepts exactly one JSON object.
        if json.loads(raw) != request:
            raise ValueError()
    except (bridge.BridgeError, ValueError, RecursionError):
        return _failure("invalid_request", "请求不是有效 JSON")
    if not isinstance(request, dict) or not isinstance(request.get("op"), str) or request["op"] not in CLIENT_OPERATIONS:
        return _failure("invalid_request", "Android 控制端不支持此操作")
    with _LOCK:
        try:
            cache = Path(cache_directory)
            if not cache.is_absolute() or not cache.is_dir():
                return _failure("runtime_unavailable", "应用私有缓存不可用")
            with tempfile.TemporaryDirectory(prefix="misaka-client-", dir=cache) as state:
                keys = {
                    "MISAKA_RUNTIME_STATE_DIR": state,
                    "BTB_CONFIG_PATH": str(Path(state) / "config.json"),
                    "BTB_COOKIES_PATH": str(Path(state) / "cookies.json"),
                    "BTB_LOG_DIR": str(Path(state) / "logs"),
                    "BTB_SKIP_INITIAL_TIME_SYNC": "1",
                    "GRADIO_TEMP_DIR": str(Path(state) / "tmp"),
                }
                previous = {key: os.environ.get(key) for key in keys}
                os.environ.update(keys)
                events: list[dict] = []
                disabled = logging.root.manager.disable
                logging.disable(logging.CRITICAL)
                try:
                    with open(os.devnull, "w") as sink, redirect_stdout(sink), redirect_stderr(sink):
                        # Loguru captures its initial sink at import time, so
                        # remove it before any upstream client module is loaded.
                        if request["op"] == "payment_qr":
                            bridge.process_request(request, None, events.append)
                        else:
                            import loguru
                            loguru.logger.remove()
                            with client_engine() as engine:
                                bridge.process_request(request, engine, events.append)
                    if len(events) != 1:
                        return _failure("runtime_error", "内置运行时返回了无效结果")
                    return json.dumps(events[0], ensure_ascii=False, allow_nan=False)
                finally:
                    logging.disable(disabled)
                    for key, value in previous.items():
                        if value is None:
                            os.environ.pop(key, None)
                        else:
                            os.environ[key] = value
        except Exception:
            return _failure("runtime_unavailable", "内置 biliTickerBuy 客户端不可用，请重新安装此版本")
