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

from fixture_environment import isolated_environment

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
        import ntplib

        cls.resources = ExitStack()
        cls.addClassCleanup(cls.resources.close)
        directory = cls.resources.enter_context(tempfile.TemporaryDirectory(prefix="misaka-security-test-"))
        cls.directory = Path(directory)
        cls.resources.enter_context(patch.dict(sys.modules))
        cls.resources.enter_context(patch.object(sys, "path", list(sys.path)))
        cls.resources.enter_context(patch.dict(os.environ, isolated_environment({
            "MISAKA_RUNTIME_STATE_DIR": directory,
            "BTB_CONFIG_PATH": str(cls.directory / "config.json"),
            "BTB_COOKIES_PATH": str(cls.directory / "cookies.json"),
            "BTB_LOG_DIR": str(cls.directory / "logs"),
            "BTB_SKIP_INITIAL_TIME_SYNC": "1",
        }), clear=True))
        # Fail closed if an import or test starts an actual network connection.
        cls.connect = cls.resources.enter_context(patch.object(socket.socket, "connect", side_effect=AssertionError("network disabled")))
        cls.connect_ex = cls.resources.enter_context(patch.object(socket.socket, "connect_ex", side_effect=AssertionError("network disabled")))
        cls.ntp = cls.resources.enter_context(patch.object(ntplib.NTPClient, "request", side_effect=AssertionError("NTP disabled")))
        cls.engine = bridge.load_engine()
        cls.resources.callback(bridge.close_upstream_databases, None)

    def tearDown(self):
        self.connect.assert_not_called()
        self.connect_ex.assert_not_called()
        self.ntp.assert_not_called()

    @staticmethod
    def linked_ticket():
        return {
            "detail": "synthetic-linked-ticket", "count": 1, "screen_id": 1,
            "project_id": 2, "sku_id": 3, "link_id": 4, "pay_money": 0,
            "buyer_info": [{"name": "synthetic-buyer", "personal_id": "synthetic-id"}],
            "buyer": "synthetic-contact", "tel": "synthetic-phone",
            "deliver_info": {"name": "synthetic-contact", "tel": "synthetic-phone",
                             "addr_id": 1, "addr": "synthetic-address"},
        }

    def test_linked_zero_price_ticket_reaches_order_without_refreshing_child_project(self):
        from task import buy
        from util.request.BiliRequest import BiliRequest

        def post(url, data, isJson):
            self.assertTrue(isJson)
            self.assertIn("project_id=2", url)
            if "/order/prepare?" in url:
                self.assertEqual(data["sku_id"], 3)
                return SimpleNamespace(json=lambda: {
                    "errno": 0, "data": {"token": "fixture-token", "ptoken": "fixture-ptoken"},
                })
            self.assertIn("/order/createV2?", url)
            self.assertEqual(data["link_id"], 4)
            self.assertEqual(data["pay_money"], 0)
            return SimpleNamespace(json=lambda: {"errno": 0, "data": {"orderId": 12}})

        request = {"op": "run", "params": {"config": self.linked_ticket(), "cookies": {"session": "synthetic"}}}
        events = []
        with (
            patch.object(buy, "fetch_project_payload", side_effect=RuntimeError("child project unavailable")) as refresh,
            patch.object(BiliRequest, "prewarm_h2_connection") as prewarm,
            patch.object(BiliRequest, "post", side_effect=post) as send,
            patch.object(BiliRequest, "get", return_value=SimpleNamespace(json=lambda: {"errno": 1})) as payment,
        ):
            status = bridge.process_request(request, self.engine, events.append)
        refresh.assert_not_called()
        prewarm.assert_called_once_with("https://show.bilibili.com/")
        self.assertEqual(send.call_count, 2)
        payment.assert_called_once_with("https://show.bilibili.com/api/ticket/order/getPayParam?order_id=12")
        self.assertEqual(status, 0)
        self.assertEqual(events[-1]["data"], {
            "status": "succeeded", "order_id": "12",
            "order_detail_url": "https://show.bilibili.com/platform/orderDetail.html?order_id=12",
        })

    @staticmethod
    def ntp_reply(**changes):
        import ntplib
        reply = ntplib.NTPStats()
        reply.mode = 4
        reply.stratum = 2
        # A synchronized server a quarter second ahead, with 125 ms round-trip.
        reply.orig_timestamp = 100
        reply.recv_timestamp = reply.tx_timestamp = 100.3125
        reply.dest_timestamp = 100.125
        for name, value in changes.items():
            setattr(reply, name, value)
        return reply

    def test_unusable_ntp_replies_try_the_next_server_and_then_use_local_time(self):
        import ntplib
        from util.TimeUtil import DEFAULT_NTP_SERVERS, create_time_service

        for changes in ({"mode": 3}, {"stratum": 0}, {"stratum": 16}, {"leap": 3},
                        {"orig_timestamp": 0}, {"recv_timestamp": float("nan")},
                        {"dest_timestamp": float("inf")}, {"dest_timestamp": 99}):
            with self.subTest(changes=changes), patch.object(ntplib.NTPClient, "request", return_value=self.ntp_reply(**changes)) as ntp:
                clock = create_time_service()
                self.assertEqual(clock.time_source, "local")
                self.assertEqual(clock.get_timeoffset(), 0)
                self.assertEqual([call.args[0] for call in ntp.call_args_list], list(DEFAULT_NTP_SERVERS))
        with patch.object(ntplib.NTPClient, "request", side_effect=[
            self.ntp_reply(stratum=0), self.ntp_reply(), TimeoutError(), TimeoutError(),
        ]):
            clock = create_time_service()
            self.assertEqual(clock.time_source, f"ntp:{DEFAULT_NTP_SERVERS[1]}")
            self.assertEqual(clock.get_timeoffset(), -0.25)

    def test_scheduled_countdown_and_first_order_share_the_task_clock(self):
        import ntplib
        from task import buy, buy_helpers
        from util.Constant import BEIJING_TZ
        from util.TimeUtil import DEFAULT_NTP_SERVERS
        from util.request.BiliRequest import BiliRequest

        target = datetime(2030, 1, 2, tzinfo=BEIJING_TZ)
        system_start = target.timestamp() - 0.5
        schedule = target.strftime(bridge.TIME_START_FORMAT)
        earlier = (target - timedelta(seconds=1)).strftime(bridge.TIME_START_FORMAT)
        failed = [TimeoutError() for _ in DEFAULT_NTP_SERVERS]
        # Expected order time is expressed in milliseconds relative to target.
        for start, delay, responses, wait_ms, order_offset_ms in (
            (schedule, None, [self.ntp_reply()], 280, 30),
            (schedule, 0, [self.ntp_reply()], 250, 0),
            (schedule, 90, failed, 590, 90),
            (earlier, 900, [self.ntp_reply()], 150, -100),  # sale passed, delay still pending
            (earlier, None, [self.ntp_reply()], 0, -250),   # queued past the entire delay
            ("", 60000, [], 0, -500),                       # no calibration or wait
        ):
            with self.subTest(start=start, delay=delay, responses=len(responses)):
                elapsed = 0.0

                def sleep(seconds):
                    nonlocal elapsed
                    elapsed += seconds
                    self.assertLess(elapsed, 2, "countdown must use the simulated task clock")

                simulated_time = SimpleNamespace(time=lambda: system_start + elapsed,
                                                 perf_counter=lambda: elapsed, sleep=sleep)
                options = {"time_start": start}
                if delay is not None:
                    options["start_delay_ms"] = delay
                params = {"runtime_options": options, "config": self.linked_ticket(), "cookies": {"session": "synthetic"}}
                prepare = SimpleNamespace(json=lambda: {"errno": 0, "data": {"token": "fixture", "ptoken": "fixture"}})
                create = SimpleNamespace(json=lambda: {"errno": 0, "data": {"orderId": 12}})
                with (
                    patch.dict(os.environ, {"BTB_NTP_SERVERS": "untrusted.invalid", "BTB_USE_LOCAL_TIME": "true",
                                            "BTB_SKIP_INITIAL_TIME_SYNC": "1", "BTB_START_DELAY_MS": "35000"}),
                    patch.object(ntplib.NTPClient, "request", side_effect=responses) as ntp,
                    patch("util.TimeUtil.time", simulated_time),
                    patch.object(buy_helpers, "time", simulated_time),
                    patch("requests.get", side_effect=AssertionError("HTTP Date probe forbidden")) as date_probe,
                    patch.object(buy, "init_ctoken_state", wraps=buy.init_ctoken_state) as collect,
                    patch.object(BiliRequest, "prewarm_h2_connection"),
                    patch.object(BiliRequest, "post", side_effect=[prepare, create]) as send,
                    patch.object(BiliRequest, "get", return_value=SimpleNamespace(json=lambda: {"errno": 1})),
                ):
                    result = bridge.run_task(params, self.engine, lambda event: None)
                self.assertEqual(result["status"], "succeeded")
                self.assertAlmostEqual(elapsed, wait_ms / 1000)
                expected_servers = DEFAULT_NTP_SERVERS[:len(responses)]
                self.assertEqual([call.args[0] for call in ntp.call_args_list], list(expected_servers))
                self.assertTrue(all(call.kwargs == {"version": 4, "timeout": 1.2} for call in ntp.call_args_list))
                date_probe.assert_not_called()
                expected_ms = int(target.timestamp() * 1000) + order_offset_ms
                self.assertEqual(collect.call_args.kwargs["ticket_collection_t"], expected_ms)
                self.assertEqual(send.call_args.kwargs["data"]["timestamp"], expected_ms)

    def test_ticket_config_environment_and_database_cannot_override_runtime_policy(self):
        from app_cmd.config.BuyConfig import BuyConfig
        from app_cmd.config.NotifierConfig import NotifierConfig
        from util import ConfigDB
        from util.notifer.Notifier import NotifierManager

        hostile_options = {
            "use_local_time": True, "start_delay_ms": 36000,
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
            params = {"config": config, "cookies": {"session": "synthetic-cookie"}}
            bridge.run_task(params, self.engine, output.append)
            self.assertEqual(buy.call_args.kwargs["config"].interval, 500)
            self.assertEqual(buy.call_args.kwargs["config"].start_delay_ms, 30)
            self.assertTrue(buy.call_args.kwargs["config"].use_local_time)
            result = bridge.run_task({**params, "runtime_options": {"interval": 750, "time_start": "2030-01-01T00:00:00"}}, self.engine, output.append)
            actual = buy.call_args.kwargs["config"]
            self.assertIsInstance(actual, BuyConfig)
            self.assertEqual(actual.interval, 750)
            self.assertEqual(actual.start_delay_ms, 30)
            self.assertFalse(actual.use_local_time)
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
