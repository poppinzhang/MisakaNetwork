#!/usr/bin/env python3
"""MisakaNetwork's one-request, JSONL adapter for the bundled biliTickerBuy."""
from __future__ import annotations

import base64
from contextlib import redirect_stderr, redirect_stdout
import dataclasses
from datetime import datetime
import importlib
import io
import json
import logging
import math
import os
from pathlib import Path
import signal
import sys
import tempfile
from typing import Any, Callable
from urllib.parse import urlsplit

VERSION = "0.1.5"
BILI_VERSION = "2.15.17"
MAX_REQUEST_BYTES = 4 * 1024 * 1024
OPERATIONS = frozenset({"ping", "qr_start", "qr_poll", "login_cookie", "login_state", "search", "purchase_context", "build_config", "validate", "run"})
# Upstream stage labels mapped to the stable codes Sisters understands; any
# other label becomes "working" so no upstream text crosses the protocol.
STAGE_CODES = {
    "初始化": "starting",
    "等待开票": "waiting",
    "订单准备": "preparing",
    "创建订单": "ordering",
    "抢票成功": "ordered",
    "购票页校验超时": "page_timeout",
}
SAFE_STATUSES = frozenset({"running", "cooldown", "succeeded", "duplicate_order", "failed", "cancelled", "completed"})
TERMINAL_STATUSES = frozenset({"succeeded", "duplicate_order", "failed", "cancelled", "completed"})
# An order is known to exist; later upstream errors must not turn this into a failure.
CONFIRMED_STATUSES = frozenset({"succeeded", "duplicate_order"})
# Create-order errors on which upstream stops because the account already holds
# an order for the project: 100003 (purchase limit reached by an existing order),
# 100048 (unfinished order) and 100079 (duplicate order). biliTickerBuy reports
# all of them as "completed", which this protocol treats as unconfirmed.
EXISTING_ORDER_ERRNOS = frozenset({100003, 100048, 100079})
# Upstream waits for this Beijing-time form as is; clock-only values would be
# dated by the host's own time zone.
TIME_START_FORMAT = "%Y-%m-%dT%H:%M:%S"
PAYMENT_KEYS = ("order_id", "order_detail_url", "payment_qr_url", "payment_code_url")
NAV_URL = "https://api.bilibili.com/x/web-interface/nav"


class BridgeError(Exception):
    def __init__(self, code: str, message: str):
        self.code, self.message = code, message
        super().__init__(message)


class Cancelled(BaseException):
    pass


def require_object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BridgeError("invalid_request", f"{name} 必须为 JSON 对象")
    return value


def normalize_cookies(value: Any) -> list[dict[str, str]]:
    if isinstance(value, dict):
        if "cookie" in value or "cookies" in value:
            value = value.get("cookie", value.get("cookies"))
        else:
            value = [{"name": key, "value": item} for key, item in value.items()]
    if not isinstance(value, list) or not value:
        raise BridgeError("invalid_cookies", "Cookie 必须是非空名称/值列表或对象")
    result = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not isinstance(item.get("value"), str):
            raise BridgeError("invalid_cookies", "Cookie 条目需要字符串 name 与 value")
        name, content = item["name"], item["value"]
        if not name or not content or any(c in name for c in "\r\n;=") or any(c in content for c in "\r\n"):
            raise BridgeError("invalid_cookies", "Cookie 包含空值或非法字符")
        result.append({"name": name, "value": content})
    return result


def authentication_result(status: str, *, username: str = "", uid: str = "") -> dict[str, Any]:
    return {
        "status": status,
        "logged_in": status == "valid",
        "username": username if status == "valid" else "",
        "uid": uid if status == "valid" else "",
        "message": {
            "valid": "登录有效",
            "expired": "登录已失效，请重新扫码登录",
            "unknown": "暂时无法确认登录状态，请检查网络后重试",
        }[status],
    }


