"""Unit tests for the vendored Chromium WebChatbotGenerator auth support."""
import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

_plugins = str(Path(__file__).resolve().parent.parent / "garak_plugins")
if _plugins not in sys.path:
    sys.path.insert(0, _plugins)

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
        gen._playwright = None

        context = AsyncMock()
        context.new_page = AsyncMock(return_value=AsyncMock())
        browser = AsyncMock()
        browser.new_context = AsyncMock(return_value=context)
        chromium = MagicMock()
        chromium.launch = AsyncMock(return_value=browser)
        pw = AsyncMock()
        pw.chromium = chromium

        import web_chatbot as mod
        original = mod.async_playwright
        mod.async_playwright = lambda: MagicMock(start=AsyncMock(return_value=pw))
        try:
            asyncio.run(gen._init_browser())
        finally:
            mod.async_playwright = original

        chromium.launch.assert_awaited_once()
        browser.new_context.assert_awaited_once()
        _, ctx_kwargs = browser.new_context.call_args
        self.assertEqual(ctx_kwargs["extra_http_headers"], {"Authorization": "Bearer t"})
        context.add_cookies.assert_awaited_once_with(
            [{"name": "s", "value": "secret", "domain": "example.com", "path": "/"}]
        )


if __name__ == "__main__":
    unittest.main()
