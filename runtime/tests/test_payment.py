"""Offline payment projection and QR encoding, with synthetic order data only."""
from __future__ import annotations

import base64
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_bridge
import bridge

WECHAT = "weixin://wxpay/bizpayurl?pr=synthetic_A-1"
ALIPAY = "https://qr.alipay.com/synthetic_A-1"
ORDER_URL = "https://show.bilibili.com/platform/orderDetail.html?order_id=12"


class SyntheticImageFactory:
    pass


def encoder_modules(make):
    return {
        "qrcode": SimpleNamespace(make=make),
        "qrcode.image.pil": SimpleNamespace(PilImage=SyntheticImageFactory),
    }


class PaymentTests(unittest.TestCase):
    def invoke(self, request, engine=None):
        events = []
        code = bridge.process_request(request, engine, events.append)
        return code, events

    def stream(self, *states):
        modules = {
            "app_cmd.config.BuyConfig": SimpleNamespace(BuyConfig=SimpleNamespace(from_runtime_options=lambda *a: {})),
            "task.buy": SimpleNamespace(Buy=lambda **kw: SimpleNamespace(stream=lambda: iter(
                SimpleNamespace(message="synthetic-secret", state=SimpleNamespace(**state)) for state in states
            ))),
            "task.buy_helpers": SimpleNamespace(CREATE_ORDER_TERMINAL_RULES={}),
        }
        engine = SimpleNamespace(
            validate_config=lambda c: SimpleNamespace(ok=True, normalized_config=c),
            build_runtime_options=lambda **kw: kw,
        )
        with patch.dict(sys.modules, modules):
            return self.invoke({"op": "run", "params": {"config": {}, "cookies": {"session": "synthetic-cookie"}}}, engine)

    def test_payload_allowlist_and_boundaries(self):
        for prefix in ("weixin://wxpay/bizpayurl?pr=", "https://qr.alipay.com/"):
            for token in ("a", "A_-09", "a" * 512):
                with self.subTest(prefix=prefix, length=len(token)):
                    self.assertEqual(bridge.safe_payment_code(prefix + token), prefix + token)
            for token in ("", "a" * 513, "a" * 2049, "例", "%41", "a+b", "a/b", "a=b"):
                self.assertIsNone(bridge.safe_payment_code(prefix + token))

    def test_rejects_url_ambiguity_and_arbitrary_schemes(self):
        invalid = (
            None, False, 123, [], {}, "javascript:alert(1)", "file:///tmp/private",
            "http://qr.alipay.com/abc", "HTTPS://qr.alipay.com/abc", "https://QR.alipay.com/abc",
            "https://qr.alipay.com.evil.test/abc", "https://evil.test/qr.alipay.com/abc",
            "https://user:password@qr.alipay.com/abc", "https://qr.alipay.com@evil.test/abc",
            "https://qr.alipay.com:443/abc", "https://qr.alipay.com./abc", "https://qr.alipay.com/abc/",
            "https://qr.alipay.com/../abc", "https://qr.alipay.com/%61bc", "https://qr.alipay.com/abc?x=1",
            "https://qr.alipay.com/abc#fragment", "https://qr.alipay.com\\@evil.test/abc",
            "weixin://wxpay:80/bizpayurl?pr=abc", "weixin://user@wxpay/bizpayurl?pr=abc",
            "weixin://wxpay/bizpayurl?pr=abc&pr=def", "weixin://wxpay/bizpayurl?pr=abc&redirect=https://evil.test",
            "weixin://wxpay/bizpayurl?PR=abc", "weixin://wxpay/bizpayurl?pr=abc#fragment",
            "weixin://wxpay/bizpayurl?pr=%61bc", "weixin://wxpay/bizpayurl/?pr=abc",
            " " + WECHAT, WECHAT + " ", WECHAT + "\n", WECHAT + "\r", WECHAT + "\x00",
            WECHAT + "\t", "weixin://wxpay/bizpayurl?pr=abc\u202e",
            ORDER_URL,
        )
        for value in invalid:
            with self.subTest(value=value):
                self.assertIsNone(bridge.safe_payment_code(value))

    def test_order_identity_is_required_and_canonical(self):
        for value in (None, "", False, True, 0, -1, 12.0, "0", "01", "12 ", " 12", "+12", "12\n", "１２", "١٢", "1" * 81, 10**1000, [], {}):
            with self.subTest(value=type(value).__name__):
                self.assertEqual(bridge.safe_payment_fields({"order_id": value, "payment_code_url": WECHAT}), {})
        for value in (1, "1", "9" * 80, 10**79):
            expected = str(value)
            self.assertEqual(bridge.safe_payment_fields({"order_id": value})["order_id"], expected)

    def test_order_page_is_reconstructed_and_qr_alias_is_not_payment(self):
        for code in (None, "https://evil.test/synthetic-secret"):
            actual = bridge.safe_payment_fields({
                "order_id": "12", "order_detail_url": "https://evil.test/synthetic-secret",
                "payment_qr_url": WECHAT, "payment_code_url": code,
                "cookies": "synthetic-secret", "buyer": "synthetic-secret",
            })
            self.assertEqual(actual, {"order_id": "12", "order_detail_url": ORDER_URL})
        self.assertEqual(bridge.safe_payment_fields(SimpleNamespace(order_id=12, payment_code_url=ALIPAY)), {
            "order_id": "12", "order_detail_url": ORDER_URL, "payment_code_url": ALIPAY,
        })

    def test_only_confirmed_results_carry_payment_data(self):
        for status in ("running", "completed", "failed", "cancelled"):
            _, events = self.stream({"status": status, "order_id": 12, "payment_code_url": WECHAT})
            self.assertNotIn("order_id", events[-1]["data"])
            self.assertNotIn("payment_code_url", events[-1]["data"])
        for status in ("succeeded", "duplicate_order"):
            code, events = self.stream({"status": status, "order_id": 12, "payment_code_url": WECHAT})
            self.assertEqual(code, 0)
            self.assertEqual(events[-1]["data"], {"status": status, "order_id": "12", "order_detail_url": ORDER_URL, "payment_code_url": WECHAT})
            self.assertNotIn(WECHAT, json.dumps(events[:-1]))
            self.assertNotIn("synthetic-secret", json.dumps(events))

    def test_missing_or_invalid_payment_does_not_undo_success(self):
        for status in ("succeeded", "duplicate_order"):
            for payload in (None, ORDER_URL, "https://evil.test/synthetic-secret"):
                code, events = self.stream({"status": status, "order_id": 12, "payment_code_url": payload}, {"status": "failed"})
                self.assertEqual(code, 0)
                self.assertEqual(events[-1]["data"], {"status": status, "order_id": "12", "order_detail_url": ORDER_URL})
        _, events = self.stream({"status": "duplicate_order"})
        self.assertEqual(events[-1]["data"], {"status": "duplicate_order"})

    def test_later_same_order_event_keeps_code_but_new_order_clears_it(self):
        first = {"status": "succeeded", "order_id": 12, "payment_code_url": WECHAT}
        _, events = self.stream(first, {"status": "succeeded", "order_id": 12})
        self.assertEqual(events[-1]["data"]["payment_code_url"], WECHAT)
        _, events = self.stream(first, {"status": "duplicate_order", "order_id": 13})
        self.assertEqual(events[-1]["data"]["order_id"], "13")
        self.assertNotIn("payment_code_url", events[-1]["data"])

    def mock_encoder(self):
        def save(buffer):
            self.assertIsInstance(buffer, io.BytesIO)
            buffer.write(b"synthetic-png")
        return Mock(return_value=SimpleNamespace(save=save))

    def test_local_qr_is_in_memory_and_needs_no_engine_or_network(self):
        make = self.mock_encoder()
        with patch.dict(sys.modules, encoder_modules(make)), \
                patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")) as connect:
            code, events = self.invoke({"op": "payment_qr", "params": {"payment_code_url": WECHAT}})
        self.assertEqual(code, 0)
        make.assert_called_once_with(WECHAT, box_size=6, border=4, image_factory=SyntheticImageFactory)
        self.assertEqual(events[-1]["data"], {"qr_png_base64": base64.b64encode(b"synthetic-png").decode("ascii")})
        connect.assert_not_called()

    def test_local_qr_rejects_extra_parameters_and_redacts_failure(self):
        make = Mock(side_effect=RuntimeError("synthetic-secret"))
        with patch.dict(sys.modules, encoder_modules(make)):
            for params in ({}, {"payment_code_url": "https://evil.test/synthetic-secret"}, {"payment_code_url": WECHAT, "cookies": "synthetic-secret"}):
                code, events = self.invoke({"op": "payment_qr", "params": params})
                self.assertEqual(code, 1)
                self.assertEqual(events[-1]["error"]["code"], "invalid_request")
                self.assertNotIn("synthetic-secret", json.dumps(events))
            make.assert_not_called()
            code, events = self.invoke({"op": "payment_qr", "params": {"payment_code_url": WECHAT}})
            self.assertEqual(code, 1)
            self.assertNotIn("synthetic-secret", json.dumps(events))
            self.assertNotIn(WECHAT, json.dumps(events))

    def test_local_qr_explicitly_selects_pypng_when_pillow_is_absent(self):
        make = self.mock_encoder()
        modules = encoder_modules(make)
        modules["qrcode.image.pil"] = None
        modules["qrcode.image.pure"] = SimpleNamespace(PyPNGImage=SyntheticImageFactory)
        with patch.dict(sys.modules, modules):
            code, _ = self.invoke({"op": "payment_qr", "params": {"payment_code_url": WECHAT}})
        self.assertEqual(code, 0)
        make.assert_called_once_with(WECHAT, box_size=6, border=4, image_factory=SyntheticImageFactory)

    def test_desktop_qr_skips_upstream_initialization(self):
        output = io.BytesIO()
        request = json.dumps({"op": "payment_qr", "params": {"payment_code_url": WECHAT}}).encode("ascii")
        with patch.dict(os.environ), patch.object(sys, "argv", ["bridge.py"]), \
                patch.object(sys, "stdin", SimpleNamespace(buffer=io.BytesIO(request))), \
                patch.object(sys, "stdout", SimpleNamespace(buffer=output)), \
                patch.object(bridge.signal, "signal"), patch.object(bridge.os, "umask"), patch.object(bridge.logging, "disable"), \
                patch.object(bridge, "load_engine", side_effect=AssertionError("upstream forbidden")) as load, \
                patch.object(bridge, "close_upstream_databases"), \
                patch.dict(sys.modules, encoder_modules(self.mock_encoder())):
            self.assertEqual(bridge.main(), 0)
        load.assert_not_called()
        reply = json.loads(output.getvalue())
        self.assertTrue(reply["ok"])
        self.assertNotIn(WECHAT, output.getvalue().decode("ascii"))

    def test_android_qr_skips_upstream_and_keeps_private_output(self):
        output = io.StringIO()
        def make(*args, **kwargs):
            print("synthetic-secret")
            return self.mock_encoder()(*args, **kwargs)
        with tempfile.TemporaryDirectory() as cache, \
                patch.object(android_bridge, "load_client_engine", side_effect=AssertionError("upstream forbidden")) as load, \
                patch.dict(sys.modules, encoder_modules(make)), \
                redirect_stdout(output), redirect_stderr(output):
            reply = json.loads(android_bridge.invoke(json.dumps({"op": "payment_qr", "params": {"payment_code_url": ALIPAY}}), cache))
            self.assertEqual(list(Path(cache).iterdir()), [])
        self.assertTrue(reply["ok"])
        self.assertEqual(output.getvalue(), "")
        load.assert_not_called()