def classify_authentication(payload: Any) -> dict[str, Any]:
    """Classify only an HTTP-200 response from the fixed authenticated nav API.

    A missing username, transport error or a generic API failure is not evidence
    of expiry. Account identity must come from the authenticated server result,
    never from the caller's cookie fields or the upstream display-name fallback.
    """
    if not isinstance(payload, dict) or type(payload.get("code")) is not int:
        return authentication_result("unknown")
    data = payload.get("data")
    if payload["code"] == -101:
        # An internally contradictory response must not trigger credential loss.
        if isinstance(data, dict) and data.get("isLogin") is True:
            return authentication_result("unknown")
        return authentication_result("expired")
    if payload["code"] != 0 or not isinstance(data, dict):
        return authentication_result("unknown")
    if data.get("isLogin") is False:
        mid = data.get("mid")
        if not (mid is None or type(mid) is int and mid == 0 or type(mid) is str and mid in {"0", ""}):
            return authentication_result("unknown")
        return authentication_result("expired")
    if data.get("isLogin") is not True:
        return authentication_result("unknown")
    mid = data.get("mid")
    if type(mid) is int:
        uid = str(mid)
    elif isinstance(mid, str) and mid.isascii() and mid.isdigit():
        uid = mid.lstrip("0") or "0"
    else:
        return authentication_result("unknown")
    username = data.get("uname")
    if (
        not uid.isascii() or not uid.isdigit() or uid == "0" or len(uid) > 20
        or not isinstance(username, str) or not username.strip() or len(username) > 256
        or any(ord(character) < 32 or ord(character) == 127 for character in username)
    ):
        return authentication_result("unknown")
    return authentication_result("valid", username=username.strip(), uid=uid)


def verify_authentication(cookies: list[dict[str, str]]) -> dict[str, Any]:
    """Return a conservative three-state login result; never expose raw failures."""
    try:
        import requests
        response = requests.get(
            NAV_URL,
            headers={
                "accept": "application/json",
                "referer": "https://show.bilibili.com/",
                "user-agent": "Mozilla/5.0",
                "cookie": "; ".join(f"{item['name']}={item['value']}" for item in cookies),
            },
            timeout=(3.05, 8),
            allow_redirects=False,
        )
        try:
            # In particular, 401/403/429/5xx and redirects are not expiry proof,
            # even when a proxy or intermediary returns a nav-looking JSON body.
            if response.status_code != 200:
                return authentication_result("unknown")
            return classify_authentication(response.json())
        finally:
            response.close()
    except Exception:
        return authentication_result("unknown")


def valid_time_start(value: str) -> bool:
    try:
        return datetime.strptime(value, TIME_START_FORMAT).strftime(TIME_START_FORMAT) == value
    except ValueError:
        return False


def bounded_number(params: dict, key: str, default: float, low: float, high: float) -> float:
    value = params.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
        raise BridgeError("invalid_request", f"{key} 超出允许范围")
    return value


def safe_payment_fields(state: Any) -> dict[str, Any]:
    """Only return payment fields, never arbitrary state or upstream request dumps."""
    result: dict[str, Any] = {}
    for key in PAYMENT_KEYS:
        value = state.get(key) if isinstance(state, dict) else getattr(state, key, None)
        if value in (None, ""):
            continue
        if key == "order_id":
            if isinstance(value, (int, str)) and str(value).isdigit() and len(str(value)) <= 80:
                result[key] = str(value)
            continue
        if not isinstance(value, str) or len(value) > 8192:
            continue
        try:
            url = urlsplit(value)
            host = url.hostname or ""
            if url.scheme == "https" and not url.username and not url.password and (host == "bilibili.com" or host.endswith(".bilibili.com")):
                result[key] = value
        except ValueError:
            continue
    return result


def progress_event(event: Any) -> dict[str, Any]:
    state = getattr(event, "state", None)
    status = getattr(state, "status", "running")
    if status not in SAFE_STATUSES:
        status = "running"
    stage = STAGE_CODES.get(getattr(state, "stage", "初始化"), "working")
    # Raw upstream messages can contain response bodies, buyer data and proxy
    # credentials. Fixed messages intentionally avoid all such content.
    message = {
        "running": "抢票任务执行中", "cooldown": "等待请求冷却",
        "succeeded": "订单已创建，请及时付款", "duplicate_order": "检测到已有订单，请检查订单并付款",
        "failed": "抢票执行失败", "cancelled": "任务已取消", "completed": "执行结束，尚未确认创建订单",
    }[status]
    result: dict[str, Any] = {"type": "progress", "status": status, "stage": stage, "message": message}
    for key in ("attempt_current", "attempt_total", "countdown_seconds"):
        value = getattr(state, key, None)
        if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 10**9:
            result[key] = value
    return result


