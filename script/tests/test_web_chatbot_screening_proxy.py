"""Lifecycle and fail-closed tests for the web-chat screening proxy adapter."""

import asyncio
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"
RUNNER_PATH = ROOT / "app" / "services" / "browser_automation" / "screening_proxy_runner.cjs"


def _load(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_proxy = _load("local_screening_proxy", "_screening_proxy.py")
ScreeningProxyError = _proxy.ScreeningProxyError
ScreeningProxyProcess = _proxy.ScreeningProxyProcess


def proxy_config(**overrides):
    config = {
        "modulePath": str(RUNNER_PATH),
        "blockedCidrs": ["127.0.0.0/8", "::1/128"],
        "connectTimeoutMs": 1000,
    }
    config.update(overrides)
    return config


async def proxy_status(proxy_url, target_url):
    from urllib.parse import urlsplit

    endpoint = urlsplit(proxy_url)
    reader, writer = await asyncio.open_connection(endpoint.hostname, endpoint.port)
    writer.write(
        (
            f"GET {target_url} HTTP/1.1\r\n"
            "Host: 127.0.0.1:9\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
    )
    await writer.drain()
    status_line = await asyncio.wait_for(reader.readline(), timeout=3)
    writer.close()
    await writer.wait_closed()
    return status_line.decode("latin1").strip()


async def can_connect(proxy_url):
    from urllib.parse import urlsplit

    endpoint = urlsplit(proxy_url)
    try:
        _reader, writer = await asyncio.wait_for(
            asyncio.open_connection(endpoint.hostname, endpoint.port), timeout=1
        )
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    await writer.wait_closed()
    return True


class TestScreeningProxyProcess(unittest.IsolatedAsyncioTestCase):
    async def test_real_runner_reports_a_refused_connection_and_closes(self):
        proxy = ScreeningProxyProcess(proxy_config())
        proxy_url = await proxy.start()

        self.assertRegex(proxy_url, r"^http://127\.0\.0\.1:\d+$")
        self.assertEqual(
            await proxy_status(proxy_url, "http://127.0.0.1:9/blocked"),
            "HTTP/1.1 403 Forbidden",
        )

        report = await proxy.close()

        self.assertEqual(report["blocked_request_count"], 1)
        self.assertEqual(proxy.blocked_events[0]["reason"], "blocked-address")
        self.assertFalse(await can_connect(proxy_url))

    async def test_async_context_manager_closes_after_callback_exception(self):
        proxy = ScreeningProxyProcess(proxy_config())
        proxy_url = None

        with self.assertRaisesRegex(RuntimeError, "forced navigation failure"):
            async with proxy:
                proxy_url = proxy.url
                raise RuntimeError("forced navigation failure")

        self.assertIsNotNone(proxy_url)
        self.assertFalse(await can_connect(proxy_url))
        self.assertIsNotNone(proxy.process.returncode)

    async def test_malformed_ready_endpoint_fails_closed_and_reaps_runner(self):
        with tempfile.NamedTemporaryFile("w", suffix=".cjs", delete=False) as runner:
            runner.write(
                "process.stdin.once('data', () => {\n"
                "  console.log(JSON.stringify({type:'ready', proxyUrl:'http://0.0.0.0:1234'}));\n"
                "});\n"
            )
            runner_path = runner.name
        os.chmod(runner_path, 0o700)

        proxy = ScreeningProxyProcess(proxy_config(modulePath=runner_path))
        try:
            with self.assertRaisesRegex(ScreeningProxyError, "invalid ready response"):
                await proxy.start()
            self.assertIsNotNone(proxy.process.returncode)
        finally:
            os.unlink(runner_path)

    async def test_missing_or_invalid_config_refuses_to_start(self):
        for config in (None, {}, {"modulePath": str(RUNNER_PATH), "blockedCidrs": []}):
            with self.subTest(config=config):
                with self.assertRaises(ScreeningProxyError):
                    ScreeningProxyProcess(config)


if __name__ == "__main__":
    unittest.main()
