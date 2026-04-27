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


if __name__ == "__main__":
    unittest.main()
