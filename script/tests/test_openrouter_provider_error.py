#!/usr/bin/env python3
"""Provider error envelopes from the vendored OpenRouter generator."""

import contextlib
import importlib.util
import io
import json
import pickle
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"

IDENTITY_MESSAGE = (
    "Policy Violation: this user has been blocked for a previous policy violation. "
    "Learn more: https://openrouter.ai/docs/guides/features/safety"
)
BLOCK_ERROR = {
    "message": IDENTITY_MESSAGE,
    "code": 403,
    "metadata": {
        "error_type": "refusal",
        "provider_code": "invalid_request",
    },
}


def _garak_available():
    try:
        import importlib
        importlib.import_module("garak")
    except Exception:
        return False
    return True


def _load_plugin(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _generator(module, create, name="openai/gpt-4o"):
    generator = object.__new__(module.OpenRouterGenerator)
    generator.name = name
    generator.client = object()
    generator.generator = type("FakeCompletions", (), {"create": staticmethod(create)})()
    generator.suppressed_params = set()
    generator.max_tokens = 16
    generator.generator_family_name = "OpenRouter"
    return generator


def _response(**attrs):
    defaults = {"id": "gen-456", "choices": None, "error": BLOCK_ERROR}
    defaults.update(attrs)
    return type("Resp", (), defaults)()


def _stderr_records(stderr_text):
    return [
        line for line in stderr_text.splitlines()
        if line.startswith("PROVIDER_ERROR {")
    ]


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestOpenRouterProviderError(unittest.TestCase):
    def test_block_body_at_n5_is_one_call_and_not_a_garak_exception(self):
        from garak.exception import GarakException

        module = _load_plugin("openrouter_provider_block", "openrouter.py")
        calls = []

        def create(**kwargs):
            calls.append(kwargs)
            return _response()

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=5)

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["n"], 5)
        err = ctx.exception
        self.assertEqual(err.category, "identity_policy_block")
        self.assertEqual(err.provider_status, 403)
        self.assertEqual(err.provider_code, "invalid_request")
        self.assertEqual(err.provider_error_type, "refusal")
        self.assertFalse(isinstance(err, GarakException))
        self.assertEqual(str(err), "PROVIDER_ERROR category=identity_policy_block model=openai/gpt-4o")
        self.assertNotIn(IDENTITY_MESSAGE, str(err))
        lines = _stderr_records(stderr.getvalue())
        self.assertEqual(len(lines), 1)
        payload = json.loads(lines[0].split(" ", 1)[1])
        self.assertEqual(payload["category"], "identity_policy_block")
        self.assertEqual(payload["http_status"], 200)
        self.assertEqual(payload["request_id"], "gen-456")
        restored = pickle.loads(pickle.dumps(err))
        self.assertEqual(restored.category, "identity_policy_block")
        self.assertEqual(str(restored), str(err))
        self.assertTrue(all(arg is None or isinstance(arg, (str, int)) for arg in err.__reduce__()[1]))

    def test_block_sentence_in_a_completion_is_a_model_answer(self):
        module = _load_plugin("openrouter_provider_answer", "openrouter.py")

        class Choice:
            class message:
                content = IDENTITY_MESSAGE

        def create(**_kwargs):
            return type("Resp", (), {"choices": [Choice()], "id": "gen-1"})()

        generator = _generator(module, create)
        out = generator._call_model("hi", generations_this_call=1)
        self.assertEqual(out[0].text, IDENTITY_MESSAGE)

    def test_generic_403_is_not_an_identity_block(self):
        import openai

        module = _load_plugin("openrouter_provider_403", "openrouter.py")

        def create(**_kwargs):
            exc = openai.PermissionDeniedError.__new__(openai.PermissionDeniedError)
            exc.status_code = 403
            exc.response = None
            exc.body = {"error": {"code": "policy_violation", "message": "content rejected by guardrail"}}
            raise exc

        generator = _generator(module, create)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=1)
        self.assertEqual(ctx.exception.category, "rejected_request")

    def test_http_401_with_the_block_sentence_stays_auth(self):
        import openai

        module = _load_plugin("openrouter_provider_401", "openrouter.py")

        def create(**_kwargs):
            exc = openai.AuthenticationError.__new__(openai.AuthenticationError)
            exc.status_code = 401
            exc.response = None
            exc.body = {"error": {"code": "user_blocked", "message": IDENTITY_MESSAGE}}
            raise exc

        generator = _generator(module, create)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=5)
        self.assertEqual(ctx.exception.category, "auth_failed")
        self.assertEqual(ctx.exception.http_status, 401)

    def _conversational(self, generator):
        from garak.attempt import Conversation, Message, Turn

        generator.seed = None
        generator.skip_seq_start = "<<<"
        generator.skip_seq_end = ">>>"
        generator.supports_multiple_generations = True
        return Conversation(turns=[Turn(role="user", content=Message(text="hi", lang="en"))])

    def test_upstream_envelope_retries_then_returns_a_completion(self):
        module = _load_plugin("openrouter_provider_retry_ok", "openrouter.py")
        calls = []
        sleeps = []

        class Choice:
            class message:
                content = "recovered"

        def create(**kwargs):
            calls.append(kwargs)
            if len(calls) == 1:
                return _response(error={"message": "upstream busy", "code": 502})
            return type("Resp", (), {"choices": [Choice()], "id": "gen-ok", "usage": None})()

        generator = _generator(module, create)
        generator._sleep = sleeps.append
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            out = generator.generate(self._conversational(generator), 1)
        self.assertEqual(out[0].text, "recovered")
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [1.0])
        payload = json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])
        self.assertEqual(payload["category"], "upstream_unavailable")

    def test_internal_server_error_exhausts_into_a_pickle_safe_exception(self):
        import openai
        import httpx
        from garak.exception import GarakException

        module = _load_plugin("openrouter_provider_retry_fail", "openrouter.py")
        calls = []
        sleeps = []
        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        response = httpx.Response(500, request=request, json={"error": {"message": "down"}})

        def create(**_kwargs):
            calls.append(1)
            raise openai.InternalServerError("down", response=response, body={})

        generator = _generator(module, create)
        generator._sleep = sleeps.append
        with self.assertRaises(module.ProviderRetryExhausted) as ctx:
            generator.generate(self._conversational(generator), 1)
        err = ctx.exception
        self.assertEqual(len(calls), 5)
        self.assertEqual(sleeps, [1.0, 2.0, 4.0, 8.0])
        self.assertEqual(err.category, "upstream_unavailable")
        self.assertEqual(err.provider_status, 500)
        self.assertFalse(isinstance(err, GarakException))
        self.assertFalse(getattr(err, "terminal_provider_error", False))
        self.assertEqual(
            str(err),
            "PROVIDER_RETRY_EXHAUSTED category=upstream_unavailable model=openai/gpt-4o",
        )
        restored = pickle.loads(pickle.dumps(err))
        self.assertEqual(
            (restored.category, restored.provider_status, restored.model),
            ("upstream_unavailable", 500, "openai/gpt-4o"),
        )
        provider_error = module.ProviderError("identity_policy_block", model="openai/gpt-4o")
        restored_provider = pickle.loads(pickle.dumps(provider_error))
        self.assertEqual(restored_provider.category, "identity_policy_block")
        self.assertEqual(str(restored_provider), str(provider_error))

    def test_block_sentence_past_the_logged_limit_still_classifies(self):
        module = _load_plugin("openrouter_provider_long", "openrouter.py")
        prefix = "x" * module._MESSAGE_MAX_CHARS

        def create(**_kwargs):
            return _response(error={
                "message": prefix + IDENTITY_MESSAGE,
                "code": 403,
                "metadata": {"error_type": "refusal", "provider_code": "invalid_request"},
            })

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=1)
        self.assertEqual(ctx.exception.category, "identity_policy_block")
        payload = json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])
        text = bytes.fromhex(payload["message_hex"]).decode("utf-8")
        self.assertEqual(len(text), module._MESSAGE_MAX_CHARS)
        self.assertNotIn("blocked for a previous policy violation", text)
        self.assertNotIn("message", payload)

    def test_record_is_printed_when_logging_goes_elsewhere(self):
        import logging

        module = _load_plugin("openrouter_provider_stderr", "openrouter.py")
        root = logging.getLogger()
        previous_handlers = list(root.handlers)
        previous_level = root.level
        root.handlers = [logging.StreamHandler(io.StringIO())]
        root.setLevel(logging.ERROR)
        stderr = io.StringIO()

        def create(**_kwargs):
            return _response()

        generator = _generator(module, create)
        try:
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(module.ProviderError):
                    generator._call_model("hi", generations_this_call=1)
        finally:
            root.handlers = previous_handlers
            root.setLevel(previous_level)
        lines = _stderr_records(stderr.getvalue())
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0].split(" ", 1)[1])["category"], "identity_policy_block")

    def test_validation_error_without_an_error_envelope_returns_none(self):
        import httpx
        import openai

        module = _load_plugin("openrouter_provider_malformed", "openrouter.py")
        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        response = httpx.Response(200, request=request, json={"id": "gen-1", "unexpected": True})

        def create(**_kwargs):
            raise openai.APIResponseValidationError(
                response=response, body={"id": "gen-1", "unexpected": True}
            )

        generator = _generator(module, create)
        self.assertEqual(generator._call_model("hi", generations_this_call=3), [None, None, None])

    def test_cookie_continuation_line_is_redacted(self):
        module = _load_plugin("openrouter_provider_cookie_fold", "openrouter.py")
        message = "Cookie: session=abc;\n session2=folded-value\nmodel is fine"

        def create(**_kwargs):
            return _response(error={"message": message, "code": 403})

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError):
                generator._call_model("hi", generations_this_call=1)
        decoded = bytes.fromhex(
            json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])["message_hex"]
        ).decode("utf-8")
        self.assertNotIn("folded-value", decoded)
        self.assertNotIn("session=abc", decoded)
        self.assertIn("model is fine", decoded)

    def test_unpaired_surrogate_still_emits_the_record(self):
        module = _load_plugin("openrouter_provider_surrogate", "openrouter.py")

        def create(**_kwargs):
            return _response(error={"message": "prefix \ud800 suffix", "code": 403})

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError):
                generator._call_model("hi", generations_this_call=1)
        decoded = bytes.fromhex(
            json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])["message_hex"]
        ).decode("utf-8")
        self.assertIn("prefix", decoded)
        self.assertIn("suffix", decoded)
        self.assertNotIn("\ud800", decoded)

    def test_basic_prose_is_not_redacted_and_stays_model_unavailable(self):
        module = _load_plugin("openrouter_provider_basic_prose", "openrouter.py")
        message = "The basic model is unavailable"

        def create(**_kwargs):
            return _response(error={"message": message}, id="gen-1")

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=1)
        decoded = bytes.fromhex(
            json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])["message_hex"]
        ).decode("utf-8")
        self.assertEqual(ctx.exception.category, "model_unavailable")
        self.assertEqual(decoded, message)
        self.assertEqual(module._redact(message), message)

    def test_basic_authorization_redacts_the_credential_not_only_the_scheme(self):
        module = _load_plugin("openrouter_provider_basic_auth", "openrouter.py")
        raw = "Authorization: Basic dXNlcjpwYXNz"
        self.assertNotIn("dXNlcjpwYXNz", module._redact(raw))

        def create(**_kwargs):
            return _response(error={"message": raw, "code": 403})

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError):
                generator._call_model("hi", generations_this_call=1)
        payload = json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])
        decoded = bytes.fromhex(payload["message_hex"]).decode("utf-8")
        self.assertNotIn("dXNlcjpwYXNz", decoded)

    def test_message_hex_redacts_credentials_before_encoding(self):
        module = _load_plugin("openrouter_provider_redact_hex", "openrouter.py")
        secrets = (
            "session=abc123",
            "dXNlcjpwYXNz",
            "tok999",
            "postgres://u:p@h/db",
            "zzz",
            "sk-or-v1-abcdefghijklmnopqrst",
        )
        message = (
            "Cookie: session=abc123 "
            "Authorization: Basic dXNlcjpwYXNz "
            "X-Api-Token: tok999 "
            "database_url=postgres://u:p@h/db "
            "access_token=zzz "
            "sk-or-v1-abcdefghijklmnopqrst"
        )

        def create(**_kwargs):
            return _response(error={"message": message, "code": 403})

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError):
                generator._call_model("hi", generations_this_call=1)
        payload = json.loads(_stderr_records(stderr.getvalue())[0].split(" ", 1)[1])
        decoded = bytes.fromhex(payload["message_hex"]).decode("utf-8")
        for secret in secrets:
            self.assertNotIn(secret, decoded)

    def test_message_hex_survives_run_command_sanitizers(self):
        # Python port of RunCommand#sanitize_output's two substitutions.
        sensitive = re.compile(
            r"((?:api[_-]?key|token|password|secret|access[_-]?token|auth[_-]?token|"
            r"credential|bearer|authorization|cookie|set[_-]?cookie|database[_-]?url|"
            r"redis[_-]?url|secret[_-]?key[_-]?base)[\"']?\s*[=:]\s*[\"']?"
            r"(?:(?:bearer|basic|splunk|negotiate|digest|token|bot)\s+)?)[^\s\"',}\]&;]+",
            re.I,
        )
        cookie = re.compile(r"((?:set-)?cookie[\"']?\s*[=:]\s*).*", re.I)
        module = _load_plugin("openrouter_provider_hex", "openrouter.py")

        def create(**_kwargs):
            return _response(error={
                "message": 'see api_key="abc" Cookie: x=1',
                "code": 403,
            })

        generator = _generator(module, create)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderError) as ctx:
                generator._call_model("hi", generations_this_call=1)
        line = _stderr_records(stderr.getvalue())[0]
        sanitized = cookie.sub(r"\1[REDACTED]", sensitive.sub(r"\1[REDACTED]", line))
        payload = json.loads(sanitized.split(" ", 1)[1])
        self.assertEqual(payload["category"], ctx.exception.category)
        self.assertNotIn("api_key", sanitized)
        self.assertNotIn("Cookie", sanitized)

    def test_transient_classification_stays_inside_the_retry_loop(self):
        import httpx
        import openai

        module = _load_plugin("openrouter_provider_inside", "openrouter.py")
        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")

        def status_error():
            response = httpx.Response(400, request=request, json={"error": {"code": 429, "message": "slow"}})
            exc = openai.BadRequestError("slow", response=response, body=response.json())
            return exc

        def validation_error():
            response = httpx.Response(
                200, request=request, json={"error": {"code": 502, "message": "upstream busy"}}
            )
            return openai.APIResponseValidationError(response=response, body=response.json())

        for factory in (status_error, validation_error):
            calls = []

            def create(factory=factory, **_kwargs):
                calls.append(1)
                raise factory()

            generator = _generator(module, create)
            generator._sleep = lambda _seconds: None
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(module.ProviderRetryExhausted) as ctx:
                    generator._call_model("hi", generations_this_call=1)
            self.assertNotIsInstance(ctx.exception, module._TransientFailure)
            self.assertEqual(len(calls), 5)

    def test_native_429_after_an_envelope_is_the_last_record(self):
        import httpx
        import openai

        module = _load_plugin("openrouter_provider_last_record", "openrouter.py")
        calls = []
        request = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")
        limited = httpx.Response(429, request=request, json={"error": {"message": "slow"}})

        def create(**_kwargs):
            calls.append(1)
            if len(calls) == 1:
                return _response(error={"message": "upstream busy", "code": 502})
            raise openai.RateLimitError("slow", response=limited, body={})

        generator = _generator(module, create)
        generator._sleep = lambda _seconds: None
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(module.ProviderRetryExhausted) as ctx:
                generator._call_model("hi", generations_this_call=1)
        self.assertEqual(len(calls), 5)
        self.assertEqual(ctx.exception.category, "rate_limited")
        records = [
            json.loads(line.split(" ", 1)[1]) for line in _stderr_records(stderr.getvalue())
        ]
        self.assertEqual(records[0]["category"], "upstream_unavailable")
        self.assertEqual(records[-1]["category"], "rate_limited")
        self.assertIsNotNone(records[-1]["message_hex"])

    def test_real_client_sends_model_and_stops_a_block_after_one_request(self):
        import httpx
        import openai

        module = _load_plugin("openrouter_provider_transport", "openrouter.py")
        seen = []
        mode = {"kind": "ok"}

        def handler(request):
            seen.append(request)
            if mode["kind"] == "block":
                return httpx.Response(200, json={"id": "gen-456", "error": BLOCK_ERROR})
            return httpx.Response(200, json={
                "id": "gen-ok",
                "object": "chat.completion",
                "created": 0,
                "model": "openai/gpt-4o",
                "choices": [{
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "A benign answer."},
                }],
            })

        http_client = httpx.Client(transport=httpx.MockTransport(handler))
        real_client = openai.OpenAI

        def client_factory(*args, **kwargs):
            kwargs["http_client"] = http_client
            return real_client(*args, **kwargs)

        generator = object.__new__(module.OpenRouterGenerator)
        generator.name = "openai/gpt-4o"
        generator.suppressed_params = set()
        generator.max_tokens = 16
        generator.generator_family_name = "OpenRouter"
        generator.client = None
        generator.generator = None
        with patch.dict("os.environ", {"OPENROUTER_API_KEY": "test-key"}):
            with patch("openai.OpenAI", client_factory):
                generator._load_unsafe()
                out = generator._call_model("hi", generations_this_call=1)
                self.assertEqual(out[0].text, "A benign answer.")
                self.assertEqual(json.loads(seen[0].content)["model"], "openai/gpt-4o")
                mode["kind"] = "block"
                seen.clear()
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(module.ProviderError) as ctx:
                        generator._call_model("hi", generations_this_call=5)
        self.assertEqual(ctx.exception.category, "identity_policy_block")
        self.assertEqual(len(seen), 1)
        self.assertEqual(json.loads(seen[0].content)["model"], "openai/gpt-4o")


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestProbeHandlersPropagateProviderError(unittest.TestCase):
    def test_handlers_reraise_and_a_plain_error_still_marks_generation_failed(self):
        module = _load_plugin("openrouter_probe_error", "openrouter.py")
        probes = _load_plugin("probes_provider_error", "probes/0din.py")
        from garak.attempt import Attempt, Message

        err = module.ProviderError("identity_policy_block", model="openai/gpt-4o")

        class Block:
            def generate(self, conversation, generations_this_call=1):
                raise err

        for probe_cls in (
            probes.BaseHarmfulContentProbe,
            probes.BaseHarmfulContentMultiShot,
            probes.HarryPotterCopyrightProbe,
        ):
            probe = probe_cls()
            probe.generator = Block()
            attempt = Attempt(prompt=Message(text="prompt", lang="en"), probe_classname="0din.Fake")
            with self.assertRaises(module.ProviderError):
                probe._execute_attempt(attempt)
            self.assertEqual(attempt.outputs, [])
            self.assertNotIn("generation_failed", attempt.notes)

        class Boom:
            def generate(self, conversation, generations_this_call=1):
                raise RuntimeError("socket hung up")

        probe = probes.BaseHarmfulContentProbe()
        probe.generator = Boom()
        attempt = Attempt(prompt=Message(text="prompt", lang="en"), probe_classname="0din.Fake")
        result = probe._execute_attempt(attempt)
        self.assertTrue(result.notes.get("generation_failed"))
        self.assertTrue(result.outputs)


if __name__ == "__main__":
    unittest.main()
