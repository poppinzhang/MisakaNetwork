import contextlib
import io
import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
