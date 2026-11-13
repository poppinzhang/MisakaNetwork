"""Offline payment endpoint and fallback checks with the pinned engine.

Run with runtime/requirements.lock installed to exercise the real dependencies.
No login, order, external HTTP request or listening socket is used.
"""
from __future__ import annotations

from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import bridge


DEPENDENCIES = ("requests", "httpx", "loguru", "tinydb", "ntplib", "cryptography", "qrcode", "PIL", "socks", "socksio", "zstandard")


@unittest.skipUnless(
    all(importlib.util.find_spec(name) is not None for name in DEPENDENCIES),
    "Install runtime/requirements.lock for real-engine offline security checks",
)
class PaymentRequestSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = ExitStack()
        cls.addClassCleanup(cls.resources.close)
        directory = cls.resources.enter_context(tempfile.TemporaryDirectory(prefix="misaka-security-test-"))
        cls.directory = Path(directory)
        cls.resources.enter_context(patch.dict(sys.modules))
        cls.resources.enter_context(patch.object(sys, "path", list(sys.path)))
        cls.resources.enter_context(patch.dict(os.environ, {
            "MISAKA_RUNTIME_STATE_DIR": directory,
            "BTB_CONFIG_PATH": str(cls.directory / "config.json"),
            "BTB_COOKIES_PATH": str(cls.directory / "cookies.json"),
            "BTB_LOG_DIR": str(cls.directory / "logs"),
            "BTB_SKIP_INITIAL_TIME_SYNC": "1",
        }, clear=True))
        # Fail closed if an import or test starts an actual network connection.
        cls.connect = cls.resources.enter_context(patch.object(socket.socket, "connect", side_effect=AssertionError("network disabled")))
        cls.connect_ex = cls.resources.enter_context(patch.object(socket.socket, "connect_ex", side_effect=AssertionError("network disabled")))
        cls.engine = bridge.load_engine()
        cls.resources.callback(bridge.close_upstream_databases, None)

    def tearDown(self):
        self.connect.assert_not_called()
        self.connect_ex.assert_not_called()

    def test_payment_parameters_use_only_fixed_platform_endpoint_and_keep_fallback(self):
        from task.buy_helpers import build_payment_result_with_fallback
        from util.request.BiliRequest import BiliRequest

        request = BiliRequest(cookies=[{"name": "session", "value": "synthetic-cookie"}])
        self.addCleanup(request.session.close)
        self.addCleanup(request.cookieManager.db.close)
        self.assertIs(request.session.verify, True)
        for response in (
            {"errno": 0, "data": {"code_url": "weixin://wxpay/bizpayurl?pr=synthetic"}},
            {"errno": 0, "data": None},
            {"errno": 1, "data": None},
            {"errno": 0, "data": {"code_url": "https://synthetic.invalid/private"}},
        ):
            with patch.object(request, "get", return_value=SimpleNamespace(json=lambda: response)) as get:
                result, _ = build_payment_result_with_fallback(request, 12)
            get.assert_called_once_with("https://show.bilibili.com/api/ticket/order/getPayParam?order_id=12")
            public = bridge.safe_payment_fields(result)
            self.assertEqual(public["order_id"], "12")
            self.assertEqual(public["order_detail_url"], "https://show.bilibili.com/platform/orderDetail.html?order_id=12")
            self.assertNotIn("private", json.dumps(public))
            self.assertNotIn("synthetic-cookie", json.dumps(public))
            self.assertEqual("payment_code_url" in public, response == {"errno": 0, "data": {"code_url": "weixin://wxpay/bizpayurl?pr=synthetic"}})


if __name__ == "__main__":
    unittest.main()
