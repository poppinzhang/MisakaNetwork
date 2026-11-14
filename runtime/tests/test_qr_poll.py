"""Offline QR polling contract, TLS defaults, and verified-Cookie boundary."""
from __future__ import annotations

import importlib.util
from email.message import Message
import json
from pathlib import Path
import socket
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge


class SyntheticNetworkError(Exception):
    pass


def response(payload, *, status=200, cookies=()):
    return SimpleNamespace(
        status_code=status,
        json=Mock(return_value=payload),
        cookies=[SimpleNamespace(name=name, value=value, domain=".bilibili.com", domain_specified=True, path="/", is_expired=lambda: False) for name, value in cookies],
        close=Mock(),
    )


class QrPollTests(unittest.TestCase):
    KEY = "synthetic-qr-key"

    def setUp(self):
        self.get = Mock(side_effect=AssertionError("unexpected network request"))
        self.engine = SimpleNamespace(poll_qr_login=Mock(side_effect=AssertionError("upstream blocking loop forbidden")))
        modules = {"requests": SimpleNamespace(get=self.get, exceptions=SimpleNamespace(RequestException=SyntheticNetworkError))}
        patcher = patch.dict(sys.modules, modules)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.connect = patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")).start()
        self.addCleanup(patch.stopall)

    def tearDown(self):
        self.engine.poll_qr_login.assert_not_called()
        self.connect.assert_not_called()

    def invoke(self, params=None):
        events = []
        code = bridge.process_request({"op": "qr_poll", "params": params if params is not None else {"qrcode_key": self.KEY}}, self.engine, events.append)
        self.assertEqual(len(events), 1)
        return code, events[0]

    def qr_response(self, state, *, status=200):
        value = response({"code": 0, "data": {"code": state, "message": "private-response", "url": "https://private.invalid/cookie"}}, status=status)
        self.get.side_effect = None
        self.get.return_value = value
        return value

    def confirmed_responses(self, identity):
        qr = response({"code": 0, "data": {"code": 0, "url": "https://private.invalid/cookie", "refresh_token": "private-token"}}, cookies=(("SESSDATA", "private-cookie"),))
        self.get.side_effect = [qr, identity]
        return qr

    def assert_safe_state(self, event, status):
        self.assertTrue(event["ok"])
        self.assertEqual(event["data"]["status"], status)
        self.assertEqual(set(event["data"]), {"status", "message"})
        serialized = json.dumps(event)
        for secret in ("private", self.KEY, "cookies", "username", "uid"):
            self.assertNotIn(secret, serialized)

    def test_pending_scanned_and_expired_are_distinct_single_requests(self):
        for state, expected in ((86101, "pending"), (86090, "scanned"), (86038, "expired")):
            with self.subTest(state=state):
                self.get.reset_mock()
                qr = self.qr_response(state)
                code, event = self.invoke()
                self.assertEqual(code, 0)
                self.assert_safe_state(event, expected)
                self.get.assert_called_once_with(
                    bridge.QR_POLL_URL,
                    params={"qrcode_key": self.KEY},
                    headers={"accept": "application/json", "user-agent": "Mozilla/5.0"},
                    timeout=(3.05, 8),
                    allow_redirects=False,
                )
                qr.close.assert_called_once()

    def test_no_local_clock_or_ttl_declares_expiry(self):
        qr = self.qr_response(86101)
        qr.json.return_value.update({"ttl": 0, "expires_in": 0, "timestamp": 0})
        with patch("time.time", return_value=10**12):
            _, event = self.invoke()
        self.assert_safe_state(event, "pending")

    def test_http_errors_never_claim_expiry_or_consume_cookies(self):
        for status in (301, 302, 400, 401, 403, 404, 408, 429, 500, 502, 503, 599):
            with self.subTest(status=status):
                self.get.reset_mock()
                qr = self.qr_response(86038, status=status)
                _, event = self.invoke()
                self.assert_safe_state(event, "transient_error" if status == 429 or status >= 500 else "failed")
                qr.json.assert_not_called()
                self.get.assert_called_once()
                qr.close.assert_called_once()

    def test_transport_error_is_retryable_without_echoing_exception(self):
        self.get.side_effect = SyntheticNetworkError("private-key private-cookie")
        _, event = self.invoke()
        self.assert_safe_state(event, "transient_error")
        self.get.assert_called_once()

    def test_unexpected_failure_is_terminal_without_echoing_exception(self):
        self.get.side_effect = ValueError("private-error")
        _, event = self.invoke()
        self.assert_safe_state(event, "failed")

    def test_malformed_rejected_and_unknown_responses_are_not_expiry(self):
        payloads = (
            None, [], {}, {"code": False, "data": {"code": 86038}},
            {"code": "0", "data": {"code": 86038}},
            {"code": -400, "data": {"code": 86038}, "message": "private"},
            {"code": 0, "data": None}, {"code": 0, "data": []},
            {"code": 0, "data": {}}, {"code": 0, "data": {"code": "86038"}},
            {"code": 0, "data": {"code": False}}, {"code": 0, "data": {"code": 99999}},
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                qr = response(payload)
                self.get.side_effect = None
                self.get.return_value = qr
                _, event = self.invoke()
                self.assert_safe_state(event, "failed")
                qr.close.assert_called_once()

    def test_invalid_json_is_terminal_and_response_is_closed(self):
        qr = self.qr_response(86101)
        qr.json.side_effect = ValueError("private-response")
        _, event = self.invoke()
        self.assert_safe_state(event, "failed")
        qr.close.assert_called_once()

    def test_confirmation_requires_valid_cookie_and_verified_identity(self):
        identity = response({"code": 0, "data": {"isLogin": True, "mid": 123, "uname": "verified-name"}})
        qr = self.confirmed_responses(identity)
        code, event = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(event["data"], {
            "status": "confirmed", "uid": "123", "username": "verified-name",
            "cookies": [{"name": "SESSDATA", "value": "private-cookie"}],
        })
        self.assertEqual([call.args[0] for call in self.get.call_args_list], [bridge.QR_POLL_URL, bridge.NAV_URL])
        self.assertEqual(self.get.call_args_list[1].kwargs["headers"]["cookie"], "SESSDATA=private-cookie")
        self.assertNotIn("private.invalid", json.dumps(event))
        self.assertNotIn("private-token", json.dumps(event))
        for call in self.get.call_args_list:
            self.assertFalse(call.kwargs["allow_redirects"])
            self.assertNotIn("verify", call.kwargs)  # requests' default is True.
        qr.close.assert_called_once()
        identity.close.assert_called_once()

    def test_confirmation_without_cookie_is_terminal_without_identity_request(self):
        self.qr_response(0)
        _, event = self.invoke()
        self.assert_safe_state(event, "failed")
        self.get.assert_called_once()

    def test_confirmation_rejects_malformed_cookie_before_identity_request(self):
        for cookies in ((('bad\r\nname', 'private'),), (('SESSDATA', 'private\r\nheader'),), (('SESSDATA', ''),)):
            with self.subTest(cookies=cookies):
                self.get.reset_mock()
                self.get.side_effect = None
                self.get.return_value = response({"code": 0, "data": {"code": 0}}, cookies=cookies)
                _, event = self.invoke()
                self.assert_safe_state(event, "failed")
                self.get.assert_called_once()

    def test_confirmation_without_verified_identity_requires_new_scan(self):
        for payload in ({"code": -101}, {"code": -500}, {"code": 0, "data": {"isLogin": True, "uname": "private-name"}}):
            with self.subTest(payload=payload):
                self.get.reset_mock()
                self.confirmed_responses(response(payload))
                _, event = self.invoke()
                self.assert_safe_state(event, "failed")
                self.assertIn("重新生成二维码", event["data"]["message"])
                self.assertEqual(self.get.call_count, 2)

    def test_identity_network_failure_is_terminal_not_qr_retryable(self):
        self.confirmed_responses(SyntheticNetworkError("private-identity-error"))
        _, event = self.invoke()
        self.assert_safe_state(event, "failed")
        self.assertIn("账号尚未保存", event["data"]["message"])
        self.assertEqual(self.get.call_count, 2)

    def test_request_allowlist_cannot_override_network_or_polling_policy(self):
        for params in ({}, {"qrcode_key": 1}, {"qrcode_key": ""}, {"qrcode_key": "k" * 2049},
                       {"qrcode_key": "k", "timeout_seconds": 5}, {"qrcode_key": "k", "verify": False},
                       {"qrcode_key": "k", "url": "https://private.invalid"}, {"qrcode_key": "k", "cookies": {"session": "private"}}):
            with self.subTest(params=params):
                code, event = self.invoke(params)
                self.assertEqual(code, 1)
                self.assertEqual(event["error"]["code"], "invalid_request")
                self.assertNotIn("private", json.dumps(event))
        self.get.assert_not_called()


@unittest.skipUnless(importlib.util.find_spec("requests") is not None, "Install runtime requirements for requests TLS-default verification")
class RealRequestsQrTests(unittest.TestCase):
    def cookie_response(self, headers):
        """Use requests' actual Set-Cookie parser, not a manually flattened map."""
        import requests
        from urllib3._collections import HTTPHeaderDict
        from urllib3.response import HTTPResponse

        message = Message()
        for value in headers:
            message.add_header("Set-Cookie", value)
        body = b'{"code":0,"data":{"code":0}}'
        raw = HTTPResponse(
            body=body, status=200, headers=HTTPHeaderDict(message.items()),
            original_response=SimpleNamespace(msg=message, close=lambda: None),
        )
        prepared = requests.Request("GET", bridge.QR_POLL_URL).prepare()
        reply = requests.adapters.HTTPAdapter().build_response(prepared, raw)
        reply._content = body
        reply._content_consumed = True
        self.assertIsInstance(reply.cookies, requests.cookies.RequestsCookieJar)
        return reply

    def poll_response(self, reply):
        import requests

        with patch.object(requests, "get", return_value=reply) as get, \
                patch.object(bridge, "verify_authentication", return_value={"status": "valid", "uid": "123", "username": "verified"}) as verify, \
                patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")) as connect:
            result = bridge.poll_qr_once("synthetic-key")
            get.assert_called_once()
            connect.assert_not_called()
        return result, verify

    def test_root_cross_domain_set_cookies_are_the_only_exported_scope(self):
        reply = self.cookie_response([
            "SESSDATA=synthetic-session; Domain=.bilibili.com; Path=/; Secure; HttpOnly",
            "bili_jct=synthetic-csrf; Domain=bilibili.com; Path=/",
            "host_only=private-host; Path=/",
            "passport_only=private-passport; Domain=passport.bilibili.com; Path=/",
            "restricted=private-path; Domain=.bilibili.com; Path=/x",
            "default_path=private-default; Domain=.bilibili.com",
            "foreign=private-foreign; Domain=example.invalid; Path=/",
            "expired=private-expired; Domain=.bilibili.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:01 GMT",
        ])
        # These narrower cookies really entered the jar and are excluded by the
        # bridge. Foreign domains and expired Set-Cookie are rejected by requests.
        parsed_names = {cookie.name for cookie in reply.cookies}
        self.assertTrue({"host_only", "passport_only", "restricted", "default_path"} <= parsed_names)
        self.assertNotIn("foreign", parsed_names)
        self.assertNotIn("expired", parsed_names)
        result, verify = self.poll_response(reply)
        expected = [{"name": "SESSDATA", "value": "synthetic-session"}, {"name": "bili_jct", "value": "synthetic-csrf"}]
        self.assertEqual(result["status"], "confirmed")
        self.assertEqual(result["cookies"], expected)
        verify.assert_called_once_with(expected)
        self.assertNotIn("private", json.dumps(result))

    def test_only_host_or_path_scoped_set_cookies_cannot_confirm_login(self):
        for header in (
            "SESSDATA=private; Path=/",  # host-only passport cookie
            "SESSDATA=private; Domain=passport.bilibili.com; Path=/",
            "SESSDATA=private; Domain=.bilibili.com; Path=/x",
            "SESSDATA=private; Domain=.bilibili.com",  # default request path
            "SESSDATA=private; Domain=.bilibili.com; Path=/; Max-Age=0",
        ):
            with self.subTest(header=header):
                result, verify = self.poll_response(self.cookie_response([header]))
                self.assertEqual(result["status"], "failed")
                self.assertNotIn("private", json.dumps(result))
                verify.assert_not_called()

    def test_cookie_expiring_after_parsing_is_not_exported(self):
        reply = self.cookie_response(["SESSDATA=private; Domain=.bilibili.com; Path=/; Max-Age=60"])
        cookie = next(iter(reply.cookies))
        self.assertIsInstance(cookie.expires, int)
        with patch("time.time", return_value=cookie.expires + 1):
            result, verify = self.poll_response(reply)
        self.assertEqual(result["status"], "failed")
        verify.assert_not_called()
        self.assertNotIn("private", json.dumps(result))

    def test_same_name_in_narrower_scope_does_not_replace_cross_domain_cookie(self):
        reply = self.cookie_response([
            "SESSDATA=synthetic-session; Domain=.bilibili.com; Path=/",
            "SESSDATA=private-host; Path=/",
            "SESSDATA=private-path; Domain=.bilibili.com; Path=/x",
        ])
        self.assertEqual(len(reply.cookies), 3)
        result, verify = self.poll_response(reply)
        expected = [{"name": "SESSDATA", "value": "synthetic-session"}]
        self.assertEqual(result["status"], "confirmed")
        self.assertEqual(result["cookies"], expected)
        verify.assert_called_once_with(expected)

    def test_duplicate_eligible_cookie_names_are_rejected(self):
        from requests.cookies import create_cookie

        for second_value in ("private-first", "private-second"):
            with self.subTest(second_value=second_value):
                reply = self.cookie_response(["SESSDATA=private-first; Domain=.bilibili.com; Path=/"])
                # requests canonicalizes the two Domain spellings on parsing,
                # but its real CookieJar can also contain distinct domain keys.
                reply.cookies.set_cookie(create_cookie("SESSDATA", second_value, domain="bilibili.com", path="/"))
                self.assertEqual(len(reply.cookies), 2)
                result, verify = self.poll_response(reply)
                self.assertEqual(result["status"], "failed")
                verify.assert_not_called()
                self.assertNotIn("private", json.dumps(result))

    def test_requests_passes_tls_verification_to_adapter_and_never_follows_redirects(self):
        import requests

        observed = []

        def send(adapter, request, **kwargs):
            observed.append((request, kwargs))
            reply = requests.Response()
            reply.status_code = 302
            reply.headers["Location"] = "https://untrusted.invalid/private"
            reply._content = b'{"code":0,"data":{"code":86038}}'
            reply._content_consumed = True
            reply.url = request.url
            reply.request = request
            return reply

        with patch.object(requests.adapters.HTTPAdapter, "send", new=send), \
                patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")) as connect:
            self.assertEqual(bridge.poll_qr_once("synthetic-key")["status"], "failed")
            connect.assert_not_called()
        self.assertEqual(len(observed), 1)
        request, kwargs = observed[0]
        self.assertTrue(request.url.startswith(bridge.QR_POLL_URL + "?"))
        self.assertTrue(kwargs["verify"] is True or isinstance(kwargs["verify"], str) and bool(kwargs["verify"]))
        self.assertEqual(kwargs["timeout"], (3.05, 8))
        self.assertNotIn("Cookie", request.headers)


if __name__ == "__main__":
    unittest.main()
