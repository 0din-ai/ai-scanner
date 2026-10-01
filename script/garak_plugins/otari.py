"""OpenAI-compatible Otari generator for OpenAI provider:model slugs."""

import inspect
import json
import os
import re
from collections.abc import Mapping, Sequence

from garak import _config
from garak.attempt import Conversation, Message
from garak.exception import BadGeneratorException
from garak.generators.openai import OpenAICompatible


POLICY_CODE = re.compile(r"\b(?:user_blocked|account_blocked|identity_policy_block|policy_violation)\b", re.I)
POLICY_MESSAGE = re.compile(r"\b(?:user|account)\s+(?:has been |is )?blocked\b|\bpolicy violation\b", re.I)
SAFE_ID = re.compile(r"(?:req[-_]|gen[-_]|chatcmpl[-_])[A-Za-z0-9_-]{1,120}\Z|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z", re.I)
SENSITIVE_KEY = re.compile(r"(?:api[_-]?key|token|secret|password|authorization)", re.I)
SECRET_VALUE = re.compile(r"Bearer\s+[A-Za-z0-9._~+\-/=]+|\bsk-(?:or-v1-)?[A-Za-z0-9_-]{8,}\b", re.I)
SECRET_ASSIGNMENT = re.compile(
    r"""((?:api[_-]?key|token|secret|password|authorization)["']?\s*[=:]\s*["']?)[^"'\s,}]+""",
    re.I,
)


def _field(obj, key):
    return obj.get(key) if isinstance(obj, Mapping) else getattr(obj, key, None)


def _safe_detail(value):
    if isinstance(value, Mapping):
        value = {
            key: "[REDACTED]" if SENSITIVE_KEY.search(str(key)) else _safe_detail(nested)
            for key, nested in value.items()
        }
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        value = [_safe_detail(nested) for nested in value]
    elif isinstance(value, str):
        value = SECRET_VALUE.sub("[REDACTED]", value)
        value = SECRET_ASSIGNMENT.sub(lambda match: match.group(1) + "[REDACTED]", value)
    try:
        rendered = json.dumps(value, default=str, ensure_ascii=True)
    except Exception:
        rendered = f"<unprintable {type(value).__name__}>"
    return rendered[:2000] + ("...<truncated>" if len(rendered) > 2000 else "")


class OtariPolicyBlock(BadGeneratorException):
    """Terminal provider policy block; it is not a model refusal or score."""

    def __init__(self, status_code, code, error, request_id=None):
        self.status_code = status_code
        self.code = code
        self.error = error
        self.request_id = request_id
        super().__init__(
            f"provider_policy_block status_code={status_code} code={code} "
            f"request_id={request_id or ''} error={error}"
        )

    def __reduce__(self):
        return (type(self), (self.status_code, self.code, self.error, self.request_id))


class OtariGenerator(OpenAICompatible):
    """Route OpenAI-first model requests through the configured Otari gateway."""

    ENV_VAR = "OTARI_API_KEY"
    active = True
    parallel_capable = False
    supports_multiple_generations = False
    generator_family_name = "Otari"
    DEFAULT_PARAMS = {**OpenAICompatible.DEFAULT_PARAMS, "max_tokens": 2000, "stop": None}

    def _load_unsafe(self):
        import openai

        endpoint = os.getenv("OTARI_API_ENDPOINT")
        key = os.getenv(self.ENV_VAR)
        if not endpoint:
            raise ValueError("OTARI_API_ENDPOINT must be configured")
        if not key:
            raise ValueError("OTARI_API_KEY must be configured")
        self.uri = endpoint
        self.client = openai.OpenAI(api_key=key, base_url=endpoint)
        self.generator = self.client.chat.completions

    def _validate_config(self):
        if not self.name or not self.name.startswith("openai:") or len(self.name) == len("openai:"):
            raise ValueError("Otari currently requires an OpenAI provider:model slug")
        self.context_len = 4096

    def _call_model(self, prompt, generations_this_call=1):
        import openai

        if self.client is None or self.generator is None:
            self._load_unsafe()
        if isinstance(prompt, Conversation):
            messages = self._conversation_to_list(prompt)
        elif isinstance(prompt, str):
            messages = [{"role": "user", "content": prompt}]
        else:
            messages = prompt

        create_args = {}
        for arg in inspect.signature(self.generator.create).parameters:
            if arg == "model":
                create_args[arg] = self.name
            elif arg == "messages":
                create_args[arg] = messages
            elif arg == "n":
                if "n" not in self.suppressed_params:
                    create_args[arg] = 1
            elif arg != "extra_params" and hasattr(self, arg) and arg not in self.suppressed_params:
                value = getattr(self, arg)
                if value is not None:
                    create_args[arg] = value
        create_args.update(getattr(self, "extra_params", {}))

        try:
            raw_response = self.generator.with_raw_response.create(**create_args)
            response = raw_response.parse()
        except openai.APIStatusError as exc:
            body = _field(exc, "body")
            error = _field(body, "error") or body
            self._raise_if_blocked(error, exc.status_code, _field(exc, "response"))
            raise BadGeneratorException(
                f"Otari terminal API status error: model={_safe_detail(self.name)} "
                f"status_code={exc.status_code} error={_safe_detail(error)}"
            ) from None

        extra = _field(response, "model_extra")
        error = _field(response, "error") or _field(extra, "error")
        if error:
            self._raise_if_blocked(error, None, response)
            raise BadGeneratorException(f"Otari terminal API status error: error={_safe_detail(error)}")

        headers = _field(raw_response, "headers") or {}
        if not hasattr(headers, "get"):
            headers = {}
        provider = next((value for value in (
            _field(response, "serving_provider"), _field(extra, "serving_provider"),
            _field(response, "provider"), _field(extra, "provider"),
            headers.get("x-otari-serving-provider"), headers.get("x-otari-provider"),
        ) if isinstance(value, str) and value), None)
        requested_provider = self.name.split(":", 1)[0]
        notes = {
            "gateway": "otari",
            "serving_provider": provider or "unknown",
            "requested_provider": requested_provider,
            "requested_model": self.name,
            "fallback_used": provider.lower() != requested_provider.lower() if provider else None,
        }
        choices = _field(response, "choices") or []
        if not choices:
            raise BadGeneratorException("Otari returned no generations")
        return [Message(text=_field(_field(choice, "message"), "content"), notes=notes) for choice in choices[:1]]

    @staticmethod
    def _raise_if_blocked(error, status_code, response):
        code = _field(error, "code") or _field(error, "type")
        message = _field(error, "message")
        if isinstance(error, str):
            message = error
            if not code and POLICY_CODE.search(error):
                code = error
        if status_code != 403 and not (
            isinstance(code, str) and POLICY_CODE.search(code) or
            isinstance(message, str) and POLICY_MESSAGE.search(message)
        ):
            return
        request_id = _field(response, "request_id") or _field(error, "request_id")
        headers = _field(response, "headers")
        if hasattr(headers, "get"):
            request_id = request_id or headers.get("x-otari-request-id")
        if not isinstance(request_id, str) or not SAFE_ID.fullmatch(request_id):
            request_id = None
        safe_code = code if isinstance(code, str) and POLICY_CODE.fullmatch(code) else "blocked"
        raise OtariPolicyBlock(status_code or 200, safe_code, _safe_detail(error), request_id)


DEFAULT_CLASS = "OtariGenerator"
