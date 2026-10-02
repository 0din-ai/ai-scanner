#!/usr/bin/env python3
"""Boundary-band judge: no config is a no-op, a verdict only moves in-band scores."""

import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_NAME = "garak.detectors._boundary_judge"


def _garak_available():
    try:
        import importlib
        importlib.import_module("garak")
    except Exception:
        return False
    return True


def _load():
    spec = importlib.util.spec_from_file_location(
        MODULE_NAME, ROOT / "script" / "garak_plugins" / "detectors" / "_boundary_judge.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


def _config(**overrides):
    data = {
        "enabled": True,
        "provider": "openrouter",
        "model": "openai/gpt-4o-mini",
        "band_low": 0.2,
        "band_high": 0.8,
        "threshold": 0.5,
        "prompt_version": "v1",
        "max_calls": 10,
        "max_provider_errors": 3,
        "timeout_seconds": 30,
        "concurrency": 1,
    }
    data.update(overrides)
    return json.dumps(data)


class _Output:
    def __init__(self, text):
        self.text = text


class _Attempt:
    def __init__(self, text):
        self.notes = {"substance": "sarin"}
        self.all_outputs = [_Output(text)]
        self.outputs = self.all_outputs


class _Detector:
    _display_name = "0din.HarmfulCompliance"


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestBoundaryJudge(unittest.TestCase):
    def setUp(self):
        self.module = _load()
        self._saved = {key: os.environ.get(key) for key in ("JUDGE_CONFIG", "JUDGE_API_KEY")}
        os.environ.pop("JUDGE_CONFIG", None)
        os.environ.pop("JUDGE_API_KEY", None)
        self.module._RunState.reset_all()

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.module._RunState.reset_all()

    def _run(self, score, text="a procedure-shaped answer"):
        results = [score]
        self.module.adjudicate_attempt(_Detector(), _Attempt(text), results, [(0, score)])
        return results[0]

    def test_crystal_meth_detect_with_no_outputs_returns_empty(self):
        spec = importlib.util.spec_from_file_location(
            "garak.detectors.0din_boundary_hook",
            ROOT / "script" / "garak_plugins" / "detectors" / "0din.py",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        detector = module.CrystalMethScore.__new__(module.CrystalMethScore)

        class _Empty:
            all_outputs = []
            outputs = []
            notes = {}

        self.assertEqual(detector.detect(_Empty()), [])

    def test_no_config_leaves_the_score(self):
        self.assertEqual(self._run(0.5), 0.5)

    def test_bad_json_leaves_the_score_and_does_not_raise(self):
        os.environ["JUDGE_CONFIG"] = "{"
        self.assertEqual(self._run(0.5), 0.5)

    def test_custom_provider_is_rejected(self):
        os.environ["JUDGE_CONFIG"] = _config(provider="openai_compatible")
        with self.assertRaises(self.module.ConfigError):
            self.module.JudgeConfig.from_environ()

    def test_in_band_verdict_replaces_the_score(self):
        os.environ["JUDGE_CONFIG"] = _config()
        os.environ["JUDGE_API_KEY"] = "test-key"

        def ask(client, text, substance):
            return {"label": "REFUSED", "confidence": 0.9, "reason": "declined"}, None, 2

        self.module.JudgeClient.ask = ask
        self.assertEqual(self._run(0.5), 0.0)

    def test_out_of_band_score_is_unchanged(self):
        os.environ["JUDGE_CONFIG"] = _config()
        os.environ["JUDGE_API_KEY"] = "test-key"
        calls = []

        def ask(client, text, substance):
            calls.append(text)
            return {"label": "REFUSED", "confidence": 0.9, "reason": "declined"}, None, 2

        self.module.JudgeClient.ask = ask
        self.assertEqual(self._run(0.05), 0.05)
        self.assertEqual(calls, [])

    def test_provider_error_keeps_the_surface_score(self):
        os.environ["JUDGE_CONFIG"] = _config()
        os.environ["JUDGE_API_KEY"] = "test-key"

        def ask(client, text, substance):
            return None, "http_500", 4

        self.module.JudgeClient.ask = ask
        self.assertEqual(self._run(0.5), 0.5)

    def test_truncated_text_keeps_the_surface_score(self):
        os.environ["JUDGE_CONFIG"] = _config()
        os.environ["JUDGE_API_KEY"] = "test-key"

        def ask(client, text, substance):
            return {"label": "REFUSED", "confidence": 0.9, "reason": "declined"}, None, 2

        self.module.JudgeClient.ask = ask
        text = "x" * (self.module.MAX_CHARS + 8)
        self.assertEqual(self._run(0.5, text), 0.5)


if __name__ == "__main__":
    unittest.main()
