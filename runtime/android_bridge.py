"""Serialized in-process client adapter for Android's embedded Python runtime.

The shared protocol and upstream interface functions are identical to desktop.
Only account, catalog, and task-configuration operations are allowed here;
Sisters executes purchases on a remote machine.
"""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib
import io
import json
import logging
import os
from pathlib import Path
import tempfile
import threading
from typing import Any

import bridge

CLIENT_OPERATIONS = bridge.OPERATIONS - {"run"}
_LOCK = threading.Lock()


def load_client_engine() -> Any:
    # Deployment stages the verified upstream source at the Python source root.
    # BiliRequest imports HTTP/2 implementations lazily; the client interface
    # uses requests and does not need the subprocess buying engine on Android.
    engine = importlib.import_module("interface")
    importlib.import_module("util.request.BiliRequest")
    import qrcode.image.pure
    import png
    return engine


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
                        import loguru
                        loguru.logger.remove()
                        engine = load_client_engine()
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
