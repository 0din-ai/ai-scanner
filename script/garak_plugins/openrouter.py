"""OpenRouter.ai API Generator

Supports various LLMs through OpenRouter.ai's API. Put your API key in
the OPENROUTER_API_KEY environment variable. Put the name of the
model you want in either the --target_name command line parameter, or
pass it as an argument to the Generator constructor.

Usage:
    export OPENROUTER_API_KEY='your-api-key-here'
    garak --target_type openrouter --target_name MODEL_NAME

Example:
    garak --target_type openrouter --target_name anthropic/claude-3-opus

For available models, see: https://openrouter.ai/docs#models

Requires garak 0.14+ (uses Conversation/Message API).
"""

import json
import logging
import re
import sys
import time
from collections.abc import Mapping, Sequence
from typing import List, Union, Optional

from garak import _config
from garak.attempt import Conversation, Message
from garak.exception import BadGeneratorException
from garak.generators.openai import OpenAICompatible

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

# Default context lengths for common models
# These are just examples - any model from OpenRouter will work
context_lengths = {
    "openai/gpt-4-turbo-preview": 128000,
    "openai/gpt-3.5-turbo": 16385,
    "anthropic/claude-3-opus": 200000,
    "anthropic/claude-3-sonnet": 200000,
    "anthropic/claude-2.1": 200000,
    "google/gemini-pro": 32000,
    "meta/llama-2-70b-chat": 4096,
    "mistral/mistral-medium": 32000,
    "mistral/mistral-small": 32000
}

SENSITIVE_KEY_RE = re.compile(r"(?:api[_-]?key|token|secret|password|authorization)", re.I)
# Scheme-aware rules first. The generic authorization rule matches only the
# next token, so "Authorization: Basic <credential>" would redact "Basic"
# and leave the secret if it ran earlier.
# Bearer needs a token-shaped value. "bearer of" is prose; an 8+ char token is not.
_BEARER_PATTERN = (
    re.compile(r"(Bearer\s+)[A-Za-z0-9._~+\-/=]{8,}", re.I),
    r"\1[REDACTED]",
)
# Only after an authorization header. A bare "basic model" is prose.
_AUTH_SCHEME_PATTERN = (
    re.compile(
        r"((?:proxy-authorization|www-authenticate|authorization)[\"']?\s*[:=]\s*[\"']?"
        r"(?:Basic|Digest|NTLM|Negotiate)\s+)[A-Za-z0-9._~+\-/=]+",
        re.I,
    ),
    r"\1[REDACTED]",
)
# Folded cookie lines (a following line that starts with whitespace) are one header.
_COOKIE_PATTERN = (
    re.compile(
        r"((?:set-)?cookie[\"']?\s*[=:]\s*)[^\n]*(?:\n[ \t]+[^\n]*)*",
        re.I,
    ),
    r"\1[REDACTED]",
)
SECRET_VALUE_PATTERNS = (
    _BEARER_PATTERN,
    _AUTH_SCHEME_PATTERN,
    (re.compile(r"((?:api[_-]?key|token|secret|password|authorization)[\"']?\s*[:=]\s*)[\"']?[^\"'\s,}]+", re.I), r"\1[REDACTED]"),
    (re.compile(r"\bsk-(?:or-v1-)?[A-Za-z0-9_-]{8,}\b", re.I), "[REDACTED]"),
)
# Rails redacts these in RunCommand and FailureClassifier. message_hex is
# applied before those sanitizers run, so the encoded text has to already
# be clean. Cookie is last: its .* consumes the rest of the line.
_OUTPUT_REDACTION_PATTERNS = (
    _BEARER_PATTERN,
    _AUTH_SCHEME_PATTERN,
    (re.compile(
        r"((?:api[_-]?key|token|password|secret|access[_-]?token|auth[_-]?token|"
        r"credential|bearer|authorization|cookie|set[_-]?cookie|database[_-]?url|"
        r"redis[_-]?url|secret[_-]?key[_-]?base)[\"']?\s*[=:]\s*[\"']?"
        r"(?:(?:bearer|basic|splunk|negotiate|digest|token|bot)\s+)?)"
        r"[^\s\"',}\]&;]+",
        re.I,
    ), r"\1[REDACTED]"),
    (re.compile(
        r"(x-[\w-]*(?:key|token|auth|secret|cookie)[\w-]*\s*[=:]\s*)[\"']?[^\"'\s,}]+",
        re.I,
    ), r"\1[REDACTED]"),
    _COOKIE_PATTERN,
)


