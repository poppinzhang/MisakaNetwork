"""Offline end-to-end checks of the real Android client and packaged dependencies."""
from __future__ import annotations

import base64
import contextlib
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import android_bridge
import bridge

DEPENDENCIES = ("requests", "httpx", "httpcore", "h2", "loguru", "tinydb", "ntplib", "qrcode", "png")


@unittest.skipUnless(
    all(importlib.util.find_spec(name) is not None for name in DEPENDENCIES),
    "Install runtime/requirements-android.lock for real Android client checks",
)
class AndroidClientIntegrationTests(unittest.TestCase):
    def setUp(self):
        import httpx
        import requests

        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.cache = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.stack.enter_context(patch.object(sys, "path", [str(ROOT / "vendor/biliTickerBuy"), *sys.path]))
        self.stack.enter_context(patch.dict(os.environ, {"GRADIO_TEMP_DIR": "preserved-value"}))
        self.stack.enter_context(patch.dict(sys.modules, {"PIL": None, "qrcode.image.pil": None, "brotli": None, "brotlicffi": None, "zstandard": None}))
        self.connect = self.stack.enter_context(patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")))
        self.connect_ex = self.stack.enter_context(patch.object(socket.socket, "connect_ex", side_effect=AssertionError("network forbidden")))
        self.calls = []
        self.states = []
        self.resources = []
        self.config_databases = []
        real_loader = android_bridge.load_client_engine

        def load(resources):
            self.resources.append(resources)
            engine = real_loader(resources)
            self.states.append(sys.modules["util"].EXE_PATH)
            self.config_databases.append(sys.modules["util"].ConfigDB)
            self.assertNotIn("task.buy", sys.modules)
            self.assertNotIn("gradio", sys.modules)
            self.assertNotIn("util.notifer.Notifier", sys.modules)
            return engine

        self.stack.enter_context(patch.object(android_bridge, "load_client_engine", side_effect=load))
        process_request = bridge.process_request

        def process(*args):
            result = process_request(*args)
            # Inspect before TemporaryDirectory cleanup: deleting a credential
            # file afterward would not satisfy the in-memory storage contract.
            for path in Path(self.cache).rglob("*"):
                if path.is_file():
                    self.assertNotIn(b"synthetic", path.read_bytes())
            return result

        self.stack.enter_context(patch.object(bridge, "process_request", side_effect=process))

        def httpx_send(transport, request):
            # Keep the real BiliRequest, HTTPX Client, SSLContext, cookie jar and
            # decompressor; replace only the final wire transport.
            context = transport._pool._ssl_context
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
            self.assertEqual(request.headers["accept-encoding"], "gzip, deflate")
            self.calls.append((str(request.url), request.headers.get("cookie", "")))
            payload = self.payload(request.url.path)
            return httpx.Response(200, headers={"content-encoding": "gzip", "content-type": "application/json"},
                                  stream=httpx.ByteStream(gzip.compress(json.dumps(payload).encode())))

        def requests_send(adapter, request, **kwargs):
            self.assertIs(kwargs.get("verify"), True)
            self.calls.append((request.url, request.headers.get("cookie", "")))
            from urllib.parse import urlparse
            response = requests.Response()
            response.status_code = 200
            response._content = json.dumps(self.payload(urlparse(request.url).path)).encode()
            response.cookies.set("SESSDATA", "synthetic-confirmed", domain=".bilibili.com", path="/")
            return response

        self.stack.enter_context(patch.object(httpx.HTTPTransport, "handle_request", httpx_send))
        self.stack.enter_context(patch.object(requests.adapters.HTTPAdapter, "send", requests_send))

    @staticmethod
    def payload(path):
        payloads = {
            "/x/passport-login/web/qrcode/generate": {"code": 0, "data": {"url": "https://passport.bilibili.com/synthetic", "qrcode_key": "synthetic-key"}},
            "/x/passport-login/web/qrcode/poll": {"code": 0, "data": {"code": 0}},
            "/x/web-interface/nav": {"code": 0, "data": {"isLogin": True, "mid": 123, "uname": "synthetic-user"}},
            "/api/ticket/search/list": {"errno": 0, "data": {"total": 1, "result": [{"id": 1, "title": "synthetic-event"}]}},
            "/mall-search-items/items_detail/info": {"code": 0, "data": {"projectId": 1, "projectName": "synthetic-event", "screenList": [{"id": 11, "name": "synthetic-screen", "ticketList": [{"id": 21, "desc": "synthetic-ticket", "price": 100, "sale_start": "2026-01-01 12:00:00"}]}]}},
            "/api/ticket/linkgoods/list": {"errno": 0, "data": {"list": []}},
            "/api/ticket/buyer/list": {"errno": 0, "data": {"list": [{"name": "synthetic-buyer", "personal_id": "synthetic-id"}]}},
            "/api/ticket/addr/list": {"errno": 0, "data": {"addr_list": [{"id": 1, "name": "synthetic-contact", "phone": "synthetic-phone", "addr": "synthetic-address"}]}},
        }
        if path not in payloads:
            raise AssertionError("unexpected platform endpoint")
        return payloads[path]

    def invoke(self, op, **params):
        output = io.StringIO()
        previous_modules = {key: value for key, value in sys.modules.items() if android_bridge._is_upstream_module(key)}
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = json.loads(android_bridge.invoke(json.dumps({"op": op, "params": params}), self.cache))
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(list(Path(self.cache).iterdir()), [])
        self.assertEqual(os.environ["GRADIO_TEMP_DIR"], "preserved-value")
        self.assertEqual({key: value for key, value in sys.modules.items() if android_bridge._is_upstream_module(key)}, previous_modules)
        for resources in self.resources:
            for request in resources:
                if getattr(request, "_h2_client", None) is not None:
                    self.assertTrue(request._h2_client.is_closed)
                self.assertFalse(request.cookieManager.db.db._opened)
        for database in self.config_databases:
            self.assertTrue(database.db.storage._handle.closed)
        self.connect.assert_not_called()
        self.connect_ex.assert_not_called()
        return result

    def test_complete_client_flow_uses_real_engine_without_native_optional_dependencies(self):
        self.assertTrue(self.invoke("ping")["data"]["ready"])
        started = self.invoke("qr_start")
        self.assertTrue(started["ok"], started)
        self.assertTrue(base64.b64decode(started["data"]["qr_png_base64"]).startswith(b"\x89PNG"))
        confirmed = self.invoke("qr_poll", qrcode_key="synthetic-key")
        self.assertEqual(confirmed["data"]["status"], "confirmed")
        cookies = confirmed["data"]["cookies"]
        for op in ("login_cookie", "login_state"):
            self.assertEqual(self.invoke(op, cookies=cookies)["data"]["status"], "valid")
        self.assertEqual(self.invoke("search", cookies=cookies, keyword="event")["data"]["total"], 1)
        context = self.invoke("purchase_context", cookies=cookies, project_input="1")
        self.assertTrue(context["ok"], context)
        self.assertEqual(context["data"]["ticket_options"][0]["screen_id"], 11)
        built = self.invoke("build_config", purchase_context=context["data"], selection={
            "ticket_index": 0, "buyer_indices": [0], "address_index": 0,
            "buyer": "synthetic-contact", "tel": "synthetic-phone",
        })
        self.assertTrue(built["ok"], built)
        self.assertEqual(built["data"]["sku_id"], 21)
        self.assertTrue(self.invoke("validate", config=built["data"])["data"]["ok"])
        self.assertTrue(self.invoke("payment_qr", payment_code_url="weixin://wxpay/bizpayurl?pr=synthetic")["ok"])
        self.assertFalse(self.invoke("run", config=built["data"])["ok"])
        self.assertEqual(len(self.states), len(set(self.states)))
        self.assertTrue(all(not Path(state).exists() for state in self.states))

    def test_repeated_purchase_contexts_do_not_reuse_cookies_or_connections(self):
        for value in ("synthetic-account-a", "synthetic-account-b"):
            self.calls.clear()
            reply = self.invoke("purchase_context", cookies=[{"name": "SESSDATA", "value": value}], project_input="1")
            self.assertTrue(reply["ok"], reply)
            self.assertGreaterEqual(len(self.calls), 5)
            for _, cookie in self.calls:
                self.assertEqual(cookie, "SESSDATA=" + value)
            self.assertEqual(reply["data"]["cookies"], [{"name": "SESSDATA", "value": value}])

    def test_missing_httpx_fails_ping_and_next_invocation_can_recover(self):
        with patch.dict(sys.modules, {"httpx": None}):
            reply = json.loads(android_bridge.invoke('{"op":"ping"}', self.cache))
        self.assertEqual(reply["error"]["code"], "runtime_unavailable")
        self.assertEqual(list(Path(self.cache).iterdir()), [])
        self.assertTrue(self.invoke("ping")["ok"])

    def test_operation_error_closes_clients_and_does_not_expose_secrets(self):
        with patch.object(self, "payload", side_effect=RuntimeError("synthetic-private-response")):
            reply = self.invoke("purchase_context", cookies={"SESSDATA": "synthetic-secret"}, project_input="1")
        self.assertFalse(reply["ok"])
        self.assertNotIn("synthetic", json.dumps(reply))
        self.assertTrue(self.invoke("ping")["ok"])

    def test_failed_module_import_closes_partial_global_request_and_can_recover(self):
        import ntplib
        import requests
        sessions = []
        original_session = requests.Session

        def session():
            result = original_session()
            sessions.append(result)
            result.close = unittest.mock.Mock(wraps=result.close)
            return result

        with patch.object(ntplib, "NTPClient", side_effect=RuntimeError("synthetic-init-failure")), \
                patch.object(requests, "Session", side_effect=session):
            reply = self.invoke("ping")
        self.assertEqual(reply["error"]["code"], "runtime_unavailable")
        self.assertEqual(len(sessions), 1)
        sessions[0].close.assert_called_once()
        self.assertTrue(self.invoke("ping")["ok"])

    def test_cleanup_error_fails_closed_but_still_restores_modules_and_environment(self):
        original_close = bridge.close_upstream_databases

        def close(error):
            original_close(error)
            raise RuntimeError("synthetic-cleanup-failure")

        with patch.object(bridge, "close_upstream_databases", side_effect=close):
            reply = self.invoke("ping")
        self.assertEqual(reply["error"]["code"], "runtime_unavailable")
        self.assertNotIn("synthetic", json.dumps(reply))
        self.assertTrue(self.invoke("ping")["ok"])


if __name__ == "__main__":
    unittest.main()
