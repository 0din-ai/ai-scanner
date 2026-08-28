"""Unit tests for the vendored Chromium WebChatbotGenerator auth support."""
import asyncio
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

_plugins = str(Path(__file__).resolve().parent.parent / "garak_plugins")
if _plugins not in sys.path:
    sys.path.insert(0, _plugins)


def _install_local_generator_module(module_name, filename):
    spec = importlib.util.spec_from_file_location(module_name, Path(_plugins) / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)


_install_local_generator_module("garak.generators._network_guard", "_network_guard.py")
_install_local_generator_module("garak.generators._screening_proxy", "_screening_proxy.py")

try:
    from web_chatbot import WebChatbotGenerator  # noqa: E402
    _IMPORT_ERROR = None
except Exception as exc:  # playwright/garak not present in this interpreter
    WebChatbotGenerator = None
    _IMPORT_ERROR = exc


@unittest.skipUnless(WebChatbotGenerator is not None, f"web_chatbot import unavailable: {_IMPORT_ERROR}")
class TestWebChatbotAuth(unittest.TestCase):
    def test_build_context_kwargs_maps_auth_and_viewport(self):
        kwargs = WebChatbotGenerator._build_context_kwargs(
            {"headers": {"Authorization": "Bearer x"}, "storage_state": {"cookies": []}},
            {"viewport": {"width": 1280, "height": 720}},
        )
        self.assertEqual(kwargs["extra_http_headers"], {"Authorization": "Bearer x"})
        self.assertEqual(kwargs["storage_state"], {"cookies": []})
        self.assertEqual(kwargs["viewport"], {"width": 1280, "height": 720})

    def test_build_context_kwargs_drops_host_header(self):
        kwargs = WebChatbotGenerator._build_context_kwargs(
            {"headers": {"Host": "evil.com", "X-Api": "ok"}}, {}
        )
        self.assertEqual(kwargs["extra_http_headers"], {"X-Api": "ok"})

    def test_normalize_cookies_defaults_path_and_capitalizes_samesite(self):
        out = WebChatbotGenerator._normalize_cookies(
            [{"name": "s", "value": "v", "domain": "example.com", "sameSite": "lax"}]
        )
        self.assertEqual(out[0]["path"], "/")
        self.assertEqual(out[0]["sameSite"], "Lax")

    def test_init_browser_uses_chromium_and_applies_cookies(self):
        gen = object.__new__(WebChatbotGenerator)
        gen.url = "https://example.com/chat"
        gen.browser_options = {"headless": True, "viewport": {"width": 1280, "height": 720}}
        gen.wait_times = {"page_load": 10000, "chat_open": 5000}
        gen.selectors = {"input_field": "#i", "response_container": "#r"}
        gen.auth = {"cookies": [{"name": "s", "value": "secret", "domain": "example.com"}],
                    "headers": {"Authorization": "Bearer t"}, "storage_state": None}
        gen.network_guard = {"blocked_cidrs": ["127.0.0.0/8"]}
        gen.screening_proxy = {
            "modulePath": "/rails/app/services/browser_automation/screening_proxy_runner.cjs",
            "blockedCidrs": ["127.0.0.0/8"],
        }
        gen._playwright = None
        gen._browser = None
        gen._context = None
        gen._page = None
        gen._screening_proxy = None

        context = AsyncMock()
        context.new_page = AsyncMock(return_value=AsyncMock())
        browser = AsyncMock()
        browser.new_context = AsyncMock(return_value=context)
        chromium = MagicMock()
        chromium.launch = AsyncMock(return_value=browser)
        pw = AsyncMock()
        pw.chromium = chromium

        screening_proxy = MagicMock()
        screening_proxy.start = AsyncMock(return_value="http://127.0.0.1:45678")
        screening_proxy.close = AsyncMock(return_value={"blocked_requests": [], "blocked_request_count": 0})

        import web_chatbot as mod
        original = mod.async_playwright
        original_proxy = mod.ScreeningProxyProcess
        mod.async_playwright = lambda: MagicMock(start=AsyncMock(return_value=pw))
        mod.ScreeningProxyProcess = MagicMock(return_value=screening_proxy)
        try:
            asyncio.run(gen._init_browser())
        finally:
            mod.async_playwright = original
            mod.ScreeningProxyProcess = original_proxy

        chromium.launch.assert_awaited_once()
        _, launch_kwargs = chromium.launch.call_args
        self.assertEqual(launch_kwargs["proxy"], {"server": "http://127.0.0.1:45678"})
        self.assertEqual(
            launch_kwargs["args"],
            ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
        )
        browser.new_context.assert_awaited_once()
        _, ctx_kwargs = browser.new_context.call_args
        self.assertEqual(ctx_kwargs["extra_http_headers"], {"Authorization": "Bearer t"})
        context.add_cookies.assert_awaited_once_with(
            [{"name": "s", "value": "secret", "domain": "example.com", "path": "/"}]
        )
        context.route.assert_awaited_once()
        screening_proxy.start.assert_awaited_once()

    def test_init_failure_closes_proxy_and_partial_browser_resources(self):
        gen = object.__new__(WebChatbotGenerator)
        gen.url = "https://example.com/chat"
        gen.browser_options = {"headless": True}
        gen.wait_times = {"page_load": 10000, "chat_open": 5000}
        gen.selectors = {"input_field": "#i", "response_container": "#r"}
        gen.auth = {"cookies": [], "headers": {}, "storage_state": None}
        gen.network_guard = {"blocked_cidrs": ["127.0.0.0/8"]}
        gen.screening_proxy = {
            "modulePath": "/rails/app/services/browser_automation/screening_proxy_runner.cjs",
            "blockedCidrs": ["127.0.0.0/8"],
        }
        gen._playwright = None
        gen._browser = None
        gen._context = None
        gen._page = None
        gen._screening_proxy = None

        page = AsyncMock()
        page.goto = AsyncMock(side_effect=RuntimeError("navigation failed"))
        context = AsyncMock()
        context.new_page = AsyncMock(return_value=page)
        browser = AsyncMock()
        browser.new_context = AsyncMock(return_value=context)
        chromium = MagicMock()
        chromium.launch = AsyncMock(return_value=browser)
        pw = AsyncMock()
        pw.chromium = chromium
        screening_proxy = MagicMock()
        screening_proxy.start = AsyncMock(return_value="http://127.0.0.1:45678")
        screening_proxy.close = AsyncMock(return_value={"blocked_requests": [], "blocked_request_count": 0})

        import web_chatbot as mod
        original = mod.async_playwright
        original_proxy = mod.ScreeningProxyProcess
        mod.async_playwright = lambda: MagicMock(start=AsyncMock(return_value=pw))
        mod.ScreeningProxyProcess = MagicMock(return_value=screening_proxy)
        try:
            with self.assertRaisesRegex(RuntimeError, "navigation failed"):
                asyncio.run(gen._init_browser())
        finally:
            mod.async_playwright = original
            mod.ScreeningProxyProcess = original_proxy

        page.close.assert_awaited_once()
        context.close.assert_awaited_once()
        browser.close.assert_awaited_once()
        pw.stop.assert_awaited_once()
        screening_proxy.close.assert_awaited_once()

    def test_cleanup_timeout_on_page_does_not_skip_proxy_teardown(self):
        gen = object.__new__(WebChatbotGenerator)
        async def hang_during_close():
            await asyncio.sleep(60)

        page = MagicMock()
        page.close = AsyncMock(side_effect=hang_during_close)
        screening_proxy = MagicMock()
        screening_proxy.close = AsyncMock(return_value={"blocked_requests": [], "blocked_request_count": 0})
        gen._page = page
        gen._context = None
        gen._browser = None
        gen._playwright = None
        gen._screening_proxy = screening_proxy

        import web_chatbot as mod
        original_timeout = mod.RESOURCE_CLOSE_TIMEOUT_SECONDS
        mod.RESOURCE_CLOSE_TIMEOUT_SECONDS = 0.01
        try:
            asyncio.run(gen._async_cleanup())
        finally:
            mod.RESOURCE_CLOSE_TIMEOUT_SECONDS = original_timeout

        screening_proxy.close.assert_awaited_once()
        self.assertIsNone(gen._screening_proxy)


if __name__ == "__main__":
    unittest.main()