def public_validation(validation: Any) -> dict[str, Any]:
    # Validation error strings may include values from malformed configuration;
    # return generic messages while retaining useful counts and the boolean.
    errors = list(getattr(validation, "errors", []))
    warnings = list(getattr(validation, "warnings", []))
    return {
        "ok": bool(validation.ok),
        "errors": ["任务配置不完整或字段类型错误，请重新选择场次、购票人与收货地址"] if errors else [],
        "warnings": ["部分可选配置未填写"] if warnings else [],
        "error_count": len(errors),
    }


def load_engine() -> Any:
    if not getattr(sys, "frozen", False):
        vendor = Path(__file__).resolve().parent / "vendor" / "biliTickerBuy"
        sys.path.insert(0, str(vendor))
    engine = importlib.import_module("interface")
    # Import the actual buying engine even for ping, without starting a task.
    importlib.import_module("task.buy")
    return engine


def report_existing_orders(rules: dict[int, Any]) -> None:
    """Make upstream's existing-order stops end as duplicate_order, not completed."""
    for errno in EXISTING_ORDER_ERRNOS:
        rule = rules.get(errno)
        if rule is not None:
            rules[errno] = dataclasses.replace(rule, status="duplicate_order")


def run_task(params: dict[str, Any], engine: Any, emit: Callable[[dict], None]) -> dict[str, Any]:
    config = dict(require_object(params.get("config"), "config"))
    config["cookies"] = normalize_cookies(params.get("cookies", config.get("cookies")))
    validation = engine.validate_config(config)
    if not validation.ok:
        raise BridgeError("invalid_config", "任务配置不完整，请重新选择场次、购票人与收货地址")
    options = dict(require_object(params.get("runtime_options", {}), "runtime_options"))
    # v0.1 accepts a small, explicit set; no credentials, notification channels,
    # arbitrary local file paths or extra background work enter the runtime.
    if set(options) - {"interval", "time_start", "create_retry_limit", "wait_for_buy_button"}:
        raise BridgeError("invalid_request", "runtime_options 包含未支持的选项")
    interval = bounded_number(options, "interval", 1000, 100, 60000)
    retries = bounded_number(options, "create_retry_limit", 20, 1, 100)
    if int(interval) != interval or int(retries) != retries:
        raise BridgeError("invalid_request", "interval 和 create_retry_limit 必须是整数")
    time_start = options.get("time_start", "")
    if not isinstance(time_start, str) or not isinstance(options.get("wait_for_buy_button", False), bool):
        raise BridgeError("invalid_request", "开始时间或购买按钮选项格式错误")
    if time_start and not valid_time_start(time_start):
        raise BridgeError("invalid_request", "开始时间必须是北京时间 YYYY-MM-DDTHH:MM:SS")
    runtime = engine.build_runtime_options(
        interval=int(interval), create_retry_limit=int(retries),
        time_start=time_start, wait_for_buy_button=options.get("wait_for_buy_button", False),
        show_qrcode=False, show_random_message=False, auto_open_payment_url=False,
        create_request_batch_size=1,
    )
    from app_cmd.config.BuyConfig import BuyConfig
    from task.buy import Buy
    from task.buy_helpers import CREATE_ORDER_TERMINAL_RULES
    report_existing_orders(CREATE_ORDER_TERMINAL_RULES)
    job = Buy(config=BuyConfig.from_runtime_options(json.dumps(validation.normalized_config, ensure_ascii=False), runtime))
    status = "completed"
    confirmed: str | None = None
    payment: dict[str, Any] = {}
    emit({"type": "progress", "status": "running", "stage": "starting", "message": "正在启动 biliTickerBuy"})
    for event in job.stream():
        progress = progress_event(event)
        emit(progress)
        payment.update(safe_payment_fields(getattr(event, "state", None)))
        state_status = getattr(getattr(event, "state", None), "status", "running")
        if state_status in CONFIRMED_STATUSES:
            if confirmed is None or state_status == "succeeded":
                confirmed = state_status
        elif state_status in TERMINAL_STATUSES:
            status = state_status
        if state_status in {"failed", "cancelled"}:
            break  # Upstream may otherwise retry a terminal program exception forever.
    return {"status": confirmed or status, **payment}


