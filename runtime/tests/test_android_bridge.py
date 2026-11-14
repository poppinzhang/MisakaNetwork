import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_bridge
import bridge


class AndroidBridgeTests(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.TemporaryDirectory()
        self.addCleanup(self.cache.cleanup)
        self.engine = types.SimpleNamespace()
        self.addCleanup(patch.stopall)
        patch.object(android_bridge, "load_client_engine", return_value=self.engine).start()
        patch.dict(sys.modules, {"loguru": types.SimpleNamespace(logger=types.SimpleNamespace(remove=lambda: None))}).start()

    def invoke(self, request):
        return json.loads(android_bridge.invoke(json.dumps(request), self.cache.name))

    def test_ping_uses_shared_version(self):
        reply = self.invoke({"op": "ping"})
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["data"]["version"], bridge.VERSION)

    def test_buying_is_not_available_in_embedded_client(self):
        self.assertFalse(self.invoke({"op": "run", "params": {}})["ok"])
        android_bridge.load_client_engine.assert_not_called()

    def test_invalid_channel_requests(self):
        for raw in ("", "[]", "null", '{"op":[]}', "{}\n{}", '{"op":"ping","value":NaN}', "x" * (bridge.MAX_REQUEST_BYTES+1)):
            self.assertFalse(json.loads(android_bridge.invoke(raw, self.cache.name))["ok"])

    def test_shared_authentication_policy(self):
        cookies = [{"name": "SESSDATA", "value": "secret"}]
        with patch.object(bridge, "verify_authentication", return_value={"status": "unknown", "logged_in": False}):
            self.assertEqual(self.invoke({"op": "login_state", "params": {"cookies": cookies}})["data"]["status"], "unknown")

    def test_ephemeral_state_and_no_sensitive_output(self):
        observed = []
        def search(*args, **kwargs):
            observed.append(os.environ["MISAKA_RUNTIME_STATE_DIR"])
            print("secret-cookie")
            raise RuntimeError("secret-cookie")
        self.engine.search_tickets = search
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            reply = self.invoke({"op": "search", "params": {"keyword": "concert", "cookies": [{"name": "SESSDATA", "value": "secret-cookie"}]}})
        self.assertFalse(reply["ok"])
        self.assertNotIn("secret-cookie", json.dumps(reply))
        self.assertEqual(output.getvalue(), "")
        self.assertFalse(Path(observed[0]).exists())
        self.assertNotIn("MISAKA_RUNTIME_STATE_DIR", os.environ)

    def test_cache_directory_must_exist(self):
        self.assertFalse(json.loads(android_bridge.invoke('{"op":"ping"}', "relative"))["ok"])


@unittest.skipUnless(
    importlib.util.find_spec("qrcode") is not None and importlib.util.find_spec("png") is not None,
    "Install runtime/requirements-android.lock for real Android QR encoding checks",
)
class AndroidPackagedQrTests(unittest.TestCase):
    """Real qrcode and PyPNG with Pillow hidden, as packaged in the Android app."""

    LOGIN_URL = "https://passport.bilibili.com/h5-app/passport/login/scan?navhide=1&qrcode_key=" + "0" * 32 + "&from="
    PAYMENT = "weixin://wxpay/bizpayurl?pr=synthetic_A-1"

    def setUp(self):
        self.addCleanup(patch.stopall)
        # Desktop environments may have Pillow; hide it like the Android package.
        patch.dict(sys.modules, {
            "PIL": None,
            "qrcode.image.pil": None,
            "loguru": types.SimpleNamespace(logger=types.SimpleNamespace(remove=lambda: None)),
        }).start()
        self.connect = patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")).start()

    def invoke(self, request, engine):
        with tempfile.TemporaryDirectory() as cache, \
                patch.object(android_bridge, "load_client_engine", return_value=engine):
            reply = json.loads(android_bridge.invoke(json.dumps(request), cache))
            self.assertEqual(list(Path(cache).iterdir()), [])
        return reply

    def assert_qr_png(self, encoded, content, box_size):
        import png
        import qrcode
        width, height, rows, _ = png.Reader(bytes=base64.b64decode(encoded, validate=True)).read()
        reference = qrcode.QRCode(box_size=box_size, border=4)
        reference.add_data(content)
        matrix = reference.get_matrix()  # includes the quiet zone
        self.assertEqual((width, height), (len(matrix) * box_size,) * 2)
        pixels = list(rows)
        centre = box_size // 2
        dark = [[pixels[y * box_size + centre][x * box_size + centre] == 0 for x in range(len(matrix))] for y in range(len(matrix))]
        self.assertEqual(dark, matrix)

    def test_login_qr_is_a_real_png_without_pillow(self):
        engine = types.SimpleNamespace(start_qr_login=lambda **kw: {"ok": True, "login_url": self.LOGIN_URL, "qrcode_key": "0" * 32})
        reply = self.invoke({"op": "qr_start", "params": {}}, engine)
        self.assertTrue(reply["ok"], reply.get("error"))
        self.assert_qr_png(reply["data"]["qr_png_base64"], self.LOGIN_URL, box_size=10)
        self.connect.assert_not_called()

    def test_payment_qr_is_a_real_png_without_pillow(self):
        reply = self.invoke({"op": "payment_qr", "params": {"payment_code_url": self.PAYMENT}}, None)
        self.assertTrue(reply["ok"], reply.get("error"))
        self.assert_qr_png(reply["data"]["qr_png_base64"], self.PAYMENT, box_size=6)
        self.connect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
