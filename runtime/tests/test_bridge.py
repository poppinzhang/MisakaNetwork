from __future__ import annotations

import ast
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import bridge
import vendor_bili


def validation(ok=True, normalized=None):
    return SimpleNamespace(ok=ok, normalized_config=normalized or {}, errors=[] if ok else ["secret"], warnings=[])


@dataclass(frozen=True)
class TerminalRule:
    """Mirrors upstream task.buy_types.CreateOrderTerminalRule."""
    status: str
    message: str
    expose_payment_url: bool = False


def stream_event(status, **state):
    return SimpleNamespace(message="抢票成功 Cookie: secret", state=SimpleNamespace(status=status, **state))


def recorded_stream(statuses, consumed):
    for status in statuses:
        consumed.append(status)
        yield stream_event(status, order_id=12)


class SyntheticPilImage:
    pass


class SyntheticPyPNGImage:
    pass


def qr_encoder_modules(make, *, pillow=True):
    """Stand-in qrcode modules; without Pillow, qrcode.image.pil cannot import."""
    return {
        "qrcode": SimpleNamespace(make=make),
        "qrcode.image.pil": SimpleNamespace(PilImage=SyntheticPilImage) if pillow else None,
        "qrcode.image.pure": SimpleNamespace(PyPNGImage=SyntheticPyPNGImage),
    }


