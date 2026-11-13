"""Offline checks of the pinned engine's configuration and TLS client paths.

Run with runtime/requirements.lock installed to exercise the real dependencies.
No login, order, external HTTP request or listening socket is used.
"""
from __future__ import annotations

from contextlib import ExitStack
from dataclasses import fields
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import socket
import ssl
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
class EmbeddedRuntimeSecurityTests(unittest.TestCase):
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

    def test_ticket_config_environment_and_database_cannot_override_runtime_policy(self):
        from app_cmd.config.BuyConfig import BuyConfig
        from app_cmd.config.NotifierConfig import NotifierConfig
        from util import ConfigDB
        from util.notifer.Notifier import NotifierManager

        hostile_options = {
            "create_request_proxy_strategy": "local_fanout", "create_retry_limit": 1,
            "create_request_batch_size": 99, "interval": 1, "notify_proxy_exhausted": True,
            "https_proxys": "http://synthetic.invalid", "proxy_api_url": "https://synthetic.invalid",
        }
        hostile_env = {
            "BTB_CREATE_REQUEST_PROXY_STRATEGY": "local_fanout", "BTB_CREATE_RETRY_LIMIT": "1",
            "BTB_CREATE_REQUEST_BATCH_SIZE": "99", "BTB_INTERVAL": "1", "BTB_NOTIFY_PROXY_EXHAUSTED": "true",
            "BTB_HTTPS_PROXYS": "http://synthetic.invalid", "BTB_PROXY_API_URL": "https://synthetic.invalid",
        }
        for item in fields(NotifierConfig):
            if item.type not in (str, "str"):
                continue
            hostile_options[item.metadata["runtime"]] = "synthetic-secret"
            hostile_env[item.metadata["env"]] = "synthetic-secret"
            ConfigDB.insert(item.metadata["db"], "synthetic-secret")
        ConfigDB.insert("requestInterval", 1)
        ConfigDB.insert("createRetryLimit", 1)
        config = self.engine.generate_ticket_config({
            "detail": "synthetic-event", "count": 1, "screen_id": 1,
            "project_id": 1, "sku_id": 1, "pay_money": 100,
            "buyer_info": [{"name": "synthetic-buyer", "personal_id": "synthetic-id"}],
            "buyer": "synthetic-contact", "tel": "synthetic-phone",
            "deliver_info": {"name": "synthetic-contact", "tel": "synthetic-phone", "addr_id": 1, "addr": "synthetic-address"},
        })
        # Inject after generating the ticket fields so future upstream
        # normalization cannot silently remove this test's hostile input.
        config.update(hostile_options)
        output = []
        with patch.dict(os.environ, hostile_env), \
                patch("requests.sessions.Session.request", side_effect=AssertionError("HTTP disabled")) as requests_call, \
                patch("httpx.Client.request", side_effect=AssertionError("HTTP disabled")) as httpx_call, \
                patch("task.buy.Buy", return_value=SimpleNamespace(stream=lambda: iter([]))) as buy:
            result = bridge.run_task({"config": config, "cookies": {"session": "synthetic-cookie"}, "runtime_options": {"interval": 750}}, self.engine, output.append)
            actual = buy.call_args.kwargs["config"]
            self.assertIsInstance(actual, BuyConfig)
            self.assertEqual(actual.interval, 750)
            self.assertEqual(actual.create_retry_limit, 40)
            self.assertEqual(actual.create_request_batch_size, 1)
            self.assertEqual(actual.create_request_proxy_strategy, "standard")
            self.assertEqual(actual.https_proxys, "none")
            self.assertEqual(actual.proxy_api_url, "")
            for item in fields(NotifierConfig):
                if item.type in (str, "str"):
                    self.assertEqual(getattr(actual.notifier_config, item.name), "", item.name)
            self.assertFalse(actual.notifier_config.notify_proxy_exhausted)
            manager = NotifierManager.create_from_config(actual.notifier_config, "synthetic-title", "synthetic-buyer")
            self.assertEqual(manager.list_notifiers(), [])
            self.assertEqual(manager.send_all_sync("synthetic-title", "synthetic-buyer"), {})
            requests_call.assert_not_called()
            httpx_call.assert_not_called()
        self.assertEqual(result, {"status": "completed"})
        self.assertNotIn("synthetic-", json.dumps(output))

    def test_standard_http_client_rejects_untrusted_and_wrong_hostname_certificates(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        from util.request.BiliRequest import BiliRequest

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ticket.test")])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                       .public_key(key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(hours=1))
                       .add_extension(x509.SubjectAlternativeName([x509.DNSName("ticket.test")]), critical=False)
                       .sign(key, hashes.SHA256()))
        certificate_pem = certificate.public_bytes(serialization.Encoding.PEM)
        certificate_path = self.directory / "test-cert.pem"
        private_path = self.directory / "test-key.pem"
        certificate_path.write_bytes(certificate_pem)
        private_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(certificate_path, private_path)
        request = BiliRequest(cookies=[{"name": "session", "value": "synthetic-cookie"}])
        self.addCleanup(request.session.close)
        self.addCleanup(request.cookieManager.db.close)
        self.assertIs(request.session.verify, True)
        with request._build_h2_client() as client:
            # Inspect the context of the actual pinned httpx transport used by
            # BiliRequest, then handshake over memory BIOs without opening sockets.
            context = client._transport._pool._ssl_context
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.handshake(context, server_context, "ticket.test")
            context.load_verify_locations(cadata=certificate_pem.decode("ascii"))
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.handshake(context, server_context, "wrong.test")
            self.handshake(context, server_context, "ticket.test")

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
