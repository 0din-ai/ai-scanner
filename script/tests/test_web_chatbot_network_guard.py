"""Unit tests for the WebChatbotGenerator network guard.

The guard keeps Scanner's URL blocklist in force for the browser's whole navigation
lifetime. Its two jobs are screening a host against the blocklist Rails supplies, and
refusing to run at all when that blocklist is absent - browsing unguarded must never
be the fallback. Both are asserted here without a browser so the suite stays runnable
anywhere; the redirect interception itself needs Chromium and is
recorded in the PR that introduced this.
"""
import asyncio
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

PLUGIN_DIR = Path(__file__).resolve().parents[2] / "script" / "garak_plugins"


def _load(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_guard = _load("local_network_guard", "_network_guard.py")
NetworkGuard = _guard.NetworkGuard
NetworkGuardError = _guard.NetworkGuardError

# Mirrors UrlSafetyValidator::BLOCKED_RANGES. Rails passes the real list at runtime;
# this copy exists only so the test can run without Rails.
BLOCKED_CIDRS = [
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "0.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10", "100.64.0.0/10", "240.0.0.0/4",
    "224.0.0.0/4", "255.255.255.255/32", "::/128", "ff00::/8",
]


class TestNetworkGuardScreening(unittest.TestCase):
    def screen(self, url, allow_loopback=False):
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS, "allow_loopback": allow_loopback})
        return asyncio.run(guard.screen(url))

    def assert_blocked(self, url, **kwargs):
        self.assertIsNotNone(self.screen(url, **kwargs), f"expected {url} to be blocked")

    def assert_allowed(self, url, **kwargs):
        self.assertIsNone(self.screen(url, **kwargs), f"expected {url} to be allowed")

    def test_blocks_loopback_rfc1918_and_metadata(self):
        for host in ("127.0.0.1", "10.1.2.3", "172.16.5.5", "192.168.1.1", "169.254.169.254"):
            self.assert_blocked(f"http://{host}/x")

    def test_blocks_carrier_grade_nat_and_reserved_ranges(self):
        for host in ("100.64.0.1", "240.0.0.1", "224.0.0.1", "255.255.255.255", "0.0.0.0"):
            self.assert_blocked(f"http://{host}/x")

    def test_blocks_ipv6_internal_ranges(self):
        for host in ("[::1]", "[fc00::1]", "[fd00::1]", "[fe80::1]", "[ff02::1]"):
            self.assert_blocked(f"http://{host}/x")

    def test_blocks_ipv4_mapped_ipv6_that_would_otherwise_slip_past(self):
        # ::ffff:10.0.0.1 is 10.0.0.1 wearing a v6 costume - it must be screened
        # against the v4 ranges, not waved through for failing to match a v6 one.
        for host in ("[::ffff:10.0.0.1]", "[::ffff:127.0.0.1]", "[::ffff:169.254.169.254]"):
            self.assert_blocked(f"http://{host}/x")

    def test_allows_public_addresses(self):
        for host in ("8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1", "[2001:4860:4860::8888]"):
            self.assert_allowed(f"http://{host}/x")

    def test_rejects_non_http_schemes(self):
        for url in ("file:///etc/passwd", "ftp://8.8.8.8/x", "gopher://8.8.8.8/x"):
            self.assertIsNotNone(self.screen(url), f"expected {url} to be refused")

    def test_rejects_unresolvable_host(self):
        self.assert_blocked("http://this-host-does-not-exist.invalid/x")

    def test_allow_loopback_permits_loopback_only(self):
        # Matches UrlSafetyValidator.allow_localhost? in dev/test: loopback is fine,
        # everything else internal is still refused.
        self.assert_allowed("http://127.0.0.1/x", allow_loopback=True)
        self.assert_allowed("http://[::1]/x", allow_loopback=True)
        self.assert_blocked("http://10.1.2.3/x", allow_loopback=True)
        self.assert_blocked("http://169.254.169.254/x", allow_loopback=True)

    def test_rechecks_a_hostname_instead_of_reusing_an_old_dns_decision(self):
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS})
        guard._resolve = AsyncMock(side_effect=[[guard._parse_ip("93.184.216.34")],
                                                [guard._parse_ip("127.0.0.1")]])

        first = asyncio.run(guard.screen("http://resolution-change.test/first"))
        second = asyncio.run(guard.screen("http://resolution-change.test/second"))

        self.assertIsNone(first)
        self.assertEqual(second, "blocked internal address")


class TestNetworkGuardFailsClosed(unittest.TestCase):
    def test_missing_or_empty_config_refuses_to_construct(self):
        for config in (None, {}, {"blocked_cidrs": []}, {"blocked_cidrs": None}, "nope"):
            with self.assertRaises(NetworkGuardError, msg=f"config {config!r} was accepted"):
                NetworkGuard(config)

    def test_unparsable_cidr_refuses_to_construct(self):
        with self.assertRaises(NetworkGuardError):
            NetworkGuard({"blocked_cidrs": ["10.0.0.0/8", "not-a-cidr"]})

    def test_allow_loopback_defaults_to_false(self):
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS})
        self.assertFalse(guard.allow_loopback)
        # Truthy-but-not-True values must not enable it either.
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS, "allow_loopback": "yes"})
        self.assertFalse(guard.allow_loopback)


class FakeRequest:
    def __init__(self, url):
        self.url = url


class FakeRoute:
    def __init__(self, url):
        self.request = FakeRequest(url)
        self.continued = False
        self.aborted = None

    async def continue_(self):
        self.continued = True

    async def abort(self, reason):
        self.aborted = reason


class TestNetworkGuardRouting(unittest.TestCase):
    def test_allowed_request_continues_without_fetching_or_fulfilling(self):
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS})
        route = FakeRoute("http://93.184.216.34/resource")

        asyncio.run(guard.handle(route))

        self.assertTrue(route.continued)
        self.assertIsNone(route.aborted)

    def test_blocked_report_keeps_a_bounded_sample_and_full_count(self):
        guard = NetworkGuard({"blocked_cidrs": BLOCKED_CIDRS, "report_limit": 3})

        for index in range(5):
            route = FakeRoute(f"http://127.0.0.{index + 1}/resource")
            asyncio.run(guard.handle(route))
            self.assertEqual(route.aborted, "blockedbyclient")

        self.assertEqual(guard.blocked_count, 5)
        self.assertEqual(len(guard.blocked), 3)


if __name__ == "__main__":
    unittest.main()