class BridgeTests(unittest.TestCase):
    def setUp(self):
        # Every test is hermetic, including fallback authentication probes.
        self.nav_get = Mock(side_effect=AssertionError("unexpected network request"))
        patcher = patch.dict(sys.modules, {"requests": SimpleNamespace(get=self.nav_get)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def nav_response(self, payload, status=200):
        self.nav_get.side_effect = None
        self.nav_get.return_value = SimpleNamespace(status_code=status, json=lambda: payload, close=Mock())

    def invoke(self, request, engine=None):
        output = []
        code = bridge.process_request(request, engine or SimpleNamespace(), output.append)
        return code, output

    def test_ping_has_real_version(self):
        code, events = self.invoke({"op": "ping"})
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]["data"]["version"], "0.4.0")
        self.assertEqual(events[-1]["data"]["bili_version"], "2.15.18")

    def test_cookie_formats(self):
        expected = [{"name": "session", "value": "synthetic"}]
        for value in (expected, {"cookie": expected}, {"cookies": expected}, {"session": "synthetic"}):
            self.assertEqual(bridge.normalize_cookies(value), expected)

    def test_invalid_cookies(self):
        for value in (None, [], {}, "cookie", [{"name": "a", "value": ""}], [{"name": "a", "value": "x\ny"}], [{"name": "a=b", "value": "x"}], [{"name": "a", "value": 1}]):
            with self.subTest(value=value), self.assertRaises(bridge.BridgeError):
                bridge.normalize_cookies(value)

    def test_invalid_requests_never_echo_inputs(self):
        for request in ([], None, {"op": "secret_unknown"}, {"op": "ping", "params": []}, {"op": ["ping"]}):
            code, events = self.invoke(request)
            self.assertEqual(code, 1)
            self.assertFalse(events[-1]["ok"])
            self.assertNotIn("secret_unknown", json.dumps(events))

    def test_invalid_json_and_request_size(self):
        for raw in (b"", b"{bad}", b'{"a": NaN}', b"\xff", b" " * (bridge.MAX_REQUEST_BYTES + 1)):
            with self.assertRaises(bridge.BridgeError):
                bridge.read_request(io.BytesIO(raw))
        self.assertEqual(bridge.read_request(io.BytesIO(b'{"op":"ping"}\n')), {"op": "ping"})

    def test_login_cookie_checks_upstream_state(self):
        cookies = [{"name": "session", "value": "synthetic"}]
        for status, payload in (("expired", {"code": -101}), ("valid", {"code": 0, "data": {"isLogin": True, "mid": 123, "uname": "test"}}), ("unknown", {"code": -500})):
            self.nav_response(payload)
            _, events = self.invoke({"op": "login_cookie", "params": {"cookies": cookies}})
            self.assertEqual(events[-1]["data"]["status"], status)
            self.assertEqual(events[-1]["data"]["logged_in"], status == "valid")
            self.assertEqual("cookies" in events[-1]["data"], status == "valid")

    def assertUnknownIdentity(self, data):
        self.assertEqual(data["status"], "unknown")
        self.assertFalse(data["logged_in"])
        self.assertEqual(data["uid"], "")
        self.assertEqual(data["username"], "")
        self.assertNotIn("cookies", data)
        for misleading in ("失效", "过期", "重新登录", "重新扫码"):
            self.assertNotIn(misleading, data["message"])

    def test_expiry_requires_authoritative_api_result(self):
        payloads = (
            {"code": -101},
            {"code": -101, "message": "账号未登录", "data": {"isLogin": False}},
            {"code": 0, "data": {"isLogin": False}},
            {"code": 0, "data": {"isLogin": False, "mid": 0}},
        )
        for operation in ("login_cookie", "login_state"):
            for payload in payloads:
                with self.subTest(operation=operation, payload=payload):
                    self.nav_response(payload)
                    code, events = self.invoke({"op": operation, "params": {"cookies": {"session": "synthetic"}}})
                    self.assertEqual(code, 0)
                    data = events[-1]["data"]
                    self.assertEqual(data["status"], "expired")
                    self.assertFalse(data["logged_in"])
                    self.assertIn("重新扫码", data["message"])
                    self.assertNotIn("cookies", data)
                    self.assertEqual(data["uid"], "")

    def test_authenticated_identity_uses_server_mid_not_cookie(self):
        for mid in (123, "123", "000123"):
            self.nav_response({"code": 0, "data": {"isLogin": True, "mid": mid, "uname": " 已验证用户 "}})
            code, events = self.invoke({"op": "login_state", "params": {"cookies": {"DedeUserID": "999", "session": "synthetic"}}})
            self.assertEqual(code, 0)
            self.assertEqual(events[-1]["data"]["status"], "valid")
            self.assertEqual(events[-1]["data"]["uid"], "123")
            self.assertEqual(events[-1]["data"]["username"], "已验证用户")
        args, kwargs = self.nav_get.call_args
        self.assertEqual(args, ("https://api.bilibili.com/x/web-interface/nav",))
        self.assertEqual(kwargs["timeout"], (3.05, 8))
        self.assertIs(kwargs["allow_redirects"], False)
        self.assertIn("DedeUserID=999", kwargs["headers"]["cookie"])
        self.assertNotIn("999", json.dumps(events))

    def test_transport_failures_do_not_expire_credentials(self):
        for failure in (TimeoutError("private timeout"), ConnectionError("private host"), OSError("private socket"), RuntimeError("Cookie: session=private-cookie")):
            self.nav_get.side_effect = failure
            for operation in ("login_state", "login_cookie"):
                with self.subTest(failure=type(failure).__name__, operation=operation):
                    code, events = self.invoke({"op": operation, "params": {"cookies": {"session": "synthetic"}}})
                    self.assertEqual(code, 0)
                    self.assertUnknownIdentity(events[-1]["data"])
                    self.assertNotIn("private", json.dumps(events))

    def test_non_200_responses_do_not_expire_even_with_unauthenticated_body(self):
        for http_status in (201, 204, 301, 302, 307, 400, 401, 403, 408, 412, 429, 500, 502, 503, 504):
            with self.subTest(http_status=http_status):
                self.nav_response({"code": -101, "data": {"isLogin": False}}, status=http_status)
                self.nav_get.return_value.json = Mock(side_effect=AssertionError("HTTP error bodies must not classify login"))
                code, events = self.invoke({"op": "login_cookie", "params": {"cookies": {"session": "synthetic"}}})
                self.assertEqual(code, 0)
                self.assertUnknownIdentity(events[-1]["data"])
                self.nav_get.return_value.json.assert_not_called()
                self.nav_get.return_value.close.assert_called_once()

    def test_malformed_or_ambiguous_api_data_does_not_expire_credentials(self):
        payloads = (
            None, [], "private response", False, {},
            {"code": "-101"}, {"code": -101.0}, {"code": False},
            {"code": "0", "data": {"isLogin": False}},
            {"code": -400}, {"code": -403}, {"code": -412}, {"code": 429}, {"code": -500},
            {"code": 0}, {"code": 0, "data": None}, {"code": 0, "data": []},
            {"code": 0, "data": {}}, {"code": 0, "data": {"isLogin": "false"}},
            {"code": 0, "data": {"isLogin": 0}}, {"code": 0, "data": {"isLogin": 1}},
            {"code": 0, "data": {"isLogin": True, "uname": "name-without-identity"}},
            {"code": 0, "data": {"isLogin": False, "mid": 123}},
            {"code": 0, "data": {"isLogin": False, "mid": False}},
            {"code": -101, "data": {"isLogin": True, "mid": 123}},
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                self.nav_response(payload)
                code, events = self.invoke({"op": "login_state", "params": {"cookies": {"DedeUserID": "123"}}})
                self.assertEqual(code, 0)
                self.assertUnknownIdentity(events[-1]["data"])
                self.assertNotIn("private", json.dumps(events))

    def test_authenticated_response_requires_valid_identity_fields(self):
        fields = [{"mid": mid, "uname": "test"} for mid in (None, True, False, 0, -1, 1.0, [], {}, "", "-1", "0", "１２３", "١٢٣", "1" * 21)]
        fields += [{"mid": 123, "uname": name} for name in (None, False, 1, [], "", "   ", "control\nname", "a" * 257)]
        for data in fields:
            with self.subTest(data=data):
                self.nav_response({"code": 0, "data": {"isLogin": True, **data}})
                code, events = self.invoke({"op": "login_cookie", "params": {"cookies": {"session": "synthetic"}}})
                self.assertEqual(code, 0)
                self.assertUnknownIdentity(events[-1]["data"])

    def test_invalid_json_response_is_unknown_and_not_echoed(self):
        self.nav_response(None)
        self.nav_get.return_value.json = Mock(side_effect=ValueError("private malformed response"))
        code, events = self.invoke({"op": "login_state", "params": {"cookies": {"session": "synthetic"}}})
        self.assertEqual(code, 0)
        self.assertUnknownIdentity(events[-1]["data"])
        self.assertNotIn("private", json.dumps(events))
        self.nav_get.return_value.close.assert_called_once()

    def login_qr_engine(self, url="https://passport.bilibili.com/test"):
        observed = {}
        def start(**kwargs):
            observed.update(kwargs)
            return {"ok": True, "login_url": url, "qrcode_key": "synthetic"}
        return SimpleNamespace(start_qr_login=start), observed

    def png_encoder(self):
        def save(output):
            self.assertIsInstance(output, io.BytesIO)
            output.write(b"synthetic-png")
        return Mock(return_value=SimpleNamespace(save=save))

    def test_qr_start_returns_png_without_a_file(self):
        engine, observed = self.login_qr_engine()
        make = self.png_encoder()
        with patch.dict(sys.modules, qr_encoder_modules(make)):
            code, events = self.invoke({"op": "qr_start"}, engine)
        self.assertEqual(code, 0)
        self.assertIs(observed["qr_image_path"], False)
        make.assert_called_once_with("https://passport.bilibili.com/test", image_factory=SyntheticPilImage)
        self.assertEqual(events[0]["data"]["qr_png_base64"], "c3ludGhldGljLXBuZw==")

    def test_qr_start_explicitly_selects_pypng_when_pillow_is_absent(self):
        # Android ships PyPNG without Pillow. qrcode 8.2's default factory
        # still imports Pillow first, so the login QR must not rely on it.
        engine, _ = self.login_qr_engine()
        make = self.png_encoder()
        with patch.dict(sys.modules, qr_encoder_modules(make, pillow=False)):
            code, events = self.invoke({"op": "qr_start"}, engine)
        self.assertEqual(code, 0)
        make.assert_called_once_with("https://passport.bilibili.com/test", image_factory=SyntheticPyPNGImage)
        self.assertEqual(events[-1]["data"]["qr_png_base64"], "c3ludGhldGljLXBuZw==")

    def test_missing_qr_encoder_is_a_fixed_installation_error(self):
        url = "https://passport.bilibili.com/test?qrcode_key=synthetic-secret"
        broken_installs = (
            {"qrcode": None},
            qr_encoder_modules(Mock(side_effect=ImportError("PyPNG library not installed: synthetic-secret")), pillow=False),
        )
        cases = (
            ({"op": "qr_start"}, self.login_qr_engine(url)[0]),
            ({"op": "payment_qr", "params": {"payment_code_url": "weixin://wxpay/bizpayurl?pr=synthetic-secret"}}, None),
        )
        for modules in broken_installs:
            for request, engine in cases:
                with self.subTest(op=request["op"], modules=sorted(modules)), patch.dict(sys.modules, modules):
                    code, events = self.invoke(request, engine)
                    self.assertEqual(code, 1)
                    self.assertEqual(events[-1]["error"], {"code": "qr_encoder_unavailable", "message": "内置二维码组件不完整，请重新安装此版本"})
                    self.assertNotIn("synthetic-secret", json.dumps(events))

    def test_qr_unavailable_is_structured_failure(self):
        code, events = self.invoke({"op": "qr_start"}, SimpleNamespace(start_qr_login=lambda **kw: {"ok": False, "error": "private"}))
        self.assertEqual(code, 1)
        self.assertEqual(events[-1]["error"]["code"], "qr_unavailable")

    def test_login_state_does_not_return_cookies_or_paths(self):
        self.nav_response({"code": 0, "data": {"isLogin": True, "uname": "test", "mid": 123, "cookies_path": "private"}})
        _, events = self.invoke({"op": "login_state", "params": {"cookies": {"session": "synthetic"}}})
        self.assertEqual(events[-1]["data"], {"status": "valid", "logged_in": True, "username": "test", "uid": "123", "message": "登录有效"})

    def test_upstream_error_is_not_exposed(self):
        def fail(*args, **kwargs):
            raise RuntimeError("Cookie: session=secret; user private data")
        code, events = self.invoke({"op": "qr_start"}, SimpleNamespace(start_qr_login=fail))
        self.assertEqual(code, 1)
        self.assertNotIn("secret", json.dumps(events))
        self.assertEqual(events[-1]["error"]["code"], "runtime_error")

    def test_progress_redacts_untrusted_state_and_message(self):
        event = SimpleNamespace(message="Cookie: session=secret", state=SimpleNamespace(status="running", stage="private address", attempt_current=1, attempt_total=20, countdown_seconds=-5, current_proxy="password"))
        result = bridge.progress_event(event)
        self.assertEqual(result["stage"], "working")
        self.assertEqual(result["attempt_current"], 1)
        self.assertNotIn("countdown_seconds", result)
        for secret in ("secret", "private address", "password"):
            self.assertNotIn(secret, json.dumps(result))

    def test_order_detail_is_derived_from_order_id_not_untrusted_url(self):
        for url in ("http://show.bilibili.com/order", "https://bilibili.com.example.org/order", "https://user:password@bilibili.com/order", "file:///private/file", "javascript:alert(1)"):
            self.assertEqual(bridge.safe_payment_fields({"order_detail_url": url}), {})
        self.assertEqual(bridge.safe_payment_fields({"order_detail_url": "https://show.bilibili.com/order?id=1", "order_id": 1}), {"order_detail_url": "https://show.bilibili.com/platform/orderDetail.html?order_id=1", "order_id": "1"})

    def test_validation_does_not_return_config_or_secret_errors(self):
        engine = SimpleNamespace(validate_config=lambda _: validation(False, {"cookies": "secret"}))
        _, events = self.invoke({"op": "validate", "params": {"config": {}}}, engine)
        self.assertFalse(events[-1]["data"]["ok"])
        self.assertNotIn("secret", json.dumps(events))

    def test_build_config_requires_complete_selection(self):
        engine = SimpleNamespace(build_ticket_config_from_selection=lambda *a: {}, validate_config=lambda _: validation(False))
        code, events = self.invoke({"op": "build_config", "params": {"purchase_context": {}, "selection": {}}}, engine)
        self.assertEqual(code, 1)
        self.assertEqual(events[-1]["error"]["code"], "invalid_config")

    def test_build_config_returns_validated_configuration(self):
        config = {"project_id": 123, "cookies": [{"name": "session", "value": "synthetic"}]}
        engine = SimpleNamespace(build_ticket_config_from_selection=lambda *a: config, validate_config=lambda _: validation(True, config))
        code, events = self.invoke({"op": "build_config", "params": {"purchase_context": {}, "selection": {}}}, engine)
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]["data"], config)

    def test_purchase_context_forwards_project_date_and_cookies(self):
        observed = {}
        def fetch(project, **kwargs):
            observed.update(project=project, **kwargs)
            return {"project_id": 123, "ticket_options": [], "buyers": [], "addresses": []}
        code, events = self.invoke({"op": "purchase_context", "params": {"project_input": "123", "selected_date": "2030-01-01", "cookies": {"session": "synthetic"}}}, SimpleNamespace(fetch_purchase_context=fetch))
        self.assertEqual(code, 0)
        self.assertEqual(observed["project"], "123")
        self.assertEqual(observed["selected_date"], "2030-01-01")
        self.assertEqual(observed["cookies"], [{"name": "session", "value": "synthetic"}])
        self.assertEqual(events[-1]["data"]["project_id"], 123)

    def test_search_requires_login_and_omits_internal_fields(self):
        for ok in (False, True):
            engine = SimpleNamespace(search_tickets=lambda *a, **kw: {"ok": ok, "results": [], "cookies_path": "private"})
            code, events = self.invoke({"op": "search", "params": {"cookies": {"a": "b"}, "keyword": "test"}}, engine)
            self.assertEqual(code, 0 if ok else 1)
            self.assertNotIn("private", json.dumps(events))

    def test_search_failure_only_guides_relogin_after_explicit_expiry(self):
        engine = SimpleNamespace(search_tickets=lambda *a, **kw: {"ok": False, "requires_login": True, "error": "private raw error"})
        for payload, error in (({"code": -101}, "login_required"), ({"code": -500}, "search_unavailable"), ({"code": 0, "data": {"isLogin": True, "mid": 123, "uname": "test"}}, "search_unavailable")):
            self.nav_response(payload)
            code, events = self.invoke({"op": "search", "params": {"cookies": {"session": "synthetic"}, "keyword": "test"}}, engine)
            self.assertEqual(code, 1)
            self.assertEqual(events[-1]["error"]["code"], error)
            self.assertNotIn("private", json.dumps(events))
            if error == "search_unavailable":
                self.assertNotIn("失效", events[-1]["error"]["message"])
                self.assertNotIn("过期", events[-1]["error"]["message"])

    def test_search_success_does_not_run_extra_authentication_request(self):
        engine = SimpleNamespace(search_tickets=lambda *a, **kw: {"ok": True, "results": []})
        code, _ = self.invoke({"op": "search", "params": {"cookies": {"session": "synthetic"}, "keyword": "test"}}, engine)
        self.assertEqual(code, 0)
        self.nav_get.assert_not_called()

    def test_search_rejects_invalid_page(self):
        code, events = self.invoke({"op": "search", "params": {"cookies": {"a": "b"}, "keyword": "test", "page": 1.5}})
        self.assertEqual(code, 1)
        self.assertEqual(events[-1]["error"]["code"], "invalid_request")

    def run_stream(self, stream, rules=None, runtime_options=None):
        self.built_options = []
        engine = SimpleNamespace(validate_config=lambda c: validation(True, c), build_runtime_options=lambda **kw: self.built_options.append(kw) or kw)
        modules = {
            "app_cmd.config.BuyConfig": SimpleNamespace(BuyConfig=SimpleNamespace(from_runtime_options=lambda *a: {})),
            "task.buy": SimpleNamespace(Buy=lambda **kw: SimpleNamespace(stream=stream)),
            "task.buy_helpers": SimpleNamespace(CREATE_ORDER_TERMINAL_RULES={} if rules is None else rules),
        }
        params = {"config": {}, "cookies": {"a": "synthetic"}}
        if runtime_options is not None:
            params["runtime_options"] = runtime_options
        with patch.dict(sys.modules, modules):
            return self.invoke({"op": "run", "params": params}, engine)

    def test_run_uses_structured_status_not_success_message(self):
        for status, expected, exitcode in (("running", "completed", 0), ("succeeded", "succeeded", 0), ("failed", "failed", 1), ("duplicate_order", "duplicate_order", 0)):
            with self.subTest(status=status):
                code, events = self.run_stream(lambda: iter([stream_event(status, order_id=12)]))
                self.assertEqual(code, exitcode)
                self.assertEqual(events[0]["stage"], "starting")
                self.assertEqual(events[-1]["data"]["status"], expected)
                self.assertNotIn("secret", json.dumps(events))

    def test_existing_order_stops_report_duplicate_order(self):
        for errno in sorted(bridge.EXISTING_ORDER_ERRNOS):
            with self.subTest(errno=errno):
                rules = {code: TerminalRule("completed", "upstream stop", code == 100048) for code in bridge.EXISTING_ORDER_ERRNOS}
                rules[1] = TerminalRule("completed", "unrelated stop")
                # Upstream reads the rule when the create-order request stops, after the bridge has started the task.
                code, events = self.run_stream(lambda: iter([stream_event(rules[errno].status, order_id=12)]), rules)
                self.assertEqual(code, 0)
                self.assertTrue(events[-1]["ok"])
                self.assertEqual(events[-1]["data"]["status"], "duplicate_order")
                self.assertEqual(events[-2]["status"], "duplicate_order")
                self.assertEqual(rules[errno], TerminalRule("duplicate_order", "upstream stop", errno == 100048))
                self.assertEqual(rules[1].status, "completed")

    def test_confirmed_order_survives_later_upstream_failure(self):
        for statuses, expected in (
            (("succeeded", "failed"), "succeeded"),
            (("succeeded", "cancelled"), "succeeded"),
            (("duplicate_order", "failed"), "duplicate_order"),
            (("succeeded", "duplicate_order", "completed"), "succeeded"),
            (("duplicate_order", "succeeded"), "succeeded"),
        ):
            with self.subTest(statuses=statuses):
                consumed = []
                code, events = self.run_stream(lambda: recorded_stream((*statuses, "running"), consumed))
                self.assertEqual(code, 0)
                self.assertTrue(events[-1]["ok"])
                self.assertEqual(events[-1]["data"]["status"], expected)
                self.assertEqual(events[-1]["data"]["order_id"], "12")
                # A terminal upstream error still stops the job, so upstream cannot retry into another order.
                stops = statuses[-1] in {"failed", "cancelled"}
                self.assertEqual(consumed, list(statuses) if stops else [*statuses, "running"])

    def test_run_accepts_only_full_beijing_time_start(self):
        code, _ = self.run_stream(lambda: iter([stream_event("succeeded")]), runtime_options={"time_start": "2026-11-20T20:00:00"})
        self.assertEqual(code, 0)
        self.assertEqual(self.built_options[-1]["time_start"], "2026-11-20T20:00:00")
        for value in ("20:00", "2026-11-20 20:00:00", "2026-11-20T20:00", "2026-02-30T20:00:00", "2026-1-5T20:00:00", 1):
            with self.subTest(value=value):
                code, events = self.run_stream(lambda: iter([]), runtime_options={"time_start": value})
                self.assertEqual(code, 1)
                self.assertEqual(events[-1]["error"]["code"], "invalid_request")
                self.assertEqual(self.built_options, [])

    def test_run_interval_defaults_and_bounds_keep_fixed_attempt_limit(self):
        for options, expected in ((None, 1000), ({"interval": 100}, 100), ({"interval": 1250}, 1250), ({"interval": 60000}, 60000)):
            with self.subTest(options=options):
                code, _ = self.run_stream(lambda: iter([]), runtime_options=options)
                self.assertEqual(code, 0)
                self.assertEqual(self.built_options[-1]["interval"], expected)
                self.assertEqual(self.built_options[-1]["create_retry_limit"], 40)
                self.assertEqual(self.built_options[-1]["create_request_batch_size"], 1)

    def test_run_rejects_invalid_interval_before_starting_task(self):
        for value in (True, False, None, "1000", [], {}, -1, 0, 99, 60001, 100.5, float("nan"), float("inf")):
            with self.subTest(value=value):
                code, events = self.run_stream(lambda: iter([]), runtime_options={"interval": value})
                self.assertEqual(code, 1)
                self.assertEqual(events[-1]["error"]["code"], "invalid_request")
                self.assertEqual(self.built_options, [])

    def test_run_rejects_attempt_limit_override(self):
        for value in (1, 20, 40, 100, None):
            with self.subTest(value=value):
                code, events = self.run_stream(lambda: iter([]), runtime_options={"create_retry_limit": value})
                self.assertEqual(code, 1)
                self.assertEqual(events[-1]["error"]["code"], "invalid_request")
                self.assertEqual(self.built_options, [])

    def test_run_rejects_notification_options(self):
        for option in ("audio_path", "pushplusToken", "serverchanKey", "serverchan3ApiUrl", "barkToken", "meowNickname", "ntfy_url", "ntfy_username", "ntfy_password", "telegram_bot_token", "telegram_chat_id", "telegram_http_proxy", "notify_proxy_exhausted", "create_request_proxy_strategy", "create_request_batch_size", "https_proxys", "proxy_api_url", "share"):
            with self.subTest(option=option):
                code, events = self.run_stream(lambda: iter([]), runtime_options={option: "synthetic-secret"})
                self.assertEqual(code, 1)
                self.assertEqual(events[-1]["error"]["code"], "invalid_request")
                self.assertEqual(self.built_options, [])
                self.assertNotIn("synthetic-secret", json.dumps(events))

    def test_cancel_produces_terminal_result(self):
        def cancel(*a, **kw):
            raise bridge.Cancelled()
        code, events = self.invoke({"op": "qr_start"}, SimpleNamespace(start_qr_login=cancel))
        self.assertEqual(code, 130)
        self.assertEqual(events[-1]["data"]["status"], "cancelled")


