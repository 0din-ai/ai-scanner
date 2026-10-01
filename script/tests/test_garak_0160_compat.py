#!/usr/bin/env python3
"""Compatibility checks for the local OSS garak 0.16.0 integration."""

import importlib
import importlib.metadata
import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path


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

    def test_identity_block_status_is_terminal_and_never_exposes_body(self):
        import httpx
        import openai
        import traceback

        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        response = httpx.Response(403, request=request, headers={"x-request-id": "req_123"})
        body = {"error": {"code": "policy_violation", "message":
                "Policy Violation: this user has been blocked for a previous policy violation. private-prompt"}}
        calls = []

        def create(**_kwargs):
            calls.append(1)
            raise openai.PermissionDeniedError("private-prompt", response=response, body=body)

        module, generator = self._generator_with_create(create)
        with self.assertRaises(module.OpenRouterPolicyBlock) as ctx:
            generator._call_model("private-prompt", 2)
        self.assertEqual(calls, [1])
        self.assertEqual(ctx.exception.code, "identity_policy_block")
        self.assertEqual(ctx.exception.request_id, "req_123")
        self.assertNotIn("private-prompt", "".join(traceback.format_exception(ctx.exception)))

    def test_streamed_200_error_stops_sequential_fallback(self):
        from types import SimpleNamespace
        from openai.types.chat import ChatCompletion
        calls = []

        def create(**_kwargs):
            calls.append(1)
            if len(calls) == 1:
                return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content="first"))])
            if len(calls) == 2:
                return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content="first"))])
            return ChatCompletion.model_validate({
                "id": "gen_456", "object": "chat.completion", "created": 0,
                "model": "openai/gpt-4o", "choices": [],
                "error": {"code": "account_blocked", "message": "private-output"}
            })

        module, generator = self._generator_with_create(create)
        with self.assertRaises(module.OpenRouterPolicyBlock) as ctx:
            generator._call_model("prompt", 3)
        self.assertEqual(len(calls), 3)
        self.assertEqual(ctx.exception.request_id, "gen_456")
        self.assertNotIn("private-output", str(ctx.exception))

    def test_identity_block_keeps_uuid_id_but_never_a_credential_shaped_id(self):
        import httpx
        import openai

        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        for request_id, expected in (("f85f7b2a-2f52-48df-a835-e5902e343ba9", True),
                                     ("sk-or-v1-secretvalue", False),
                                     ("req_sk-or-v1-secretvalue", False)):
            with self.subTest(request_id=request_id):
                response = httpx.Response(403, request=request, headers={"x-request-id": request_id})

                def create(**_kwargs):
                    raise openai.PermissionDeniedError("blocked", response=response,
                        body={"error": {"code": "user_blocked"}})

                module, generator = self._generator_with_create(create)
                with self.assertRaises(module.OpenRouterPolicyBlock) as ctx:
                    generator._call_model("prompt")
                self.assertEqual(ctx.exception.request_id, request_id if expected else None)
                if not expected:
                    self.assertNotIn(request_id, str(ctx.exception))

    def test_generic_403_auth_and_guardrail_are_not_identity_blocks(self):
        import openai

        for error in ({"code": "policy_violation", "message": "content rejected by guardrail"},
                      {"code": "invalid_api_key", "message": "unauthorized"},
                      {"message": "forbidden"}):
            with self.subTest(error=error):
                def create(**_kwargs):
                    raise openai.PermissionDeniedError("forbidden", response=self._response(403),
                                                       body={"error": error})

                module, generator = self._generator_with_create(create)
                with self.assertRaises(Exception) as ctx:
                    generator._call_model("prompt")
                self.assertNotIsInstance(ctx.exception, module.OpenRouterPolicyBlock)

    def test_auth_errors_remain_auth_even_with_identity_words(self):
        import openai

        for status, error in ((401, {"code": "user_blocked", "message": "This user has been blocked for a previous policy violation."}),
                              (403, {"code": "invalid_api_key", "message": "This user has been blocked for a previous policy violation."})):
            with self.subTest(status=status):
                def create(**_kwargs):
                    error_type = openai.AuthenticationError if status == 401 else openai.PermissionDeniedError
                    raise error_type("authentication failed", response=self._response(status), body={"error": error})

                module, generator = self._generator_with_create(create)
                with self.assertRaises(Exception) as ctx:
                    generator._call_model("prompt")
                self.assertNotIsInstance(ctx.exception, module.OpenRouterPolicyBlock)

    def test_normal_refusal_and_benign_completion_remain_model_answers(self):
        from types import SimpleNamespace

        for text in ("I cannot assist with that request", "Here is the answer"):
            with self.subTest(text=text):
                def create(**_kwargs):
                    return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=text))])

                _module, generator = self._generator_with_create(create)
                self.assertEqual(generator._call_model("prompt")[0].text, text)

    def test_real_sdk_completion_without_usage_is_not_a_synthetic_refusal(self):
        from openai.types.chat import ChatCompletion

        def create(**_kwargs):
            return ChatCompletion.model_validate({
                "id": "gen_789", "object": "chat.completion", "created": 0,
                "model": "openai/gpt-4o", "choices": [{"index": 0, "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "A benign answer."}}]
            })

        _module, generator = self._generator_with_create(create)
        self.assertEqual(generator._call_model("prompt")[0].text, "A benign answer.")

    def test_policy_block_survives_worker_serialization(self):
        import pickle
        from unittest.mock import patch

        module = _load_local_plugin("local_openrouter_worker_block", "openrouter.py")
        with patch.dict(sys.modules, {module.__name__: module}):
            restored = pickle.loads(pickle.dumps(module.OpenRouterPolicyBlock("user_blocked", "req_123")))
        self.assertEqual((restored.code, restored.request_id), ("user_blocked", "req_123"))
        self.assertEqual(str(restored), "provider_policy_block code=user_blocked type=identity request_id=req_123")

    def test_single_turn_probes_propagate_block_without_output(self):
        from garak.attempt import Attempt, Message

        module = _load_local_plugin("local_openrouter_probe", "openrouter.py")
        probes = _load_local_plugin("local_0din_policy_block", "probes/0din.py")
        block = module.OpenRouterPolicyBlock("user_blocked")

        class BlockGenerator:
            def generate(self, _conversation, _count):
                raise block

        for probe_type in (probes.BaseHarmfulContentProbe, probes.HarryPotterCopyrightProbe):
            with self.subTest(probe=probe_type.__name__):
                probe = object.__new__(probe_type)
                probe.lang = "en"
                probe.generator = BlockGenerator()
                if probe_type is probes.BaseHarmfulContentProbe:
                    probe._prompt_data_map = {}
                attempt = Attempt(prompt=Message(text="prompt", lang="en"), probe_classname="0din.Fake")
                with self.assertRaises(module.OpenRouterPolicyBlock):
                    probe._execute_attempt(attempt)
                self.assertFalse(attempt.outputs)

    def test_identity_block_stops_prefetched_probe_attempts(self):
        import io
        from unittest.mock import patch
        from garak import _config
        from garak.attempt import Attempt, Message
        from openai.types.chat import ChatCompletion

        calls = []

        def create(**_kwargs):
            calls.append(1)
            return ChatCompletion.model_validate({
                "id": "gen_456", "object": "chat.completion", "created": 0,
                "model": "openai/gpt-4o", "choices": [],
                "error": {"code": "account_blocked", "message": "private upstream body"}
            })

        module, generator = self._generator_with_create(create)
        probes = _load_local_plugin("local_0din_prefetch_block", "probes/0din.py")

        class ProbeGenerator:
            parallel_capable = generator.parallel_capable

            def generate(self, conversation, count):
                return generator._call_model(conversation, count)

        class PrefetchedPool:
            # garak's Pool queues attempts before its parent sees the first error.
            def __init__(self, _workers):
                pass

            def imap_unordered(self, execute, attempts):
                first_block = None
                for attempt in attempts:
                    try:
                        execute(attempt)
                    except module.OpenRouterPolicyBlock as block:
                        first_block = first_block or block
                if first_block is None:
                    raise AssertionError("expected a provider policy block")

                def results():
                    raise first_block
                    yield  # Preserve the iterator contract of imap_unordered.

                return results()

            def close(self):
                pass

            def join(self):
                pass

        probe = object.__new__(probes.BaseHarmfulContentProbe)
        probe.lang = "en"
        probe.generator = ProbeGenerator()
        probe._prompt_data_map = {}
        probe.parallel_attempts = 16
        probe.max_workers = 16
        probe.probename = "0din.Fake"
        attempts = [Attempt(prompt=Message(text="prompt", lang="en"), probe_classname="0din.Fake") for _ in range(3)]
        reportfile = io.StringIO()
        with patch.object(_config.transient, "reportfile", reportfile), patch("multiprocessing.Pool", PrefetchedPool):
            with self.assertRaises(module.OpenRouterPolicyBlock):
                probe._execute_all(attempts)

        self.assertEqual(len(calls), 1)
        self.assertEqual(reportfile.getvalue(), "")
        self.assertTrue(all(not attempt.outputs for attempt in attempts))

if __name__ == "__main__":
    unittest.main()