def _safe_getattr(obj, attr, default=None):
    try:
        return getattr(obj, attr)
    except Exception:
        return default


def _redact(value):
    if isinstance(value, Mapping):
        return {
            key: "[REDACTED]" if SENSITIVE_KEY_RE.search(str(key)) else _redact(nested)
            for key, nested in value.items()
        }

    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return [_redact(nested) for nested in value]

    if isinstance(value, str):
        redacted = value
        for pattern, replacement in SECRET_VALUE_PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        return redacted

    return value


def _safe_status_detail(value, max_chars=2000):
    if value is None:
        return ""

    redacted = _redact(value)
    try:
        rendered = repr(redacted)
    except Exception as exc:  # pragma: no cover - defensive fallback
        rendered = f"<unprintable {type(value).__name__}: {type(exc).__name__}>"

    if len(rendered) > max_chars:
        return f"{rendered[:max_chars]}...<truncated>"
    return rendered


def _field(obj, key):
    if obj is None:
        return None
    if isinstance(obj, Mapping):
        return obj.get(key)
    return _safe_getattr(obj, key)


def _as_int(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _as_text(value):
    if isinstance(value, str) and value.strip():
        return value
    return None


_AUTH_ERROR_CODES = frozenset({
    "invalid_api_key",
    "invalid_credentials",
    "authentication_error",
    "unauthorized",
})
_IDENTITY_BLOCK_CODES = frozenset({
    "user_blocked",
    "account_blocked",
    "identity_policy_block",
})
_IDENTITY_BLOCK_MESSAGE = re.compile(
    r"(?:this |the |your )?(?:user|account) (?:has been |is )?blocked "
    r"(?:for|due to) (?:a )?(?:previous )?policy violation",
    re.I,
)
_MODEL_UNAVAILABLE_MESSAGE = re.compile(
    r"deprecated|model\b.*unavailable|unavailable.*\bmodel|no endpoints|"
    r"model\b.*not found|not found.*\bmodel",
    re.I,
)
_SAFE_REQUEST_ID = re.compile(
    r"(?:(?:req[-_]|gen[-_]|chatcmpl[-_])[A-Za-z0-9_-]{1,120}|"
    r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\Z",
    re.I,
)
_UNSAFE_REQUEST_ID = re.compile(
    r"sk[-_]|api[-_]?key|token|secret|password|bearer",
    re.I,
)
_MESSAGE_MAX_CHARS = 300


class ProviderError(Exception):
    """Terminal provider envelope.

    garak's cli.main swallows GarakException and the runner then reports exit 0.
    This is a plain Exception so the process exits 1. str(self) is category and
    model only; the redacted upstream text is the PROVIDER_ERROR line.
    """

    terminal_provider_error = True

    def __init__(
        self,
        category,
        http_status=None,
        provider_status=None,
        provider_code=None,
        provider_error_type=None,
        request_id=None,
        model=None,
    ):
        self.category = category
        self.http_status = http_status
        self.provider_status = provider_status
        self.provider_code = provider_code
        self.provider_error_type = provider_error_type
        self.request_id = request_id
        self.model = model
        super().__init__(str(self))

    def __str__(self):
        text = f"PROVIDER_ERROR category={self.category}"
        if self.model:
            text += f" model={self.model}"
        return text

    def __reduce__(self):
        return (
            type(self),
            (
                self.category,
                self.http_status,
                self.provider_status,
                self.provider_code,
                self.provider_error_type,
                self.request_id,
                self.model,
            ),
        )


def _provider_status(error):
    return _as_int(_field(error, "code"))


def _provider_code(error):
    metadata = _field(error, "metadata")
    nested = _as_text(_field(metadata, "provider_code"))
    if nested:
        return nested
    code = _field(error, "code")
    if isinstance(code, str) and code.strip():
        return code
    return _as_text(_field(error, "provider_code"))


def _provider_error_type(error):
    return _as_text(_field(_field(error, "metadata"), "error_type"))


def _redacted_message(message):
    """Full secret-redacted message. Classification reads this; the record slices it."""
    text = _as_text(message)
    if text is None:
        return None
    redacted = _redact(text)
    return redacted if isinstance(redacted, str) else None


def _logged_message(message):
    if message is None or len(message) <= _MESSAGE_MAX_CHARS:
        return message
    return message[:_MESSAGE_MAX_CHARS]


def _header_request_id(response):
    headers = _field(response, "headers")
    if isinstance(headers, Mapping):
        for key, value in headers.items():
            if isinstance(key, str) and key.lower() == "x-request-id":
                return value
    return None


def _allow_request_id(value):
    if not isinstance(value, str):
        return None
    if not _SAFE_REQUEST_ID.fullmatch(value) or _UNSAFE_REQUEST_ID.search(value):
        return None
    return value


def _safe_request_id(error, response):
    raw = _header_request_id(response) or _field(response, "id") or _field(error, "request_id")
    return _allow_request_id(raw)


def _classify_error_payload(*, http_status, provider_status, provider_code, message):
    code = provider_code.lower() if isinstance(provider_code, str) else ""
    text = message or ""
    statuses = {
        status
        for status in (_as_int(http_status), _as_int(provider_status))
        if status is not None
    }
    if 401 in statuses or code in _AUTH_ERROR_CODES:
        return "auth_failed"
    if 402 in statuses:
        return "billing"
    if 429 in statuses:
        return "rate_limited"
    if any(500 <= status <= 599 for status in statuses):
        return "upstream_unavailable"
    if 404 in statuses or (text and _MODEL_UNAVAILABLE_MESSAGE.search(text)):
        return "model_unavailable"
    if code in _IDENTITY_BLOCK_CODES or (text and _IDENTITY_BLOCK_MESSAGE.search(text)):
        return "identity_policy_block"
    if any(400 <= status <= 499 for status in statuses):
        return "rejected_request"
    return "provider_error"


def _normalize_error(error):
    if isinstance(error, str) and error.strip():
        return {"message": error}
    return error


class _TransientFailure(Exception):
    """Internal signal for one retryable envelope. Never leaves _create_with_retry."""

    def __init__(self, category, provider_status, response):
        self.category = category
        self.provider_status = provider_status
        self.response = response
        super().__init__(category)


class ProviderRetryExhausted(Exception):
    """Retries for a transient provider failure are used up.

    Not a GarakException, and not terminal_provider_error: probe handlers keep
    the per-attempt generation-failed marker. Pickle-safe so a worker pool can
    return it. openai exceptions are not: their constructor requires response.
    """

    def __init__(self, category, provider_status=None, model=None):
        self.category = category
        self.provider_status = provider_status
        self.model = model
        super().__init__(str(self))

    def __str__(self):
        text = f"PROVIDER_RETRY_EXHAUSTED category={self.category}"
        if self.model:
            text += f" model={self.model}"
        return text

    def __reduce__(self):
        return (type(self), (self.category, self.provider_status, self.model))


def _retry_after_seconds(source):
    if isinstance(source, _TransientFailure):
        headers = _field(source.response, "headers")
    else:
        headers = _field(_safe_getattr(source, "response"), "headers")
    if not isinstance(headers, Mapping):
        return None
    raw = None
    for key, value in headers.items():
        if isinstance(key, str) and key.lower() == "retry-after":
            raw = value
            break
    try:
        seconds = float(str(raw).strip())
    except (TypeError, ValueError):
        return None
    if seconds < 0:
        return None
    return min(seconds, 30.0)


class OpenRouterGenerator(OpenAICompatible):
    """Generator wrapper for OpenRouter.ai models. Expects API key in the OPENROUTER_API_KEY environment variable"""

    ENV_VAR = "OPENROUTER_API_KEY"
    active = True
    supports_multiple_generations = True
    _MAX_TRANSIENT_ATTEMPTS = 5
    generator_family_name = "OpenRouter"
    DEFAULT_PARAMS = {
        **OpenAICompatible.DEFAULT_PARAMS,
        "uri": OPENROUTER_BASE_URL,
        "max_tokens": 2000,
        "stop": None
    }

    def __init__(self, name="", config_root=_config):
        self.name = name
        self._load_config(config_root)
        if self.name in context_lengths:
            self.context_len = context_lengths[self.name]

        # Pin the API root before parent initialization creates the client.
        self.uri = OPENROUTER_BASE_URL
        super().__init__(self.name, config_root=config_root)

    def _load_unsafe(self):
        """Initialize the OpenAI client with OpenRouter.ai base URL"""
        import openai

        self.uri = OPENROUTER_BASE_URL
        self.client = openai.OpenAI(
            api_key=self._get_api_key(),
            base_url=OPENROUTER_BASE_URL
        )

        self.generator = self.client.chat.completions

    def _get_api_key(self):
        """Get API key from environment variable"""
        import os
        key = os.getenv(self.ENV_VAR)
        if not key:
            raise ValueError(f"Please set the {self.ENV_VAR} environment variable with your OpenRouter API key")
        return key

    def _validate_config(self):
        """Validate the configuration"""
        if not self.name:
            raise ValueError("Model name must be specified")

        # Set a default context length if not specified
        if self.name not in context_lengths:
            logging.info(
                f"Model {self.name} not in list of known context lengths. Using default of 4096 tokens."
            )
            self.context_len = 4096

    def _log_completion_details(self, prompt, response):
        """Log completion details at DEBUG level"""
        logging.debug("=== Model Input ===")
        if isinstance(prompt, str):
            logging.debug(f"Prompt: {prompt}")
        elif isinstance(prompt, Conversation):
            logging.debug("Conversation:")
            for turn in prompt.turns:
                logging.debug(f"- Role: {turn.role}")
                logging.debug(f"  Content: {turn.content.text if turn.content else ''}")
        else:
            logging.debug("Messages:")
            for msg in prompt:
                logging.debug(f"- Role: {msg.get('role', 'unknown')}")
                logging.debug(f"  Content: {msg.get('content', '')}")

        logging.debug("\n=== Model Output ===")
        usage = getattr(response, "usage", None)
        if usage is not None:
            logging.debug(f"Prompt Tokens: {usage.prompt_tokens}")
            logging.debug(f"Completion Tokens: {usage.completion_tokens}")
            logging.debug(f"Total Tokens: {usage.total_tokens}")

        logging.debug("\nGenerated Text:")
        # OpenAI response object always has choices
        for choice in response.choices:
            if hasattr(choice, 'message'):
                logging.debug(f"- Message Content: {choice.message.content}")
                if hasattr(choice.message, 'role'):
                    logging.debug(f"  Role: {choice.message.role}")
                if hasattr(choice.message, 'function_call'):
                    logging.debug(f"  Function Call: {choice.message.function_call}")
            elif hasattr(choice, 'text'):
                logging.debug(f"- Text: {choice.text}")

            # Log additional choice attributes if present
            if hasattr(choice, 'finish_reason'):
                logging.debug(f"  Finish Reason: {choice.finish_reason}")
            if hasattr(choice, 'index'):
                logging.debug(f"  Choice Index: {choice.index}")

        # Log model info if present
        if hasattr(response, 'model'):
            logging.debug(f"\nModel: {response.model}")
        if hasattr(response, 'system_fingerprint'):
            logging.debug(f"System Fingerprint: {response.system_fingerprint}")

        logging.debug("==================")

    def _call_model(
        self, prompt: Union[Conversation, str, List[dict]], generations_this_call: int = 1
    ) -> List[Optional[Message]]:
        """Call model and handle both logging and response.

        Args:
            prompt: Conversation object (garak 0.14+), string, or list of message dicts
            generations_this_call: Number of generations to request

        Returns:
            List of Message objects (or None for failed generations)
        """
        try:
            # Ensure client is initialized
            if self.client is None or self.generator is None:
                self._load_unsafe()

            # Convert prompt to messages format for the API call
            if isinstance(prompt, Conversation):
                messages = self._conversation_to_list(prompt)
            elif isinstance(prompt, str):
                messages = [{"role": "user", "content": prompt}]
            else:
                messages = prompt

            # Try a single batched call first. Most OpenRouter routes honor n=,
            # but some upstream providers ignore it and return only one choice.
            raw_response = self._create_with_retry(
                model=self.name,
                messages=messages,
                n=generations_this_call if "n" not in self.suppressed_params else None,
                max_tokens=self.max_tokens if hasattr(self, 'max_tokens') else None
            )

            # Log the completion details
            self._log_completion_details(prompt, raw_response)

            response_messages = self._messages_from_response(raw_response)
            self._raise_if_all_generations_empty(response_messages)
            if len(response_messages) == generations_this_call:
                return response_messages

            if generations_this_call <= 1:
                return response_messages or [None]

            logging.warning(
                "OpenRouter route returned %s choices for n=%s; falling back to sequential n=1 calls",
                len(response_messages),
                generations_this_call,
            )
            return self._call_model_sequential(messages, generations_this_call, prompt)

        except (ProviderError, ProviderRetryExhausted):
            raise
        except BadGeneratorException:
            raise
        except Exception as e:
            self._raise_terminal_api_status_error(e)
            logging.error(f"Error in model call: {str(e)}")
            return [None] * generations_this_call

    def _call_model_sequential(self, messages, generations_this_call, original_prompt):
        responses = []
        for _ in range(generations_this_call):
            try:
                raw_response = self._create_with_retry(
                    model=self.name,
                    messages=messages,
                    n=1 if "n" not in self.suppressed_params else None,
                    max_tokens=self.max_tokens if hasattr(self, 'max_tokens') else None
                )
                self._log_completion_details(original_prompt, raw_response)
                response_messages = self._messages_from_response(raw_response)
                self._raise_if_all_generations_empty(response_messages)
                responses.append(response_messages[0] if response_messages else None)
            except (ProviderError, ProviderRetryExhausted):
                raise
            except BadGeneratorException:
                raise
            except Exception as e:
                self._raise_terminal_api_status_error(e)
                logging.error(f"Error in sequential model call: {str(e)}")
                responses.append(None)
        return responses

    def _messages_from_response(self, raw_response):
        return [
            Message(text=choice.message.content) if choice.message.content else None
            for choice in raw_response.choices
        ]

    def _raise_if_all_generations_empty(self, response_messages):
        if response_messages and all(message is None for message in response_messages):
            raise BadGeneratorException(
                "OpenRouter returned only empty generations; the provider route may be unavailable."
            )

    def _raise_for_completion(self, response):
        error = _field(response, "error")
        if error is None:
            error = _field(_field(response, "model_extra"), "error")
        if error is None:
            return
        self._emit_provider_error(error, http_status=200, response=response)

    def _emit_provider_error(self, error, http_status, response):
        error = _normalize_error(error)
        http_status = _as_int(http_status)
        provider_status = _provider_status(error)
        provider_code = _provider_code(error)
        provider_error_type = _provider_error_type(error)
        message = _redacted_message(_field(error, "message") if error is not None else None)
        request_id = _safe_request_id(error, response)
        model = self.name if isinstance(getattr(self, "name", None), str) and self.name else None
        category = _classify_error_payload(
            http_status=http_status,
            provider_status=provider_status,
            provider_code=provider_code,
            message=message,
        )
        self._write_record(
            category=category,
            http_status=http_status,
            provider_status=provider_status,
            provider_code=provider_code,
            provider_error_type=provider_error_type,
            request_id=request_id,
            message=message,
        )
        if category in ("rate_limited", "upstream_unavailable"):
            raise _TransientFailure(category, provider_status, response)
        raise ProviderError(
            category,
            http_status,
            provider_status,
            provider_code,
            provider_error_type,
            request_id,
            model,
        ) from None

    def _raise_terminal_api_status_error(self, exc):
        import openai

        if isinstance(exc, (
            openai.RateLimitError,
            openai.InternalServerError,
            openai.APITimeoutError,
            openai.APIConnectionError,
        )):
            raise self._retry_exhausted(exc) from None

        if isinstance(exc, openai.APIStatusError):
            self._emit_from_status(exc)

        if isinstance(exc, openai.APIResponseValidationError):
            self._emit_from_validation(exc)

    def _emit_from_status(self, exc):
        body = _safe_getattr(exc, "body")
        error = _field(body, "error")
        if error is None and (_field(body, "message") is not None or _field(body, "code") is not None):
            error = body
        http_status = _as_int(_safe_getattr(exc, "status_code"))
        if http_status is None:
            http_status = _as_int(_safe_getattr(_safe_getattr(exc, "response"), "status_code"))
        self._emit_provider_error(error, http_status=http_status, response=_safe_getattr(exc, "response"))

    def _emit_from_validation(self, exc):
        body = _safe_getattr(exc, "body")
        response = _safe_getattr(exc, "response")
        if body is None and response is not None:
            text = _safe_getattr(response, "text")
            if isinstance(text, str):
                try:
                    body = json.loads(text)
                except ValueError:
                    body = None
        error = _field(body, "error")
        # No envelope: this is a malformed completion, not a provider refusal.
        # Return so the caller's except Exception logs it and yields [None].
        if error is None:
            return
        http_status = _as_int(_safe_getattr(response, "status_code")) or 200
        self._emit_provider_error(error, http_status=http_status, response=response)

    def _message_hex(self, message):
        if not isinstance(message, str) or not message:
            return None
        redacted = message
        for pattern, replacement in SECRET_VALUE_PATTERNS + _OUTPUT_REDACTION_PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        logged = _logged_message(redacted)
        if logged is None:
            return None
        try:
            return logged.encode("utf-8", "backslashreplace").hex()
        except Exception:
            return None

    def _write_record(self, *, category, http_status, provider_status, provider_code,
                      provider_error_type, request_id, message):
        model = self.name if isinstance(getattr(self, "name", None), str) and self.name else None
        record = {
            "v": 1,
            "provider": self.generator_family_name,
            "model": model,
            "category": category,
            "http_status": http_status,
            "provider_status": provider_status,
            "provider_code": provider_code,
            "provider_error_type": provider_error_type,
            "request_id": request_id,
            # Hex, not text: RunCommand's output sanitizer would otherwise eat
            # JSON escapes and the rest of a line that contains "Cookie:".
            "message_hex": self._message_hex(message),
        }
        try:
            payload = json.dumps(record, separators=(",", ":"), ensure_ascii=True, sort_keys=True)
            logging.error("PROVIDER_ERROR %s", payload)
            print("PROVIDER_ERROR " + payload, file=sys.stderr, flush=True)
        except Exception:
            # A bad character must not swallow the provider exception or skip retry.
            pass

    def _emit_native_exhaustion(self, source):
        import openai

        if isinstance(source, openai.RateLimitError):
            category = "rate_limited"
        else:
            category = "upstream_unavailable"
        status = _as_int(_safe_getattr(source, "status_code"))
        self._write_record(
            category=category,
            http_status=status,
            provider_status=status,
            provider_code=None,
            provider_error_type=None,
            request_id=_safe_request_id(None, _safe_getattr(source, "response")),
            message=_redacted_message(str(source)) if source is not None else None,
        )

    def _sleep(self, seconds):
        time.sleep(seconds)

    def _create_with_retry(self, **kwargs):
        import openai

        transient_errors = (
            openai.RateLimitError,
            openai.InternalServerError,
            openai.APITimeoutError,
            openai.APIConnectionError,
        )
        last = None
        for attempt in range(1, self._MAX_TRANSIENT_ATTEMPTS + 1):
            try:
                response = self.generator.create(**kwargs)
                self._raise_for_completion(response)
                return response
            except _TransientFailure as exc:
                last = exc
            except transient_errors as exc:
                last = exc
            except openai.APIStatusError as exc:
                try:
                    self._emit_from_status(exc)
                except _TransientFailure as inner:
                    last = inner
            except openai.APIResponseValidationError as exc:
                try:
                    self._emit_from_validation(exc)
                except _TransientFailure as inner:
                    last = inner
                else:
                    raise
            if attempt == self._MAX_TRANSIENT_ATTEMPTS:
                if not isinstance(last, _TransientFailure):
                    self._emit_native_exhaustion(last)
                raise self._retry_exhausted(last) from None
            self._sleep(self._retry_delay(last, attempt))

    def _retry_delay(self, source, attempt):
        retry_after = _retry_after_seconds(source)
        if retry_after is not None:
            return retry_after
        return float(min(2 ** (attempt - 1), 8))

    def _retry_exhausted(self, source):
        import openai

        if isinstance(source, _TransientFailure):
            category = source.category
            status = _as_int(source.provider_status)
        elif isinstance(source, openai.RateLimitError):
            category = "rate_limited"
            status = _as_int(_safe_getattr(source, "status_code")) or 429
        else:
            category = "upstream_unavailable"
            status = _as_int(_safe_getattr(source, "status_code"))
        model = self.name if isinstance(getattr(self, "name", None), str) and self.name else None
        return ProviderRetryExhausted(category, status, model)


DEFAULT_CLASS = "OpenRouterGenerator"
