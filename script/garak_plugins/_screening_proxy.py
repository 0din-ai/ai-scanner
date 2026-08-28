"""Lifecycle adapter for the shared Node screening proxy.

The proxy owns DNS resolution and the exact outbound connection. This module
contains no address-policy implementation; it only starts the shared proxy,
validates its loopback endpoint, and guarantees process teardown.
"""

import asyncio
import contextlib
import json
import logging
import os
import shutil
from pathlib import Path
from urllib.parse import urlsplit


START_TIMEOUT_SECONDS = 10
CLOSE_TIMEOUT_SECONDS = 5
MAX_PROTOCOL_LINE_BYTES = 1024 * 1024


class ScreeningProxyError(Exception):
    """Raised when the proxy cannot be configured or started safely."""


class ScreeningProxyProcess:
    """Own one screening-proxy process for one browser launch."""

    def __init__(self, config):
        if not isinstance(config, dict):
            raise ScreeningProxyError("screening_proxy config missing - refusing to browse unguarded")

        runner_path = config.get("modulePath")
        blocked_cidrs = config.get("blockedCidrs")
        if not isinstance(runner_path, str) or not os.path.isabs(runner_path):
            raise ScreeningProxyError("screening_proxy.modulePath must be an absolute path")
        if not Path(runner_path).is_file():
            raise ScreeningProxyError("screening_proxy.modulePath is not a regular file")
        if not isinstance(blocked_cidrs, list) or not blocked_cidrs:
            raise ScreeningProxyError("screening_proxy.blockedCidrs missing - refusing to browse unguarded")
        if not all(isinstance(cidr, str) and cidr for cidr in blocked_cidrs):
            raise ScreeningProxyError("screening_proxy.blockedCidrs must contain strings")

        node_path = config.get("nodePath") or shutil.which("node")
        if not node_path or not os.path.isabs(node_path) or not os.access(node_path, os.X_OK):
            raise ScreeningProxyError("screening proxy requires an executable Node.js runtime")

        self.config = dict(config)
        self.runner_path = runner_path
        self.node_path = node_path
        self.process = None
        self.url = None
        self.report = {"blocked_requests": [], "blocked_request_count": 0}
        self.blocked_events = []
        self._closed = False

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, _error_type, _error, _traceback):
        await self.close()

    async def start(self):
        if self.process is not None:
            raise ScreeningProxyError("screening proxy process already started")

        try:
            self.process = await asyncio.create_subprocess_exec(
                self.node_path,
                self.runner_path,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=MAX_PROTOCOL_LINE_BYTES,
            )
            payload = (json.dumps(self.config, separators=(",", ":")) + "\n").encode("utf-8")
            if len(payload) > MAX_PROTOCOL_LINE_BYTES:
                raise ScreeningProxyError("screening proxy configuration exceeds the size limit")
            self.process.stdin.write(payload)
            await self.process.stdin.drain()

            message = await self._read_message(START_TIMEOUT_SECONDS)
            endpoint = message.get("proxyUrl") if message.get("type") == "ready" else None
            if not self._valid_endpoint(endpoint):
                detail = message.get("error") if isinstance(message, dict) else None
                suffix = f": {detail}" if detail else ""
                raise ScreeningProxyError(f"screening proxy returned an invalid ready response{suffix}")
            self.url = endpoint
            return endpoint
        except ScreeningProxyError:
            await self._terminate()
            raise
        except Exception as error:
            await self._terminate()
            raise ScreeningProxyError(f"screening proxy failed to start: {error}") from error

    async def close(self):
        if self._closed:
            return self.report
        self._closed = True

        if self.process is None:
            return self.report

        try:
            if self.process.returncode is None and self.process.stdin is not None:
                self.process.stdin.write(b'{"command":"close"}\n')
                await self.process.stdin.drain()
                message = await self._read_message(CLOSE_TIMEOUT_SECONDS)
                if message.get("type") == "closed":
                    self._accept_report(message)
                else:
                    logging.warning(
                        "WebChatbotGenerator screening proxy returned an invalid close response: %s",
                        str(message.get("error") or message.get("type"))[:500],
                    )
        except (BrokenPipeError, ConnectionResetError, ScreeningProxyError) as error:
            logging.warning("WebChatbotGenerator screening proxy cleanup failed: %s", error)
        finally:
            await self._terminate()

        self._log_report()
        return self.report

    async def _read_message(self, timeout):
        try:
            line = await asyncio.wait_for(self.process.stdout.readline(), timeout=timeout)
        except asyncio.TimeoutError as error:
            raise ScreeningProxyError("screening proxy protocol timed out") from error
        except ValueError as error:
            raise ScreeningProxyError("screening proxy protocol line exceeds the size limit") from error
        if not line:
            raise ScreeningProxyError("screening proxy exited before replying")
        try:
            message = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ScreeningProxyError("screening proxy returned invalid JSON") from error
        if not isinstance(message, dict):
            raise ScreeningProxyError("screening proxy returned an invalid protocol message")
        return message

    @staticmethod
    def _valid_endpoint(endpoint):
        if not isinstance(endpoint, str):
            return False
        try:
            parsed = urlsplit(endpoint)
            port = parsed.port
        except ValueError:
            return False
        return (
            parsed.scheme == "http"
            and parsed.hostname == "127.0.0.1"
            and port is not None
            and 1 <= port <= 65535
            and parsed.username is None
            and parsed.password is None
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
        )

    def _accept_report(self, message):
        report = message.get("report")
        events = message.get("blocked_events")
        if isinstance(report, dict):
            requests = report.get("blocked_requests")
            count = report.get("blocked_request_count")
            if isinstance(requests, list) and isinstance(count, int) and count >= len(requests):
                self.report = {
                    "blocked_requests": requests,
                    "blocked_request_count": count,
                }
        if isinstance(events, list):
            self.blocked_events = events

    def _log_report(self):
        count = self.report["blocked_request_count"]
        if count <= 0:
            return
        samples = []
        for event in self.blocked_events:
            if not isinstance(event, dict):
                continue
            samples.append(f"{event.get('reason', 'blocked')} {event.get('target', '')}".strip())
        detail = f": {'; '.join(samples)}" if samples else ""
        logging.warning(
            "WebChatbotGenerator screening proxy blocked %d request(s)%s",
            count,
            detail,
        )

    async def _terminate(self):
        process = self.process
        if process is None:
            return

        if process.stdin is not None and not process.stdin.is_closing():
            process.stdin.close()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                await process.stdin.wait_closed()

        if process.returncode is None:
            try:
                await asyncio.wait_for(process.wait(), timeout=CLOSE_TIMEOUT_SECONDS)
            except asyncio.TimeoutError:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=CLOSE_TIMEOUT_SECONDS)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()

        if process.stderr is not None:
            stderr = await process.stderr.read()
            if stderr:
                logging.warning(
                    "WebChatbotGenerator screening proxy stderr: %s",
                    stderr.decode("utf-8", errors="replace")[:1000],
                )