def handle_request(request: Any, engine: Any, emit: Callable[[dict], None]) -> dict[str, Any]:
    request = require_object(request, "request")
    operation = request.get("op")
    if not isinstance(operation, str) or operation not in OPERATIONS:
        raise BridgeError("unknown_operation", "不支持的操作")
    params = require_object(request.get("params", {}), "params")
    if operation == "ping":
        return {"version": VERSION, "bili_version": BILI_VERSION, "protocol": 1, "ready": True}
    if operation == "qr_start":
        data = engine.start_qr_login(qr_image_path=False, max_retry=2)
        if not data.get("ok"):
            raise BridgeError("qr_unavailable", "暂时无法生成登录二维码，请稍后重试")
        import qrcode
        buffer = io.BytesIO()
        qrcode.make(data["login_url"]).save(buffer)
        return {"login_url": data["login_url"], "qrcode_key": data["qrcode_key"], "qr_png_base64": base64.b64encode(buffer.getvalue()).decode("ascii")}
    if operation == "qr_poll":
        key = params.get("qrcode_key")
        if not isinstance(key, str) or not key or len(key) > 2048:
            raise BridgeError("invalid_request", "需要有效的二维码标识")
        timeout = bounded_number(params, "timeout_seconds", 5, 1, 60)
        data = engine.poll_qr_login(key, timeout_seconds=timeout, poll_interval=1)
        status = data.get("status")
        if status == "confirmed" and data.get("ok"):
            cookies = normalize_cookies(data.get("cookies"))
            identity = verify_authentication(cookies)
            if identity["status"] == "expired":
                raise BridgeError("login_required", identity["message"])
            if identity["status"] != "valid":
                raise BridgeError("auth_unavailable", "扫码已确认，但暂时无法验证账号身份；账号尚未保存，请检查网络后重新扫码")
            return {"status": "confirmed", "username": identity["username"], "uid": identity["uid"], "cookies": cookies}
        return {"status": "timeout" if status == "timeout" else "failed", "message": "等待扫码确认" if status == "timeout" else "二维码已失效，请重新获取"}
    if operation in {"login_cookie", "login_state", "search", "purchase_context"}:
        cookies = normalize_cookies(params.get("cookies"))
        if operation in {"login_cookie", "login_state"}:
            result = verify_authentication(cookies)
            if operation == "login_cookie" and result["status"] == "valid":
                result["cookies"] = cookies
            return result
        if operation == "search":
            keyword = params.get("keyword")
            if not isinstance(keyword, str) or not keyword.strip() or len(keyword) > 200:
                raise BridgeError("invalid_request", "搜索关键词不能为空或过长")
            page = bounded_number(params, "page", 1, 1, 1000)
            if int(page) != page:
                raise BridgeError("invalid_request", "页码必须是整数")
            data = engine.search_tickets(keyword, cookies=cookies, page=int(page))
            if not data.get("ok"):
                identity = verify_authentication(cookies)
                if identity["status"] == "expired":
                    raise BridgeError("login_required", identity["message"])
                raise BridgeError("search_unavailable", "暂时无法查询活动，请检查网络或稍后重试")
            return {key: data[key] for key in ("keyword", "page", "pagesize", "total", "results") if key in data}
        project = params.get("project_input")
        if isinstance(project, bool) or not isinstance(project, (str, int)) or len(str(project)) > 4096:
            raise BridgeError("invalid_request", "需要有效的活动编号或链接")
        selected_date = params.get("selected_date")
        if selected_date is not None and (not isinstance(selected_date, str) or len(selected_date) > 20):
            raise BridgeError("invalid_request", "场次日期格式错误")
        return engine.fetch_purchase_context(project, cookies=cookies, selected_date=selected_date)
    if operation == "build_config":
        context = require_object(params.get("purchase_context"), "purchase_context")
        selection = require_object(params.get("selection"), "selection")
        config = engine.build_ticket_config_from_selection(context, selection)
        validation = engine.validate_config(config)
        if not validation.ok:
            raise BridgeError("invalid_config", "请完整选择票档、购票人与收货地址，并填写联系人及电话")
        return validation.normalized_config
    if operation == "validate":
        config = require_object(params.get("config"), "config")
        return public_validation(engine.validate_config(config))
    return run_task(params, engine, emit)


