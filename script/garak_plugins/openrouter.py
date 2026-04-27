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
from typing import List, Union, Optional

from garak import _config
from garak.generators.openai import OpenAICompatible
from garak.attempt import Conversation, Message

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

        except Exception as e:
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
                responses.append(response_messages[0] if response_messages else None)
            except Exception as e:
                logging.error(f"Error in sequential model call: {str(e)}")
                responses.append(None)
        return responses

    def _messages_from_response(self, raw_response):
        return [
            Message(text=choice.message.content) if choice.message.content else None
            for choice in raw_response.choices
        ]

DEFAULT_CLASS = "OpenRouterGenerator"
