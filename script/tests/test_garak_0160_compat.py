#!/usr/bin/env python3
"""Compatibility checks for the local OSS garak 0.16.0 integration."""

import importlib
import importlib.metadata
import importlib.util
import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"

# Matches `attempt.prompt = ...` and `attempt.prompt=...` (the `(?!=)` keeps `==`
# comparisons out), plus the `setattr` spelling of the same reassignment.
PROMPT_REASSIGNMENT_RE = re.compile(
    r"attempt\.prompt\s*=(?!=)|setattr\(attempt,\s*[\"']prompt[\"']"
)


def _garak_available():
    try:
        importlib.import_module("garak")
    except Exception:
        return False
    return True


def _load_local_plugin(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestGarakDistribution(unittest.TestCase):
    def test_requirements_pin_garak_0160(self):
        self.assertEqual((ROOT / "garak-requirements.txt").read_text().strip(), "garak==0.16.0")

    @unittest.skipUnless(_garak_available(), "garak is not importable")
    def test_installed_garak_version_is_0160(self):
        self.assertEqual(importlib.metadata.version("garak"), "0.16.0")

    @unittest.skipUnless(_garak_available(), "garak is not importable")
    def test_garak_cli_exposes_scanner_flags(self):
        result = subprocess.run(
            [sys.executable, "-m", "garak", "--help"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )

        for flag in (
            "--skip_unknown",
            "--target_type",
            "--target_name",
            "--config",
            "--generator_option_file",
            "--report_prefix",
            "--eval_threshold",
            "--parallel_attempts",
            "--probes",
        ):
            self.assertIn(flag, result.stdout)


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestGarakPluginApis(unittest.TestCase):
    def test_garak_base_classes_use_current_language_attributes(self):
        from garak.detectors.base import Detector
        from garak.generators.openai import OpenAICompatible
        from garak.probes.base import Probe

        self.assertTrue(hasattr(Probe, "lang"))
        self.assertFalse(hasattr(Probe, "bcp47"))
        self.assertTrue(hasattr(Detector, "lang_spec"))
        self.assertFalse(hasattr(Detector, "bcp47"))
        self.assertTrue(hasattr(OpenAICompatible, "_load_unsafe"))
        self.assertFalse(hasattr(OpenAICompatible, "_load_client"))

    def test_openrouter_generator_pins_openai_compatible_settings(self):
        module = _load_local_plugin("local_openrouter", "openrouter.py")

        self.assertEqual(module.OPENROUTER_BASE_URL, "https://openrouter.ai/api/v1")
        self.assertEqual(module.OpenRouterGenerator.DEFAULT_PARAMS["uri"], module.OPENROUTER_BASE_URL)
        self.assertEqual(module.OpenRouterGenerator.DEFAULT_PARAMS["max_tokens"], 2000)
        self.assertIsNone(module.OpenRouterGenerator.DEFAULT_PARAMS["stop"])
        self.assertTrue(module.OpenRouterGenerator.supports_multiple_generations)
        self.assertIn("_load_unsafe", module.OpenRouterGenerator.__dict__)
        self.assertNotIn("_load_client", module.OpenRouterGenerator.__dict__)


class TestLocalPluginSources(unittest.TestCase):
    def test_oss_probe_sources_use_lang_fallbacks(self):
        for relative_path in ("probes/0din.py", "probes/0din_variants.py"):
            source = (PLUGIN_DIR / relative_path).read_text()
            self.assertNotIn("bcp47", source)
            self.assertIn('self.lang or "en"', source)

    def test_oss_detector_sources_use_lang_spec(self):
        source = (PLUGIN_DIR / "detectors" / "0din.py").read_text()
        self.assertNotIn("bcp47", source)
        self.assertIn('lang_spec = "en"', source)


    def test_probe_sources_never_reassign_an_attempt_prompt(self):
        # garak >= 0.15: Attempt.prompt is write-once. A reassignment anywhere in the
        # vendored probes aborts the run it appears in. The regex also catches the
        # no-space `attempt.prompt=` spelling and the `setattr(attempt, "prompt", ...)`
        # equivalent, which a plain substring check on "attempt.prompt =" would miss.
        for relative_path in ("probes/0din.py", "probes/0din_variants.py"):
            source = (PLUGIN_DIR / relative_path).read_text()
            match = PROMPT_REASSIGNMENT_RE.search(source)
            self.assertIsNone(match, f"{relative_path} reassigns attempt.prompt: {match and match.group(0)!r}")

    def test_both_install_paths_ship_every_helper_the_detectors_import(self):
        # detectors/0din.py imports these at module scope: a path that ships the
        # detector without them fails to import EVERY 0din detector in that image.
        helpers = [
            name.stem
            for name in (PLUGIN_DIR / "detectors").glob("_*.py")
        ]
        self.assertTrue(helpers, "expected at least one private helper module")

        dockerfile = (ROOT / "Dockerfile").read_text()
        dockerfile_dev = (ROOT / "Dockerfile.dev").read_text()

        for helper in helpers:
            with self.subTest(helper=helper):
                self.assertIn(f"detectors/{helper}.py", dockerfile)
                self.assertIn(f"detectors/{helper}.py", dockerfile_dev)


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestOpenRouterUserRequests(unittest.TestCase):
    def setUp(self):
        import httpx
        import openai

        module = _load_local_plugin("local_openrouter_user", "openrouter.py")
        self.requests = []

        def respond(request):
            self.assertEqual(str(request.url), "https://openrouter.ai/api/v1/chat/completions")
            self.requests.append(json.loads(request.content))
            return httpx.Response(200, json={
                "id": "stub-response", "object": "chat.completion", "created": 1, "model": "stub-model",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })

        self.http_client = httpx.Client(transport=httpx.MockTransport(respond))
        self.client = openai.OpenAI(
            api_key="test-only-placeholder", base_url=module.OPENROUTER_BASE_URL, http_client=self.http_client
        )
        self.generator = object.__new__(module.OpenRouterGenerator)
        self.generator.client = self.client
        self.generator.generator = self.client.chat.completions
        self.generator.suppressed_params = set()
        self.generator.max_tokens = 10

    def tearDown(self):
        self.client.close()

    def call(self, model, count=1):
        self.generator.name = model
        result = self.generator._call_model("offline prompt", generations_this_call=count)
        self.assertEqual([message.text for message in result], ["ok"] * count)

    def test_explicit_threat_feed_identity_is_stable_in_body_including_sequential_fallback(self):
        with patch.dict(os.environ, {"OPENROUTER_USER": "scanner:threat-feed", "SCANNER_ENVIRONMENT": "prod"}, clear=True):
            self.call("anthropic/claude-3-opus", count=2)

        self.assertEqual(len(self.requests), 3)
        for body in self.requests:
            self.assertEqual(body["user"], "scanner:threat-feed:prod")
            self.assertEqual(body["messages"], [{"role": "user", "content": "offline prompt"}])
            self.assertEqual(body["model"], "anthropic/claude-3-opus")
            self.assertNotIn("user", body["messages"][0])

    def test_no_actor_gets_stable_service_identity(self):
        with patch.dict(os.environ, {"RAILS_ENV": "development"}, clear=True):
            self.call("anthropic/claude-3-opus")
            self.call("anthropic/claude-3-opus")

        self.assertEqual([body["user"] for body in self.requests], ["scanner:service:dev"] * 2)

    def test_all_routes_receive_tenant_user_at_top_level(self):
        models = ("meta/muse-spark-1.2", "meta/muse-spark-1.3", "openai/gpt-6.1-sol", "openai/gpt-6.1-sol:variant")
        with patch.dict(os.environ, {"OPENROUTER_USER": "scanner:tenant:42", "SCANNER_ENVIRONMENT": "stage"}, clear=True):
            for model in models:
                self.call(model)

        for model, body in zip(models, self.requests, strict=True):
            self.assertEqual(body, {
                "messages": [{"role": "user", "content": "offline prompt"}],
                "model": model, "n": 1, "max_tokens": 10, "user": "scanner:tenant:42:stage",
            })

    def test_meta_route_keeps_user_on_sequential_fallback(self):
        with patch.dict(os.environ, {"OPENROUTER_USER": "scanner:tenant:42", "SCANNER_ENVIRONMENT": "stage"}, clear=True):
            self.call("meta/muse-spark-1.2", count=2)

        for expected_n, body in zip((2, 1, 1), self.requests, strict=True):
            self.assertEqual(body, {
                "messages": [{"role": "user", "content": "offline prompt"}],
                "model": "meta/muse-spark-1.2", "n": expected_n, "max_tokens": 10,
                "user": "scanner:tenant:42:stage",
            })

    def test_same_actor_is_separated_across_deployments(self):
        with patch.dict(os.environ, {"OPENROUTER_USER": "scanner:tenant:42"}, clear=True):
            for deployment in ("dev", "stage", "prod"):
                os.environ["SCANNER_ENVIRONMENT"] = deployment
                self.call("anthropic/claude-3-opus")

        self.assertEqual([body["user"] for body in self.requests], [
            "scanner:tenant:42:dev", "scanner:tenant:42:stage", "scanner:tenant:42:prod"
        ])

    def test_production_without_deployment_identity_never_sends_a_request(self):
        with patch.dict(os.environ, {"RAILS_ENV": "production"}, clear=True):
            with self.assertRaisesRegex(ValueError, "SCANNER_ENVIRONMENT"):
                self.generator._call_model("offline prompt")

        self.assertEqual(self.requests, [])


    def test_other_generator_request_body_is_unchanged(self):
        from garak.generators.openai import OpenAICompatible

        other = object.__new__(OpenAICompatible)
        other.client = self.client
        other.generator = self.client.chat.completions
        other.name = "gpt-4o"
        other.max_tokens = 10
        other.suppressed_params = set()
        other.supports_multiple_generations = True
        with patch.dict(os.environ, {"OPENROUTER_USER": "scanner:tenant:42", "SCANNER_ENVIRONMENT": "stage"}, clear=True):
            responses = other._call_model([{"role": "user", "content": "offline prompt"}])

        self.assertEqual([message.text for message in responses], ["ok"])
        self.assertEqual(self.requests, [{
            "model": "gpt-4o", "messages": [{"role": "user", "content": "offline prompt"}],
            "n": 1, "max_tokens": 10,
        }])


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestOpenRouterTerminalErrors(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {"SCANNER_ENVIRONMENT": "test"})
        environment.start()
        self.addCleanup(environment.stop)

    def _generator_with_create(self, create):
        module = _load_local_plugin("local_openrouter_terminal", "openrouter.py")
        generator = object.__new__(module.OpenRouterGenerator)
        generator.name = "openai/gpt-4o"
        generator.client = object()
        generator.generator = type("FakeCompletions", (), {"create": staticmethod(create)})()
        generator.suppressed_params = set()
        generator.max_tokens = 10
        generator.generator_family_name = "OpenRouter"
        return module, generator

    def _response(self, status_code):
        import httpx

        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        return httpx.Response(status_code, request=request, json={"error": {"message": "provider rejected"}})

    def test_openrouter_converts_terminal_api_status_to_bad_generator(self):
        import openai
        from garak.exception import BadGeneratorException

        body = {
            "error": "invalid request",
            "api_key": "sk-or-v1-secretvalue",
            "debug": '{"api_key":"plainsecret"}',
            "nested": {"authorization": "Bearer topsecret"}
        }

        def create(**_kwargs):
            raise openai.BadRequestError("request rejected", response=self._response(422), body=body)

        _module, generator = self._generator_with_create(create)

        with self.assertRaises(BadGeneratorException) as ctx:
            generator._call_model("prompt", generations_this_call=1)

        message = str(ctx.exception)
        self.assertIn("OpenRouter terminal API status error", message)
        self.assertIn("status_code=422", message)
        self.assertIn("model='openai/gpt-4o'", message)
        self.assertNotIn("sk-or-v1-secretvalue", message)
        self.assertNotIn("plainsecret", message)
        self.assertNotIn("topsecret", message)
        self.assertIn("[REDACTED]", message)

    def test_openrouter_retryable_rate_limit_propagates(self):
        import openai

        def create(**_kwargs):
            raise openai.RateLimitError("rate limited", response=self._response(429), body={})

        _module, generator = self._generator_with_create(create)

        with self.assertRaises(openai.RateLimitError):
            generator._call_model("prompt", generations_this_call=1)

    def test_openrouter_all_empty_generations_raise_bad_generator(self):
        from garak.exception import BadGeneratorException

        class MessageObj:
            content = None

        class Choice:
            message = MessageObj()

        class Response:
            choices = [Choice()]

        def create(**_kwargs):
            return Response()

        _module, generator = self._generator_with_create(create)

        with self.assertRaises(BadGeneratorException) as ctx:
            generator._call_model("prompt", generations_this_call=1)

        self.assertIn("empty generations", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