class SourceIntegrityTests(unittest.TestCase):
    def test_project_release_identity_matches_native_and_flutter_consumers(self):
        project = ROOT.parent
        release = ast.parse((project / "scripts" / "release_config.py").read_text())
        values = {
            target.id: ast.literal_eval(node.value)
            for node in release.body if isinstance(node, ast.Assign)
            for target in node.targets
            if isinstance(target, ast.Name) and target.id in {"VERSION", "BUILD"}
        }
        version, build = values["VERSION"], values["BUILD"]
        self.assertEqual(bridge.VERSION, version)
        for relative in ("Sisters/agent/config.go", "internal/control/pki.go"):
            with self.subTest(source=relative):
                source = (project / relative).read_text()
                self.assertEqual(re.search(r'const Version = "([^"]+)"', source).group(1), version)
        pubspec = (project / "LastOrder/pubspec.yaml").read_text()
        self.assertEqual(re.search(r"^version: (.+)$", pubspec, re.MULTILINE).group(1), f"{version}+{build}")
        app_info = (project / "LastOrder/lib/src/app_info.dart").read_text()
        self.assertEqual(re.search(r"const appVersion = '([^']+)';", app_info).group(1), version)
        self.assertEqual(int(re.search(r"const appBuildNumber = (\d+);", app_info).group(1)), build)
        windows = (project / "LastOrder/windows/runner/Runner.rc").read_text()
        self.assertIn(f'#define VERSION_AS_STRING "{version}+{build}"', windows)
        self.assertIn(f'#define VERSION_AS_NUMBER {version.replace(".", ",")},{build}', windows)

    def test_upstream_release_identity_matches_every_runtime_consumer(self):
        manifest = json.loads((ROOT / "vendor" / "biliTickerBuy" / "MANIFEST.json").read_text())
        self.assertEqual(manifest["version"], vendor_bili.UPSTREAM_VERSION)
        self.assertEqual(manifest["tag"], vendor_bili.UPSTREAM_TAG)
        self.assertEqual(manifest["revision"], vendor_bili.UPSTREAM_REVISION)
        self.assertEqual(manifest["package_version"], vendor_bili.UPSTREAM_PACKAGE_VERSION)
        self.assertEqual(manifest["tag"], "v" + manifest["version"])
        self.assertEqual(manifest["version"], bridge.BILI_VERSION)
        release = ast.parse((ROOT.parent / "scripts" / "release_config.py").read_text())
        release_version = next(
            ast.literal_eval(node.value) for node in release.body
            if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "BILI_VERSION" for target in node.targets
            )
        )
        self.assertEqual(manifest["version"], release_version)
        go_source = (ROOT.parent / "internal" / "control" / "pki.go").read_text()
        go_version = re.search(r'const BiliVersion = "([^"]+)"', go_source).group(1)
        self.assertEqual(manifest["version"], go_version)

    def test_vendor_manifest_and_no_private_runtime_data(self):
        root = ROOT / "vendor" / "biliTickerBuy"
        manifest = json.loads((root / "MANIFEST.json").read_text())
        expected = {item["path"] for item in manifest["files"]} | {"MANIFEST.json"}
        actual = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and "__pycache__" not in path.parts}
        self.assertEqual(expected, actual)
        for item in manifest["files"]:
            self.assertEqual(hashlib.sha256((root / item["path"]).read_bytes()).hexdigest(), item["sha256"])
        self.assertFalse(any(Path(path).name in {"cookies.json", "config.json"} or path.endswith(".bak") for path in actual))

    def test_vendored_existing_order_rules_match_bridge_mapping(self):
        # Review EXISTING_ORDER_ERRNOS whenever the vendored engine changes its create-order stop rules.
        source = (ROOT / "vendor" / "biliTickerBuy" / "task" / "buy_helpers.py").read_text(encoding="utf-8")
        table = next(node.value for node in ast.parse(source).body if isinstance(node, ast.AnnAssign) and getattr(node.target, "id", None) == "CREATE_ORDER_TERMINAL_RULES")
        statuses = {ast.literal_eval(key): next(ast.literal_eval(item.value) for item in value.keywords if item.arg == "status") for key, value in zip(table.keys, table.values)}
        self.assertEqual(statuses, dict.fromkeys(bridge.EXISTING_ORDER_ERRNOS, "completed"))

    def test_embedded_sources_and_dependencies_exclude_upstream_web_ui(self):
        vendor = ROOT / "vendor" / "biliTickerBuy"
        self.assertNotIn("app_ui", vendor_bili.PACKAGES)
        for path in vendor.rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts:
                continue
            self.assertNotIn(path.name.lower(), {"dockerfile", "docker-compose.yml", "main.py"})
            if path.suffix == ".py":
                imports = set()
                for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                    if isinstance(node, ast.Import):
                        imports.update(alias.name.split(".")[0] for alias in node.names)
                    elif isinstance(node, ast.ImportFrom) and node.module:
                        imports.add(node.module.split(".")[0])
                self.assertFalse(imports & {"gradio", "app_ui"}, path.relative_to(vendor))
        for path in ROOT.glob("requirements*.lock"):
            self.assertNotRegex(path.read_text(encoding="utf-8"), r"(?im)^gradio(?:[-=]|$)")

    def test_stage_codes_cover_every_upstream_stage(self):
        # Review STAGE_CODES (and Sisters' messages) whenever the vendored engine names a new stage.
        source = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "vendor" / "biliTickerBuy" / "task").glob("*.py"))
        stages = set(re.findall(r'\bstage(?:_value)?\s*(?::\s*str\s*)?=\s*"([^"]+)"', source))
        self.assertIn("等待开票", stages)
        self.assertEqual(stages - set(bridge.STAGE_CODES), set())
        waiting = SimpleNamespace(state=SimpleNamespace(status="running", stage="等待开票", countdown_seconds=60))
        self.assertEqual(bridge.progress_event(waiting)["stage"], "waiting")
        self.assertEqual(bridge.progress_event(waiting)["countdown_seconds"], 60)

    def test_invalid_request_cli_is_a_single_json_result(self):
        result = subprocess.run([sys.executable, str(ROOT / "bridge.py")], input=b"broken\n", capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalid_json")

    def test_cli_output_is_ascii_under_legacy_code_pages(self):
        # Windows pipes use the ANSI code page, while every consumer parses the stream as JSON.
        for encoding in ("cp1252", "gbk"):
            with self.subTest(encoding=encoding):
                env = dict(os.environ, PYTHONIOENCODING=encoding)
                result = subprocess.run([sys.executable, str(ROOT / "bridge.py")], input=b"broken\n", capture_output=True, env=env)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, b"")
                self.assertTrue(result.stdout.isascii())
                self.assertEqual(json.loads(result.stdout)["error"]["message"], "请求不是有效 JSON")


if __name__ == "__main__":
    unittest.main()
