#!/usr/bin/env python3
"""Compatibility checks for the local OSS garak 0.14.1 integration."""

import importlib
import importlib.metadata
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"


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
    def test_requirements_pin_garak_0141(self):
        self.assertEqual((ROOT / "garak-requirements.txt").read_text().strip(), "garak==0.14.1")

    @unittest.skipUnless(_garak_available(), "garak is not importable")
    def test_installed_garak_version_is_0141(self):
        self.assertEqual(importlib.metadata.version("garak"), "0.14.1")

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
    def test_garak_0141_base_classes_use_current_language_attributes(self):
        from garak.detectors.base import Detector
        from garak.generators.openai import OpenAICompatible
        from garak.probes.base import Probe

        self.assertTrue(hasattr(Probe, "lang"))
        self.assertFalse(hasattr(Probe, "bcp47"))
        self.assertTrue(hasattr(Detector, "lang_spec"))
        self.assertFalse(hasattr(Detector, "bcp47"))
        self.assertTrue(hasattr(OpenAICompatible, "_load_unsafe"))
        self.assertFalse(hasattr(OpenAICompatible, "_load_client"))

    def test_openrouter_generator_pins_0141_openai_compatible_settings(self):
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

    def test_openrouter_source_keeps_sequential_fallback(self):
        source = (PLUGIN_DIR / "openrouter.py").read_text()
        self.assertIn("supports_multiple_generations = True", source)
        self.assertIn("def _load_unsafe", source)
        self.assertIn("OPENROUTER_BASE_URL", source)
        self.assertIn("def _call_model_sequential", source)
        self.assertIn("terminal API status error", source)


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestOpenRouterTerminalErrors(unittest.TestCase):
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
