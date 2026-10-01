#!/usr/bin/env python3
"""Behavioral tests for Otari using only a local OpenAI-compatible stub."""

import importlib.util
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from garak.attempt import Conversation, Message, Turn
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"
sys.path.insert(0, str(PLUGIN_DIR))
from otari import OtariGenerator, OtariPolicyBlock  # noqa: E402


class StubHandler(BaseHTTPRequestHandler):
    payload = {}
    requests = []
    response_headers = {}
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(body)
        response = json.dumps(type(self).payload).encode()
        self.send_response(403 if type(self).payload.get("status") == 403 else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        for name, value in type(self).response_headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args):
        pass


class OtariGeneratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.endpoint = f"http://127.0.0.1:{cls.server.server_port}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def setUp(self):
        StubHandler.requests = []
        StubHandler.response_headers = {}
        self.environment = patch.dict(os.environ, {
            "OTARI_API_ENDPOINT": self.endpoint,
            "OTARI_API_KEY": "test-only-key",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_passes_otari_slug_and_preserves_reported_provider_provenance(self):
        StubHandler.payload = {
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 0,
            "model": "openai:configured-model",
            "provider": "openrouter",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "stub reply"}, "finish_reason": "stop"}],
        }
        generator = OtariGenerator(name="openai:configured-model")
        generator.temperature = 0
        generator.top_p = 0.2
        result = generator.generate(Conversation([Turn("user", Message(text="probe prompt"))]))[0]

        self.assertEqual(StubHandler.requests[0]["model"], "openai:configured-model")
        self.assertEqual(StubHandler.requests[0]["temperature"], 0)
        self.assertEqual(StubHandler.requests[0]["top_p"], 0.2)
        self.assertEqual(result.text, "stub reply")
        self.assertEqual(result.notes, {
            "gateway": "otari",
            "serving_provider": "openrouter",
            "requested_provider": "openai",
            "requested_model": "openai:configured-model",
            "fallback_used": True,
        })

    def test_unknown_serving_provider_is_not_inferred_from_requested_model(self):
        StubHandler.payload = {
            "id": "chatcmpl-test", "object": "chat.completion", "created": 0,
            "model": "openai:configured-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "stub reply"}, "finish_reason": "stop"}],
        }
        result = OtariGenerator(name="openai:configured-model")._call_model("probe prompt")[0]
        self.assertEqual(result.notes["gateway"], "otari")
        self.assertEqual(result.notes["serving_provider"], "unknown")
        self.assertIsNone(result.notes["fallback_used"])

    def test_direct_provider_is_explicitly_not_a_fallback(self):
        StubHandler.payload = {
            "id": "chatcmpl-test", "object": "chat.completion", "created": 0,
            "model": "openai:configured-model", "provider": "openai",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "stub reply"}, "finish_reason": "stop"}],
        }
        result = OtariGenerator(name="openai:configured-model")._call_model("probe prompt")[0]
        self.assertEqual(result.notes["serving_provider"], "openai")
        self.assertFalse(result.notes["fallback_used"])

    def test_403_policy_block_is_terminal_and_typed(self):
        StubHandler.payload = {
            "status": 403,
            "error": {"code": "user_blocked", "message": "user blocked for policy violation authorization=local-test-key"},
        }
        generator = OtariGenerator(name="openai:configured-model")
        with self.assertRaises(OtariPolicyBlock) as raised:
            generator._call_model("probe prompt")
        self.assertEqual(raised.exception.status_code, 403)
        self.assertIn("provider_policy_block", str(raised.exception))
        self.assertNotIn("local-test-key", str(raised.exception))
        self.assertNotIn("refusal", str(raised.exception).lower())

    def test_response_headers_preserve_serving_provider(self):
        StubHandler.payload = {
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 0,
            "model": "openai:configured-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "stub reply"}, "finish_reason": "stop"}],
        }
        StubHandler.response_headers = {"x-otari-serving-provider": "openrouter"}

        result = OtariGenerator(name="openai:configured-model")._call_model("probe prompt")[0]

        self.assertEqual(result.notes["serving_provider"], "openrouter")
        self.assertTrue(result.notes["fallback_used"])

    def test_policy_error_envelopes_are_terminal(self):
        for error in ("policy_violation", {"type": "policy_violation", "message": "request denied"}):
            with self.subTest(error=error):
                StubHandler.payload = {"error": error}
                generator = OtariGenerator(name="openai:configured-model")
                with self.assertRaises(OtariPolicyBlock):
                    generator._call_model("probe prompt")

    def test_openrouter_generator_keeps_its_own_key_and_route(self):
        spec = importlib.util.spec_from_file_location("openrouter", PLUGIN_DIR / "openrouter.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        original_url = module.OPENROUTER_BASE_URL
        module.OPENROUTER_BASE_URL = self.endpoint
        try:
            with patch.dict(os.environ, {"OPENROUTER_API_KEY": "openrouter-test-only-key"}):
                StubHandler.payload = {
                    "id": "chatcmpl-test", "object": "chat.completion", "created": 0,
                    "model": "provider/model", "choices": [{"index": 0, "message": {"role": "assistant", "content": "openrouter stub"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
                }
                result = module.OpenRouterGenerator(name="provider/model")._call_model("probe prompt")[0]
                self.assertEqual(result.text, "openrouter stub")
                self.assertEqual(StubHandler.requests[0]["model"], "provider/model")
        finally:
            module.OPENROUTER_BASE_URL = original_url


if __name__ == "__main__":
    unittest.main()