def process_request(request: Any, engine: Any, emit: Callable[[dict], None]) -> int:
    try:
        data = handle_request(request, engine, emit)
        failed = data.get("status") in {"failed", "cancelled"} and request.get("op") == "run"
        result: dict[str, Any] = {"type": "result", "ok": not failed, "data": data}
        if failed:
            result["error"] = {"code": "execution_failed", "message": "抢票执行失败或已取消"}
        emit(result)
        return 1 if failed else 0
    except Cancelled:
        emit({"type": "result", "ok": False, "data": {"status": "cancelled"}, "error": {"code": "cancelled", "message": "任务已取消"}})
        return 130
    except BridgeError as exc:
        emit({"type": "result", "ok": False, "error": {"code": exc.code, "message": exc.message}})
        return 1
    except Exception:
        # Exception text often embeds HTTP headers, credential values or local paths.
        emit({"type": "result", "ok": False, "error": {"code": "runtime_error", "message": "biliTickerBuy 操作失败，请检查登录状态、活动信息与网络连接"}})
        return 1


def read_request(stream: Any) -> Any:
    raw = stream.readline(MAX_REQUEST_BYTES + 1)
    if not raw or len(raw) > MAX_REQUEST_BYTES:
        raise BridgeError("invalid_request", "请求为空或超过大小限制")
    try:
        return json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite number")))
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise BridgeError("invalid_json", "请求不是有效 JSON") from None


def main() -> int:
    output = sys.stdout.buffer
    def emit(event: dict) -> None:
        # ASCII JSON does not depend on the pipe code page, which is ANSI on Windows.
        output.write(json.dumps(event, allow_nan=False).encode("ascii") + b"\n")
        output.flush()
    if sys.argv[1:] == ["--version"]:
        emit({"type": "result", "ok": True, "data": {"version": VERSION, "bili_version": BILI_VERSION, "protocol": 1}})
        return 0
    try:
        request = read_request(sys.stdin.buffer)
    except BridgeError as exc:
        emit({"type": "result", "ok": False, "error": {"code": exc.code, "message": exc.message}})
        return 1
    if sys.argv[1:]:
        emit({"type": "result", "ok": False, "error": {"code": "invalid_request", "message": "请求必须通过标准输入传递"}})
        return 1
    os.umask(0o077)
    def cancel(_signum: int, _frame: Any) -> None:
        raise Cancelled()
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    with tempfile.TemporaryDirectory(prefix="misaka-runtime-") as temporary:
        # All paths are ephemeral, no machine-local path enters a result or log.
        os.environ["MISAKA_RUNTIME_STATE_DIR"] = temporary
        os.environ["BTB_CONFIG_PATH"] = str(Path(temporary) / "config.json")
        os.environ["BTB_COOKIES_PATH"] = str(Path(temporary) / "cookies.json")
        os.environ["BTB_LOG_DIR"] = str(Path(temporary) / "logs")
        os.environ["BTB_SKIP_INITIAL_TIME_SYNC"] = "1"
        logging.disable(logging.CRITICAL)
        with open(os.devnull, "w") as sink, redirect_stdout(sink), redirect_stderr(sink):
            try:
                engine = load_engine()
            except Exception:
                emit({"type": "result", "ok": False, "error": {"code": "runtime_unavailable", "message": "内置 biliTickerBuy 运行时不完整，请重新安装此版本"}})
                return 1
            return process_request(request, engine, emit)


if __name__ == "__main__":
    raise SystemExit(main())
