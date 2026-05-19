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

import logging
import re
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
SECRET_VALUE_PATTERNS = (
    (re.compile(r"(Bearer\s+)[A-Za-z0-9._~+\-/=]+", re.I), r"\1[REDACTED]"),
    (re.compile(r"((?:api[_-]?key|token|secret|password|authorization)[\"']?\s*[:=]\s*)[\"']?[^\"'\s,}]+", re.I), r"\1[REDACTED]"),
    (re.compile(r"\bsk-(?:or-v1-)?[A-Za-z0-9_-]{8,}\b", re.I), "[REDACTED]"),
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


def _terminal_api_status_message(exc, provider, model):
    response = _safe_getattr(exc, "response")
    status_code = _safe_getattr(exc, "status_code")
    if status_code is None:
        status_code = _safe_getattr(response, "status_code")

    reason = _safe_getattr(response, "reason_phrase") or _safe_getattr(response, "reason")
    message = _safe_getattr(exc, "message") or str(exc)
    body = _safe_getattr(exc, "body")
    if body is None and response is not None:
        body = _safe_getattr(response, "text")

    return (
        f"{provider} terminal API status error: "
        f"model={_safe_status_detail(model)} "
        f"status_code={_safe_status_detail(status_code)} "
        f"reason={_safe_status_detail(reason)} "
        f"message={_safe_status_detail(message)} "
        f"body={_safe_status_detail(body)}"
    )


class OpenRouterGenerator(OpenAICompatible):
    """Generator wrapper for OpenRouter.ai models. Expects API key in the OPENROUTER_API_KEY environment variable"""

    ENV_VAR = "OPENROUTER_API_KEY"
    active = True
    supports_multiple_generations = True
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
        if hasattr(response, 'usage'):
            logging.debug(f"Prompt Tokens: {response.usage.prompt_tokens}")
            logging.debug(f"Completion Tokens: {response.usage.completion_tokens}")
            logging.debug(f"Total Tokens: {response.usage.total_tokens}")

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
            raw_response = self.generator.create(
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
                raw_response = self.generator.create(
                    model=self.name,
                    messages=messages,
                    n=1 if "n" not in self.suppressed_params else None,
                    max_tokens=self.max_tokens if hasattr(self, 'max_tokens') else None
                )
                self._log_completion_details(original_prompt, raw_response)
                response_messages = self._messages_from_response(raw_response)
                self._raise_if_all_generations_empty(response_messages)
                responses.append(response_messages[0] if response_messages else None)
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

    def _raise_terminal_api_status_error(self, exc):
        import openai

        if isinstance(exc, (openai.RateLimitError, openai.InternalServerError)):
            raise exc

        if isinstance(exc, openai.APIStatusError):
            raise BadGeneratorException(
                _terminal_api_status_message(exc, self.generator_family_name, self.name)
            ) from exc


DEFAULT_CLASS = "OpenRouterGenerator"
