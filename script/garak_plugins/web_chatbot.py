"""Web Chatbot Generator

This generator enables interaction with web-based chatbots through browser automation.
It uses Playwright to navigate to chatbot interfaces, send prompts, and extract responses.

Requires garak 0.14.1 (uses Conversation/Message API).
"""

import logging
import asyncio
from typing import List, Union, Optional
import json

from playwright.async_api import async_playwright, Page, Browser, TimeoutError as PlaywrightTimeoutError

from garak.generators.base import Generator
from garak import _config
from garak.attempt import Conversation, Message

class WebChatbotGenerator(Generator):
    """Web-based chatbot interface using browser automation

    This generator automates interactions with web-based chatbots through browser automation.
    It navigates to the specified URL, interacts with the chat interface, and extracts responses.

    Configuration should include:
    - url: The chatbot URL
    - selectors: CSS/XPath selectors for chat elements
    - wait_times: Timeouts for various operations
    """

    DEFAULT_PARAMS = Generator.DEFAULT_PARAMS | {
        "url": None,
        "selectors": {
            "chat_button": None,  # Optional: button to open chat
            "input_field": None,  # Required: text input field
            "send_button": None,  # Optional: send button (will use Enter key if not provided)
            "response_container": None,  # Required: response area
            "response_text": None,  # Optional: specific text element within response
        },
        "wait_times": {
            "page_load": 10000,  # ms to wait for page load
            "chat_open": 5000,   # ms to wait for chat to open
            "response": 30000,   # ms to wait for response
            "typing_delay": 50,  # ms delay between keystrokes
        },
        "browser_options": {
            "headless": True,
            "viewport": {"width": 1280, "height": 720},
        },
        "response_extraction": {
            "method": "text",  # "text", "innerText", "innerHTML"
            "wait_for_stability": True,  # Wait for response to stop changing
            "stability_timeout": 2000,  # ms to wait for stable response
        },
        "detection": {
            # Selectors to try for finding response messages (in order of priority)
            "response_message_selectors": [],  # e.g., ['.outputBox .markdownContainer', '.message', '[role="article"]']

            # Selectors for last/newest message (with :last-child)
            "last_message_selectors": [],  # e.g., ['.message:last-child', '.bot-message:last-child']

            # Text patterns to skip (UI elements, not actual responses)
            "skip_patterns": [],  # e.g., ['ai chat is', 'enjoying', 'cookie', 'copied!']

            # Minimum response length to consider valid
            "min_response_length": 5,
        },
        "auth": {
            "cookies": [],          # list of Playwright cookie dicts
            "headers": {},          # extra_http_headers
            "storage_state": None,  # Playwright storage_state object
        },
    }

    generator_family_name = "WebChatbot"
    supports_multiple_generations = False
    parallel_capable = False

    def __init__(self, name="", config_root=_config):
        self.name = name
        self._browser = None
        self._context = None
        self._page = None
        self._playwright = None

        # Call parent to load configuration
        super().__init__(name=name, config_root=config_root)

        # URL can come from name or config
        if not hasattr(self, 'url') or not self.url:
            self.url = self.name if self.name else None

        if not self.url:
            raise ValueError("WebChatbotGenerator requires a 'url' parameter (via name or config)")

        # Validate selectors after config is loaded
        if not hasattr(self, 'selectors') or not self.selectors:
            raise ValueError("WebChatbotGenerator requires 'selectors' configuration")

        if not self.selectors.get("input_field"):
            raise ValueError("WebChatbotGenerator requires 'input_field' selector (send_button is optional, will use Enter key if not provided)")

        # Initialize browser asynchronously
        # We need to run this in an event loop
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # If loop is running, schedule initialization
                asyncio.create_task(self._init_browser())
            else:
                # If no loop running, run it now
                loop.run_until_complete(self._init_browser())
        except RuntimeError:
            # No event loop, create one
            asyncio.run(self._init_browser())

    @staticmethod
    def _build_context_kwargs(auth, browser_options):
        """Pure mapping of auth + viewport into browser.new_context kwargs."""
        kwargs = {}
        viewport = (browser_options or {}).get("viewport")
        if viewport:
            kwargs["viewport"] = viewport
        auth = auth or {}
        headers = auth.get("headers")
        if headers:
            headers = {k: v for k, v in headers.items() if k.lower() != "host"}
        if headers:
            kwargs["extra_http_headers"] = headers
        storage_state = auth.get("storage_state")
        if storage_state:
            kwargs["storage_state"] = storage_state
        return kwargs

    @staticmethod
    def _normalize_cookies(cookies):
        """Mirror the Ruby normalize_cookie: default path to '/' when a cookie has a
        domain but no url/path, and capitalize sameSite to Playwright's enum casing."""
        normalized = []
        for cookie in cookies or []:
            if not isinstance(cookie, dict):
                continue
            c = dict(cookie)
            if c.get("domain") and not c.get("url") and not c.get("path"):
                c["path"] = "/"
            if c.get("sameSite"):
                c["sameSite"] = str(c["sameSite"]).capitalize()
            normalized.append(c)
        return normalized

    async def _init_browser(self):
        """Initialize Playwright browser instance"""
        try:
            self._playwright = await async_playwright().start()
            self._browser = await self._playwright.chromium.launch(
                headless=self.browser_options.get("headless", True),
                args=['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
            )

            self._context = await self._browser.new_context(
                **self._build_context_kwargs(getattr(self, "auth", None), self.browser_options)
            )
            cookies = self._normalize_cookies((getattr(self, "auth", None) or {}).get("cookies") or [])
            if cookies:
                await self._context.add_cookies(cookies)
            self._page = await self._context.new_page()

            # Navigate to the chatbot URL
            # Use domcontentloaded instead of networkidle for better compatibility
            await self._page.goto(self.url, wait_until="domcontentloaded", timeout=self.wait_times["page_load"])
            # Wait a bit for dynamic content to load
            await self._page.wait_for_timeout(2000)

            # If there's a chat button to open the chat interface, click it
            if chat_button := self.selectors.get("chat_button"):
                try:
                    await self._page.wait_for_selector(chat_button, timeout=5000)
                    await self._page.click(chat_button)
                    await asyncio.sleep(self.wait_times["chat_open"] / 1000)
                except PlaywrightTimeoutError:
                    logging.warning(f"Chat button '{chat_button}' not found, continuing...")

        except Exception as e:
            logging.error(f"Failed to initialize browser: {e}")
            raise

    def _extract_prompt_text(self, prompt: Union[Conversation, str]) -> str:
        """Extract text from prompt, handling both Conversation and string inputs."""
        if isinstance(prompt, Conversation):
            # Get the last user message text from the conversation
            for turn in reversed(prompt.turns):
                if turn.role == "user" and turn.content:
                    return turn.content.text or ""
            return ""
        return prompt

    def _call_model(self, prompt: Union[Conversation, str], generations_this_call: int = 1) -> List[Optional[Message]]:
        """Send prompt to web chatbot and extract response (sync wrapper for async implementation)

        Args:
            prompt: Conversation object (garak 0.14.1) or string
            generations_this_call: Number of generations (currently only 1 supported)

        Returns:
            List of Message objects (or None for failed generations)
        """
        # Extract text from Conversation if needed
        prompt_text = self._extract_prompt_text(prompt)

        # Sync wrapper that runs the async version
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # If loop is already running, create a task and wait for it
                # This happens when called from garak's async context
                import concurrent.futures
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    future = pool.submit(asyncio.run, self._call_model_async(prompt_text, generations_this_call))
                    return future.result()
            else:
                # No loop running, run it directly
                return loop.run_until_complete(self._call_model_async(prompt_text, generations_this_call))
        except RuntimeError:
            # No event loop, create one
            return asyncio.run(self._call_model_async(prompt_text, generations_this_call))

    async def _call_model_async(self, prompt: str, generations_this_call: int = 1) -> List[Optional[Message]]:
        """Send prompt to web chatbot and extract response (async implementation)

        Args:
            prompt: The prompt text string
            generations_this_call: Number of generations (currently only 1 supported)

        Returns:
            List of Message objects (or None for failed generations)
        """
        if generations_this_call > 1:
            logging.warning("WebChatbotGenerator only supports single generation, using 1")

        # Clear chat history before each probe to ensure isolated testing
        await self.clear_history_async()

        try:
            # Find and clear the input field
            input_selector = self.selectors["input_field"]
            # Use page_load timeout for finding input field
            input_timeout = self.wait_times.get("page_load", 10000)
            await self._page.wait_for_selector(input_selector, timeout=input_timeout)
            input_field = await self._page.query_selector(input_selector)

            # Check if element is contenteditable
            is_contenteditable = await input_field.evaluate('el => el.contentEditable === "true" || el.hasAttribute("contenteditable")')

            # Store initial state for response detection
            response_selector = self.selectors["response_container"]
            container = await self._page.query_selector(response_selector)
            initial_state = await self._capture_container_state(container)

            # Handle contenteditable elements differently
            if is_contenteditable:
                # Use JavaScript to set content and trigger events for contenteditable divs
                logging.debug(f"Using contenteditable mode for input")
                await self._page.evaluate('''
                    (args) => {
                        const el = document.querySelector(args.selector);
                        if (el) {
                            el.focus();
                            el.textContent = args.text;
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                            el.dispatchEvent(new Event('change', { bubbles: true }));
                            return true;
                        }
                        return false;
                    }
                ''', {'selector': input_selector, 'text': prompt})
                logging.debug(f"Text set in contenteditable element")
            else:
                # Standard input/textarea handling
                logging.debug(f"Using standard input mode")
                await input_field.fill("")
                # Type the prompt with optional delay
                if typing_delay := self.wait_times.get("typing_delay", 0):
                    await input_field.type(prompt, delay=typing_delay)
                else:
                    await input_field.fill(prompt)
                logging.debug(f"Text filled in standard input")

            # Send the message - try multiple methods
            message_sent = False

            # Method 1: Click send button if available
            send_selector = self.selectors.get("send_button")
            if send_selector:
                try:
                    logging.debug(f"Looking for send button: {send_selector}")
                    send_button = await self._page.query_selector(send_selector)
                    if send_button:
                        is_visible = await send_button.is_visible()
                        is_enabled = await send_button.is_enabled()
                        logging.debug(f"Send button found - visible: {is_visible}, enabled: {is_enabled}")
                        if is_visible and is_enabled:
                            await send_button.click()
                            message_sent = True
                            logging.debug("Message sent via button click")
                        else:
                            logging.debug(f"Send button not clickable")
                    else:
                        logging.debug(f"Send button not found")
                except Exception as e:
                    logging.debug(f"Error clicking send button: {e}")

            # Method 2: Press Enter if button didn't work
            if not message_sent:
                await input_field.press("Enter")
                logging.debug("Message sent via Enter key")

            # Small delay after sending
            await self._page.wait_for_timeout(500)

            # Wait for response
            logging.debug(f"Waiting for response with timeout: {self.wait_times['response']}ms")
            response = await self._wait_for_response(initial_state)
            logging.debug(f"Response received: {response[:100] if response else 'None'}")

            # Return Message object (garak 0.14.1 format)
            return [Message(text=response) if response else None]

        except PlaywrightTimeoutError:
            logging.error(f"Timeout waiting for chatbot response to prompt: {prompt[:50]}...")
            return [None]
        except Exception as e:
            logging.error(f"Error during chatbot interaction: {e}")
            return [None]

    async def _wait_for_response(self, initial_state: dict) -> Union[str, None]:
        """Wait for and extract chatbot response using multiple detection strategies"""
        response_selector = self.selectors["response_container"]
        wait_timeout = self.wait_times["response"]

        try:
            # Set up MutationObserver to detect DOM changes
            await self._page.evaluate(f'''
                (() => {{
                    window.__responseDetected = false;
                    const container = document.querySelector('{response_selector}');
                    if (container) {{
                        const observer = new MutationObserver((mutations) => {{
                            window.__responseDetected = true;
                        }});
                        observer.observe(container, {{
                            childList: true,
                            subtree: true,
                            characterData: true
                        }});
                    }}
                }})()
            ''')

            # Wait for response using multiple strategies
            response_text = None
            start_time = asyncio.get_event_loop().time()

            while (asyncio.get_event_loop().time() - start_time) < (wait_timeout / 1000):
                # Strategy 1: Check if MutationObserver detected changes
                mutation_detected = await self._page.evaluate('window.__responseDetected')

                # Strategy 2: Check for text changes in container
                container = await self._page.query_selector(response_selector)
                if container and not response_text:
                    current_state = await self._capture_container_state(container)

                    # Only check for meaningful text changes (ignore small UI updates)
                    if len(current_state['text']) > len(initial_state['text']) + 20:
                        # Extract the new content
                        new_text = await self._extract_new_response(container, initial_state['text'], current_state['text'])
                        if new_text and len(new_text) > 5:
                            response_text = new_text
                            break

                # Strategy 3: Look for specific message elements
                # Get config values
                skip_patterns = self.detection.get("skip_patterns", [])
                min_length = self.detection.get("min_response_length", 5)

                # Special handling for response_text selector
                if response_text_selector := self.selectors.get("response_text"):
                    try:
                        # Try to find elements within container first (scoped search)
                        if container:
                            elements = await container.query_selector_all(response_text_selector)
                        else:
                            # Fallback to page-level search if no container
                            elements = await self._page.query_selector_all(response_text_selector)

                        for element in elements:
                            msg_text = await element.text_content()
                            if msg_text:
                                msg_text = msg_text.strip()
                                # Check if this is a new message (not in initial state)
                                if (len(msg_text) > min_length and
                                    msg_text not in initial_state.get('messages', []) and
                                    not any(skip.lower() in msg_text.lower() for skip in skip_patterns)):
                                    response_text = msg_text
                                    logging.debug(f"Found response via response_text selector: {response_text[:100]}")
                                    break
                    except Exception as e:
                        logging.debug(f"Error with response_text selector: {e}")

                # If no response found yet, try configured selectors
                if not response_text:
                    # Get selectors from config - try response_message_selectors first, then last_message_selectors
                    config_selectors = self.detection.get("response_message_selectors", [])
                    if not config_selectors:
                        config_selectors = self.detection.get("last_message_selectors", [])

                    # Fallback to container-scoped defaults if no config selectors
                    if not config_selectors:
                        config_selectors = [
                            f'{response_selector} .message:last-child',
                            f'{response_selector} .bot-message:last-child',
                            f'{response_selector} [role="article"]:last-child',
                            f'{response_selector} [class*="message"]:last-child'
                        ]

                    for msg_selector in config_selectors:
                        try:
                            # Prefer container-scoped search for better accuracy
                            if container and not msg_selector.startswith(response_selector):
                                # Selector is relative, use within container
                                elements = await container.query_selector_all(msg_selector)
                            else:
                                # Selector is absolute or no container available
                                elements = await self._page.query_selector_all(msg_selector)

                            for element in elements:
                                msg_text = await element.text_content()
                                if (msg_text and
                                    len(msg_text.strip()) > min_length and
                                    msg_text not in initial_state.get('messages', []) and
                                    not any(skip.lower() in msg_text.lower() for skip in skip_patterns)):
                                    response_text = msg_text.strip()
                                    logging.debug(f"Found response via {msg_selector}: {response_text[:100]}")
                                    break
                        except:
                            continue

                        if response_text:
                            break

                if response_text:
                    break

                # Small delay before next check
                await self._page.wait_for_timeout(100)

            if response_text:
                # Wait for response to stabilize if configured
                if self.response_extraction.get("wait_for_stability", True):
                    response_text = await self._wait_for_stable_text(response_selector, response_text)

                logging.debug(f"Response detected: {response_text[:100]}...")
                return response_text
            else:
                logging.warning("No response detected within timeout")
                return None

        except PlaywrightTimeoutError:
            logging.error("Timeout waiting for chatbot response")
            return None
        except Exception as e:
            logging.error(f"Error extracting response: {e}")
            return None

    async def _wait_for_stable_text(self, selector: str, initial_text: str) -> str:
        """Wait for response text to stop changing and return final text"""
        stability_timeout = self.response_extraction.get("stability_timeout", 2000)
        check_interval = 100  # ms

        previous_text = initial_text
        stable_count = 0
        required_stable_checks = stability_timeout // check_interval

        while stable_count < required_stable_checks:
            container = await self._page.query_selector(selector)
            if container:
                current_text = await container.text_content() or ""
                # Extract just the new part
                if len(current_text) > len(previous_text):
                    new_part = current_text[len(previous_text):].strip()
                    if new_part:
                        previous_text = current_text
                        stable_count = 0
                        continue

                if current_text == previous_text:
                    stable_count += 1
                else:
                    stable_count = 0
                    previous_text = current_text
            await asyncio.sleep(check_interval / 1000)

        return previous_text

    async def _capture_container_state(self, container) -> dict:
        """Capture the current state of the response container"""
        if not container:
            return {'text': '', 'count': 0, 'messages': []}

        # Capture existing actual messages (not UI elements)
        messages = []

        # Get message selectors from config
        config_selectors = self.detection.get("response_message_selectors", [])

        # Fallback to generic selectors if no config provided
        if not config_selectors:
            config_selectors = ['.message', '[role="article"]', '.bot-message', '.assistant-message']

        # Use container-scoped search for better accuracy
        for selector in config_selectors:
            elements = await container.query_selector_all(selector) if container else []
            for el in elements:
                msg_text = await el.text_content()
                if msg_text and len(msg_text.strip()) > 2:
                    messages.append(msg_text.strip())

        return {
            'text': await container.text_content() if container else '',
            'count': len(await container.query_selector_all('*')) if container else 0,
            'messages': messages
        }

    async def _extract_new_response(self, container, old_text: str, new_text: str) -> str:
        """Extract only the new response text from the container"""
        if not new_text:
            return ""

        # Get config values
        skip_patterns = self.detection.get("skip_patterns", [])
        min_length = self.detection.get("min_response_length", 5)

        # Get message selectors from config
        config_selectors = self.detection.get("last_message_selectors", [])

        # Fallback to generic selectors if no config provided
        if not config_selectors:
            config_selectors = [
                '.message:last-child',
                '.bot-message:last-child',
                '.assistant-message:last-child',
                '[role="article"]:last-child',
                '[data-role="assistant"]:last-child',
                '.chat-message:last-child'
            ]

        # Try to find actual message elements
        for selector in config_selectors:
            try:
                msg_element = await container.query_selector(selector)
                if msg_element:
                    msg_text = await msg_element.text_content()
                    # Filter out UI elements and empty messages
                    if msg_text and len(msg_text) > min_length and not any(skip.lower() in msg_text.lower() for skip in skip_patterns):
                        return msg_text.strip()
            except:
                continue

        # Fallback: get text after the old text, filtering out known UI elements
        if old_text and new_text.startswith(old_text):
            new_part = new_text[len(old_text):].strip()
            # Filter out UI elements based on skip patterns
            lines = new_part.split('\n')
            filtered_lines = []
            for line in lines:
                line = line.strip()
                if line and len(line) > min_length:
                    # Skip UI elements based on config
                    if not any(skip.lower() in line.lower() for skip in skip_patterns):
                        filtered_lines.append(line)

            if filtered_lines:
                return '\n'.join(filtered_lines)

        return ""

    def clear_history(self):
        """Clear chat history by reloading the page (sync wrapper)"""
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # If loop is running, use thread pool
                import concurrent.futures
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    future = pool.submit(asyncio.run, self.clear_history_async())
                    future.result()
            else:
                # No loop running, run directly
                loop.run_until_complete(self.clear_history_async())
        except RuntimeError:
            # No event loop, create one
            asyncio.run(self.clear_history_async())

    async def clear_history_async(self):
        """Clear chat history by reloading the page (async implementation)"""
        if self._page:
            await self._page.reload(wait_until="domcontentloaded", timeout=self.wait_times["page_load"])
            # Wait a bit for dynamic content to load
            await self._page.wait_for_timeout(2000)

            # Re-open chat if needed
            if chat_button := self.selectors.get("chat_button"):
                try:
                    await self._page.wait_for_selector(chat_button, timeout=5000)
                    await self._page.click(chat_button)
                    await asyncio.sleep(self.wait_times["chat_open"] / 1000)
                except PlaywrightTimeoutError:
                    pass

    def __del__(self):
        """Clean up browser resources"""
        # Cannot use await in __del__, need to handle cleanup carefully
        if self._page or self._browser or self._playwright:
            try:
                # Try to get the running loop
                loop = asyncio.get_event_loop()
                if loop.is_running():
                    # If loop is running, schedule cleanup as a task
                    loop.create_task(self._async_cleanup())
                else:
                    # If no loop running, run cleanup synchronously
                    loop.run_until_complete(self._async_cleanup())
            except RuntimeError:
                # No event loop available, try creating one
                try:
                    asyncio.run(self._async_cleanup())
                except:
                    # Last resort: log the issue
                    logging.warning("Could not properly cleanup WebChatbotGenerator resources")

    async def _async_cleanup(self):
        """Async cleanup helper"""
        try:
            if self._page:
                await self._page.close()
            if self._context:
                await self._context.close()
            if self._browser:
                await self._browser.close()
            if self._playwright:
                await self._playwright.stop()
        except Exception as e:
            logging.warning(f"Error during WebChatbotGenerator cleanup: {e}")

DEFAULT_CLASS = "WebChatbotGenerator"
