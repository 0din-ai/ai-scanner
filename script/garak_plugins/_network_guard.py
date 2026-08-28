"""Network guard for the vendored Chromium WebChatbotGenerator.

Standalone so it can be unit-tested without garak or playwright installed; the
Dockerfiles copy it next to web_chatbot.py inside garak/generators/.
"""

import asyncio
import ipaddress
import logging
import socket
from urllib.parse import urlsplit


INERT_SCHEMES = ("data", "blob", "about")


class NetworkGuardError(Exception):
    """Raised when the guard cannot be configured. Never downgraded to a warning:
    an unguarded browser is the bug this class exists to prevent."""


class NetworkGuard:
    """Keeps Scanner's URL blocklist in force for the browser's whole navigation
    lifetime, not just the URL passed to page.goto().

    Rails validates the webchat URL before the scan launches, but nothing re-checks
    where the browser ends up afterwards: an HTTP redirect from the target, or
    JavaScript on the target's own page, can steer it to an address that was never
    screened. The browser runs in the same container as Rails, so that reaches
    whatever the container can reach.

    This route handler is defense in depth: it refuses visible HTTP requests early
    and reports them. The browser's screening proxy owns connection-level DNS
    validation, redirect hops, and WebSocket traffic.

    `blocked_cidrs` is supplied by Rails from UrlSafetyValidator::BLOCKED_RANGES so
    there is one blocklist in the product rather than a Python copy that drifts.

    The handler deliberately continues allowed requests unchanged. Fetching and
    fulfilling them here would buffer streaming responses and duplicate transport
    enforcement already performed by the proxy.
    """

    LOOPBACK = (ipaddress.ip_network("127.0.0.0/8"), ipaddress.ip_network("::1/128"))

    def __init__(self, config):
        if not isinstance(config, dict):
            raise NetworkGuardError("network_guard config missing - refusing to browse unguarded")
        cidrs = config.get("blocked_cidrs") or []
        if not isinstance(cidrs, list) or not cidrs:
            raise NetworkGuardError("network_guard.blocked_cidrs missing - refusing to browse unguarded")
        try:
            self.ranges = [ipaddress.ip_network(c, strict=False) for c in cidrs]
        except ValueError as exc:
            raise NetworkGuardError(f"network_guard.blocked_cidrs unparsable: {exc}") from exc
        self.allow_loopback = config.get("allow_loopback") is True
        report_limit = config.get("report_limit", 50)
        if not isinstance(report_limit, int) or isinstance(report_limit, bool) or report_limit < 0:
            raise NetworkGuardError("network_guard.report_limit must be a non-negative integer")
        self.report_limit = report_limit
        self.blocked = []
        self.blocked_count = 0

    @staticmethod
    def _parse_ip(host):
        """Return an ip_address for a literal host, or None when it is a name.
        IPv4-mapped/compatible v6 is normalized so ::ffff:10.0.0.1 is screened
        against the IPv4 ranges instead of sailing past them."""
        candidate = host.strip()
        if candidate.startswith("[") and candidate.endswith("]"):
            candidate = candidate[1:-1]
        candidate = candidate.split("%", 1)[0]
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError:
            return None
        if isinstance(ip, ipaddress.IPv6Address):
            if ip.ipv4_mapped:
                return ip.ipv4_mapped
        return ip

    async def _resolve(self, host):
        literal = self._parse_ip(host)
        if literal is not None:
            return [literal]
        loop = asyncio.get_event_loop()
        try:
            infos = await loop.getaddrinfo(host, None, type=socket.SOCK_STREAM)
        except (socket.gaierror, OSError):
            return []
        addresses = []
        for info in infos:
            parsed = self._parse_ip(info[4][0])
            if parsed is not None:
                addresses.append(parsed)
        return addresses

    async def _host_allowed(self, host):
        addresses = await self._resolve(host)
        # No usable address is fail-closed, matching the Ruby validator.
        if not addresses:
            verdict = (False, f"could not resolve {host}")
        else:
            verdict = (True, None)
            for address in addresses:
                for network in self.ranges:
                    if address.version != network.version or address not in network:
                        continue
                    if self.allow_loopback and any(
                        address.version == lo.version and address in lo for lo in self.LOOPBACK
                    ):
                        continue
                    verdict = (False, "blocked internal address")
                    break
                if not verdict[0]:
                    break

        return verdict

    async def screen(self, url):
        """Return None when the URL may be fetched, else a rejection reason."""
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            return f"scheme {parts.scheme}"
        if not parts.hostname:
            return "no host"
        allowed, reason = await self._host_allowed(parts.hostname)
        return None if allowed else reason

    def _deny(self, url, reason):
        self.blocked_count += 1
        if len(self.blocked) < self.report_limit:
            self.blocked.append({"url": url[:200], "reason": reason})
        logging.warning("WebChatbotGenerator network guard blocked %s (%s)", url[:200], reason)

    async def handle(self, route):
        request = route.request
        url = request.url

        if urlsplit(url).scheme in INERT_SCHEMES:
            await route.continue_()
            return

        reason = await self.screen(url)
        if reason:
            self._deny(url, reason)
            await route.abort("blockedbyclient")
            return

        await route.continue_()