@unittest.skipUnless(importlib.util.find_spec("qrcode") is not None, "Install runtime/requirements.lock for real QR encoding checks")
class RealPaymentQrTests(unittest.TestCase):
    def test_android_adapter_encodes_real_png_without_loading_engine(self):
        with tempfile.TemporaryDirectory() as cache, \
                patch.object(android_bridge, "load_client_engine", side_effect=AssertionError("upstream forbidden")) as load, \
                patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")) as connect:
            reply = json.loads(android_bridge.invoke(json.dumps({"op": "payment_qr", "params": {"payment_code_url": WECHAT}}), cache))
            self.assertTrue(reply["ok"])
            self.assertTrue(base64.b64decode(reply["data"]["qr_png_base64"], validate=True).startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(list(Path(cache).iterdir()), [])
        load.assert_not_called()
        connect.assert_not_called()

    def test_bounded_real_png_without_network_or_upstream(self):
        with patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")) as connect:
            for payload in (WECHAT, ALIPAY, "weixin://wxpay/bizpayurl?pr=" + "a" * 512):
                events = []
                self.assertEqual(bridge.process_request({"op": "payment_qr", "params": {"payment_code_url": payload}}, None, events.append), 0)
                data = base64.b64decode(events[-1]["data"]["qr_png_base64"], validate=True)
                self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
                width, height = struct.unpack(">II", data[16:24])
                self.assertEqual(width, height)
                self.assertGreater(width, 6 * 8)
                self.assertLessEqual(width, 1200)
                self.assertLess(len(data), 256 * 1024)
        connect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
