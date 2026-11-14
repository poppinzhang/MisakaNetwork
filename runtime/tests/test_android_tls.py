"""Check the real Android HTTP transport without sockets or desktop extras."""
from __future__ import annotations

from contextlib import ExitStack
import importlib.util
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

# Public, synthetic test identity only. It is never trusted by the application.
# Fixed PEM fixtures let this test run with the APK's pure-Python dependencies,
# without installing cryptography just to generate a certificate at test time.
CERTIFICATE = """-----BEGIN CERTIFICATE-----
MIIBYDCCAQagAwIBAgIBATAKBggqhkjOPQQDAjAeMRwwGgYDVQQDDBNhbmRyb2lk
LWNsaWVudC50ZXN0MCAXDTIwMDEwMTAwMDAwMFoYDzIxMDAwMTAxMDAwMDAwWjAe
MRwwGgYDVQQDDBNhbmRyb2lkLWNsaWVudC50ZXN0MFkwEwYHKoZIzj0CAQYIKoZI
zj0DAQcDQgAET5lKWWV9CPzU4ZGKgeSV2UHpg9Q8LFT/Ws2jJYLQEuj4d9KRWVj9
NFxBtxDkdxGLFFC+FHjzqTlzaQupXw46g6MzMDEwDwYDVR0TAQH/BAUwAwEB/zAe
BgNVHREEFzAVghNhbmRyb2lkLWNsaWVudC50ZXN0MAoGCCqGSM49BAMCA0gAMEUC
IQDstjl71hDdrJBqbgTZZnVIafsRjwQoeUwcVGKPAy72jAIgTLkqkAIMC4s7SnBo
QE7+pdH3ZmEUkibvoJw4eWch7eA=
-----END CERTIFICATE-----
"""
PRIVATE_KEY = """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg2rk8uBtyAnTAL+do
BZK4sd4Bv4bS8HGDFKhu4AiB6SOhRANCAARPmUpZZX0I/NThkYqB5JXZQemD1Dws
VP9azaMlgtAS6Ph30pFZWP00XEG3EOR3EYsUUL4UePOpOXNpC6lfDjqD
-----END PRIVATE KEY-----
"""

DEPENDENCIES = ("requests", "httpx", "h2", "loguru", "tinydb", "ntplib", "qrcode", "png", "socks")


@unittest.skipUnless(
    all(importlib.util.find_spec(name) is not None for name in DEPENDENCIES),
    "Install runtime/requirements-android.lock for Android TLS checks",
)
class AndroidTransportTLSTests(unittest.TestCase):
    def test_actual_client_rejects_untrusted_and_wrong_hostname_certificates(self):
        captured = []
        process_request = bridge.process_request

        def inspect_transport(request, engine, emit):
            # Use the transport created by the actual MethodChannel adapter,
            # rather than a separately constructed SSLContext or fake client.
            client = sys.modules["util"].main_request._h2_client
            captured.append(client._transport._pool._ssl_context)
            return process_request(request, engine, emit)

        with ExitStack() as stack:
            root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
            cache = root / "cache"
            cache.mkdir()
            stack.enter_context(patch.object(sys, "path", [str(ROOT / "vendor/biliTickerBuy"), *sys.path]))
            stack.enter_context(patch.dict(os.environ, clear=True))
            connect = stack.enter_context(patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")))
            connect_ex = stack.enter_context(patch.object(socket.socket, "connect_ex", side_effect=AssertionError("network forbidden")))
            stack.enter_context(patch.object(bridge, "process_request", inspect_transport))
            reply = json.loads(android_bridge.invoke('{"op":"ping"}', str(cache)))
            self.assertTrue(reply["ok"], reply)
            self.assertEqual(list(cache.iterdir()), [])
            self.assertEqual(len(captured), 1)
            client_context = captured[0]
            self.assertEqual(client_context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(client_context.check_hostname)

            certificate_path, private_path = root / "cert.pem", root / "key.pem"
            certificate_path.write_text(CERTIFICATE, encoding="ascii")
            private_path.write_text(PRIVATE_KEY, encoding="ascii")
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(certificate_path, private_path)

            with self.assertRaises(ssl.SSLCertVerificationError):
                self.handshake(client_context, server_context, "android-client.test")
            client_context.load_verify_locations(cadata=CERTIFICATE)
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.handshake(client_context, server_context, "wrong.test")
            # Prove the failures above are trust/identity checks, not a broken
            # fixture or handshake harness.
            self.handshake(client_context, server_context, "android-client.test")
            connect.assert_not_called()
            connect_ex.assert_not_called()

    @staticmethod
    def handshake(client_context, server_context, hostname):
        client_in, client_out = ssl.MemoryBIO(), ssl.MemoryBIO()
        server_in, server_out = ssl.MemoryBIO(), ssl.MemoryBIO()
        client = client_context.wrap_bio(client_in, client_out, server_hostname=hostname)
        server = server_context.wrap_bio(server_in, server_out, server_side=True)
        client_done = server_done = False
        for _ in range(20):
            try:
                client.do_handshake()
                client_done = True
            except ssl.SSLWantReadError:
                pass
            server_in.write(client_out.read())
            try:
                server.do_handshake()
                server_done = True
            except ssl.SSLWantReadError:
                pass
            client_in.write(server_out.read())
            if client_done and server_done:
                return
        raise AssertionError("in-memory TLS handshake did not complete")


if __name__ == "__main__":
    unittest.main()
