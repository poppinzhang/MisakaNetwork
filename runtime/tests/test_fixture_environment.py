"""The isolated test environment retains OS location, never host policy."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import fixture_environment


class FixtureEnvironmentTests(unittest.TestCase):
    def test_windows_retains_only_system_locations_and_explicit_fixture_values(self):
        host = {
            "SystemRoot": r"X:\SyntheticWindows", "WINDIR": r"X:\SyntheticWindows",
            "HTTPS_PROXY": "https://synthetic.invalid", "SSL_CERT_FILE": "host-ca.pem",
            "REQUESTS_CA_BUNDLE": "host-ca.pem", "BTB_CREATE_REQUEST_PROXY_STRATEGY": "local_fanout",
            "PATH": "host-tools", "USERPROFILE": "host-profile", "OPENSSL_CONF": "host-openssl.cnf",
        }
        with patch.object(fixture_environment, "os", SimpleNamespace(name="nt", environ=host)):
            actual = fixture_environment.isolated_environment({"MISAKA_RUNTIME_STATE_DIR": "fixture-state"})
        self.assertEqual(actual, {
            "SystemRoot": r"X:\SyntheticWindows", "WINDIR": r"X:\SyntheticWindows",
            "MISAKA_RUNTIME_STATE_DIR": "fixture-state",
        })

    def test_posix_retains_no_host_environment(self):
        with patch.object(fixture_environment, "os", SimpleNamespace(name="posix", environ={"SystemRoot": "host", "HTTPS_PROXY": "host"})):
            self.assertEqual(fixture_environment.isolated_environment(), {})


if __name__ == "__main__":
    unittest.main()
