# Web-Chat Auth Port (cookies / headers / storageState) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the web-chat target auth feature (optional `auth` block of cookies/headers/storageState) from the closed `scanner` repo to the open-source `ai-scanner`, including a working Chromium `WebChatbotGenerator` so auth applies at scan time.

**Architecture:** Auth lives under a new optional `auth` key inside the already-encrypted `Target#web_config` (ai-scanner shares scanner's `acts_as_tenant` + `Encryption::TenantKeyProvider`, so no encryption work is needed). A new `WebConfig::AuthValidator` shape-checks it; `PlaywrightService` applies it to the Chromium context (cookies via `addCookies`, headers via `extraHTTPHeaders`, storageState via `newContext`); the same `auth` rides through `run_garak_scan.rb`'s existing `--generator_option_file` passthrough to a **newly-vendored** Python `WebChatbotGenerator`. A new `webchat-auth` Stimulus controller drives the UI. Log-scrubbing + credential-file cleanup are hardened to match scanner.

**Tech Stack:** Rails 8, RSpec, Stimulus.js (tested via `node script/tests/javascript_controller_tests.mjs`, vm-based harness — NOT `node --test`), Playwright (**Chromium** via Node + Python `async_playwright`), Python `unittest`, garak 0.14.1 (pip).

**Canonical reference (the merged feature):** every component below exists in `~/Projects/scanner/<path>`. Read those for the exact target behavior; this plan lists the ai-scanner-specific adaptations. **Key divergences from scanner:**
- **Chromium, not Firefox** (ai-scanner Dockerfile installs only chromium). Drop all `firefoxUserPrefs` / `MOZ_DISABLE_CONTENT_SANDBOX`.
- **No SSRF IP-pinning** in ai-scanner's `PlaywrightService` (no `pin_url_to_resolved_ip`, navigates the real hostname). So **do NOT port `pin_auth_to_resolved_origin`** — cookies/storageState scoped to the real host already match the page origin. (This was scanner's P1 fix, unnecessary here.)
- **No garak submodule.** Generators are vendored at `script/garak_plugins/<name>.py` and `COPY`d into garak's site-packages by the Dockerfile (see `openrouter.py`). The `WebChatbotGenerator` does not exist in ai-scanner yet and must be added.
- **JS tests** use `node:assert/strict` + `vm.runInNewContext` (no `node:test`). Port new tests in that style.

**Constraint:** Do NOT push or open PRs. All work stays local (commits only). A maintainer pushes later.

---

## File Structure

**New files:**
| Path | Responsibility |
|---|---|
| `script/garak_plugins/web_chatbot.py` | Chromium `WebChatbotGenerator` with auth (cookies/headers/storageState). Vendored; `COPY`d into garak at build. |
| `app/services/web_config/auth_validator.rb` | Shape-validate the `auth` block. Pure; returns error strings. |
| `app/views/admin/targets/wizard/_step2_auth.html.erb` | Collapsible Authentication section + cookie/header row `<template>`s. |
| `app/javascript/controllers/webchat_auth_controller.js` | Cookie/header rows + storageState → serialize into `web_config.auth`; hydrate on edit; mask/toggle. |
| `script/tests/test_cleanup_scan_files.py` | `_web.json` deleted even in debug mode. |
| `script/tests/test_remove_web_config_file.py` | `remove_web_config_file` helper + signal-handler call. |
| `spec/services/web_config/auth_validator_spec.rb` | Validator unit specs. |

**Modified files:**
| Path | Change |
|---|---|
| `Dockerfile` | `COPY` the new generator into `garak/generators/web_chatbot.py`. |
| `app/models/target.rb` | Wire `AuthValidator` into `web_config_is_valid`; add `strip_reserved_auth_headers` before_validation. |
| `app/services/browser_automation/playwright_service.rb` | `auth_payload`/`normalize_cookie`/`sanitize_headers`/`redact_for_log`; inject auth into `validate_webchat_config` + `extract_page_structure` Chromium heredocs. |
| `app/services/validate_web_chat_target.rb` | Forward `auth`; sanitize `validation_text`. |
| `app/services/auto_detect_webchat_selectors.rb` | `auth:` kwarg; forward; sanitize logs. |
| `app/controllers/admin/targets_controller.rb` | `auto_detect_selectors`: permit/forward/echo `auth`; sanitize backtrace. |
| `app/services/run_garak_scan.rb` | Launch-failure rescue → `remove_web_config_file`. |
| `app/services/reports/failure_classifier.rb` | Extend `SECRET_PATTERNS` (Basic/Digest/NTLM + cookie + x-* headers). |
| `app/services/run_command.rb` | `cookie`/`set_cookie` in `SENSITIVE_OUTPUT_PATTERN` + `COOKIE_OUTPUT_PATTERN`. |
| `config/initializers/filter_parameter_logging.rb` | Add `:auth, :cookies, :storage_state`. |
| `script/db_notifier.py` | Always delete `<uuid>_web.json` (even in debug). |
| `script/run_garak.py` | `remove_web_config_file` helper + call in `signal_handler` and `finally`. |
| `app/javascript/controllers/target_wizard_controller.js` | `redactAuthForReview` + `auth:{}` default + malformed-JSON guard. |
| `app/javascript/controllers/webchat_auto_detect_controller.js` | `currentAuth()` + auth in detect POST. |
| `app/views/admin/targets/wizard/_step2_configure.html.erb` | Render `_step2_auth` inside `webChatFields`. |
| `spec/models/target_spec.rb`, `spec/services/.../*_spec.rb`, `spec/factories/targets.rb`, `script/tests/javascript_controller_tests.mjs` | Test coverage. |
| `docs/` webchat docs | Document the `auth` schema. |

**Test commands (run inside the dev container per ai-scanner CLAUDE.md):**
- RSpec: `docker compose -f docker-compose.dev.yml exec -T scanner bash -lc 'cd /rails && RAILS_ENV=test bundle exec rspec <path>'`
- RuboCop: `... bundle exec rubocop -A <files>`
- Python: `... python3 -m unittest discover -s script/tests` and `python3 -m py_compile script/<f>.py`
- JS (host or container): `npm run test:js`

---

## Phase 0 — Vendored Chromium WebChatbotGenerator

### Task 0.1: Add the Chromium generator (TDD)

**Reference:** `~/Projects/scanner/garak-0din-plugins/garak_experimental/generators/web_chatbot.py` — the full generator WITH auth. Port it, adapting Firefox→Chromium.

**Files:**
- Create: `script/garak_plugins/web_chatbot.py`
- Test: `script/tests/test_web_chatbot_generator.py`

- [ ] **Step 1: Write the failing test** (`script/tests/test_web_chatbot_generator.py`):

```python
"""Unit tests for the vendored Chromium WebChatbotGenerator auth support."""
import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# The generator imports from garak.generators.base and playwright (both present in
# the dev container). Add the vendored plugin dir to the path so we can import it.
_plugins = str(Path(__file__).resolve().parent.parent / "garak_plugins")
if _plugins not in sys.path:
    sys.path.insert(0, _plugins)

from web_chatbot import WebChatbotGenerator  # noqa: E402


class TestWebChatbotAuth(unittest.TestCase):
    def test_build_context_kwargs_maps_auth_and_viewport(self):
        kwargs = WebChatbotGenerator._build_context_kwargs(
            {"headers": {"Authorization": "Bearer x"}, "storage_state": {"cookies": []}},
            {"viewport": {"width": 1280, "height": 720}},
        )
        self.assertEqual(kwargs["extra_http_headers"], {"Authorization": "Bearer x"})
        self.assertEqual(kwargs["storage_state"], {"cookies": []})
        self.assertEqual(kwargs["viewport"], {"width": 1280, "height": 720})

    def test_build_context_kwargs_drops_host_header(self):
        kwargs = WebChatbotGenerator._build_context_kwargs(
            {"headers": {"Host": "evil.com", "X-Api": "ok"}}, {}
        )
        self.assertEqual(kwargs["extra_http_headers"], {"X-Api": "ok"})

    def test_normalize_cookies_defaults_path_and_capitalizes_samesite(self):
        out = WebChatbotGenerator._normalize_cookies(
            [{"name": "s", "value": "v", "domain": "example.com", "sameSite": "lax"}]
        )
        self.assertEqual(out[0]["path"], "/")
        self.assertEqual(out[0]["sameSite"], "Lax")

    def test_init_browser_uses_chromium_and_applies_cookies(self):
        gen = object.__new__(WebChatbotGenerator)
        gen.url = "https://example.com/chat"
        gen.browser_options = {"headless": True, "viewport": {"width": 1280, "height": 720}}
        gen.wait_times = {"page_load": 10000, "chat_open": 5000}
        gen.selectors = {"input_field": "#i", "response_container": "#r"}
        gen.auth = {"cookies": [{"name": "s", "value": "secret", "domain": "example.com"}],
                    "headers": {"Authorization": "Bearer t"}, "storage_state": None}
        gen._playwright = None

        context = AsyncMock()
        context.new_page = AsyncMock(return_value=AsyncMock())
        browser = AsyncMock()
        browser.new_context = AsyncMock(return_value=context)
        chromium = MagicMock()
        chromium.launch = AsyncMock(return_value=browser)
        pw = AsyncMock()
        pw.chromium = chromium

        import web_chatbot as mod
        original = mod.async_playwright
        mod.async_playwright = lambda: MagicMock(start=AsyncMock(return_value=pw))
        try:
            asyncio.run(gen._init_browser())
        finally:
            mod.async_playwright = original

        chromium.launch.assert_awaited_once()         # NOT firefox
        browser.new_context.assert_awaited_once()
        _, ctx_kwargs = browser.new_context.call_args
        self.assertEqual(ctx_kwargs["extra_http_headers"], {"Authorization": "Bearer t"})
        context.add_cookies.assert_awaited_once_with(
            [{"name": "s", "value": "secret", "domain": "example.com"}]
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it FAILS** (module missing):

Run: `cd /Users/olehperevertailo/Projects/ai-scanner && docker compose -f docker-compose.dev.yml exec -T scanner bash -lc 'cd /rails/script && python3 -m unittest tests.test_web_chatbot_generator -v'`
Expected: FAIL — `ModuleNotFoundError: No module named 'web_chatbot'`.

- [ ] **Step 3: Create `script/garak_plugins/web_chatbot.py`** — copy `~/Projects/scanner/garak-0din-plugins/garak_experimental/generators/web_chatbot.py` verbatim, then apply these **Chromium adaptations** in `_init_browser`:

Replace the Firefox launch:
```python
            self._browser = await self._playwright.firefox.launch(
                headless=self.browser_options.get("headless", True),
                env={**os.environ, 'MOZ_DISABLE_CONTENT_SANDBOX': '1'},
                firefox_user_prefs={'security.sandbox.content.level': 0}
            )
```
with Chromium (mirroring ai-scanner's existing PDF/screenshot launch args):
```python
            self._browser = await self._playwright.chromium.launch(
                headless=self.browser_options.get("headless", True),
                args=['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
            )
```
Keep everything else verbatim: `_build_context_kwargs`, `_normalize_cookies`, the `new_context(**...) + add_cookies + new_page()` flow, `self._context` tracking, `_async_cleanup` closing `_context`, `DEFAULT_PARAMS` with the `auth` block, `clear_history_async` (reloads same page → cookies persist). The file must remain self-contained (imports only `garak.generators.base`, `garak.attempt`, `playwright.async_api`, stdlib) — do NOT reference `garak_experimental`.

- [ ] **Step 4: Run the test — expect PASS** (4 tests):

Run: `... bash -lc 'cd /rails/script && python3 -m unittest tests.test_web_chatbot_generator -v'`

- [ ] **Step 5: py_compile the new file:**

Run: `... bash -lc 'cd /rails && python3 -m py_compile script/garak_plugins/web_chatbot.py'` — Expected: no output (success).

- [ ] **Step 6: Commit:**
```bash
cd /Users/olehperevertailo/Projects/ai-scanner
git add script/garak_plugins/web_chatbot.py script/tests/test_web_chatbot_generator.py
git commit -m "feat(webchat): vendor Chromium WebChatbotGenerator with cookies/headers/storageState auth"
```

### Task 0.2: Wire the generator into the Docker image

**Files:** Modify `Dockerfile` (the final-stage `COPY` block, after the `openrouter.py` line ~174).

- [ ] **Step 1: Add the COPY line** immediately after the `openrouter.py` COPY:
```dockerfile
COPY --from=build /rails/script/garak_plugins/web_chatbot.py /opt/venv/lib/python3.13/site-packages/garak/generators/web_chatbot.py
```
(Match the exact `python3.13` path used by the sibling COPYs; if they ever differ, mirror them.)

- [ ] **Step 2: Sanity-check the Dockerfile parses** (no build needed):

Run: `cd /Users/olehperevertailo/Projects/ai-scanner && grep -n "web_chatbot.py" Dockerfile` — Expected: the new COPY line is present alongside `openrouter.py`.

- [ ] **Step 3: Commit:**
```bash
git add Dockerfile
git commit -m "build(webchat): install the WebChatbotGenerator into the garak venv"
```

> **Runtime note (no task):** garak caches plugin names; ai-scanner's image pre-warms via `garak --list_probes` at build, which rebuilds the cache and discovers the new generator. No extra cache step needed.

---

## Phase 1 — Schema validation (Ruby)

### Task 1.1: `WebConfig::AuthValidator` (TDD)

**Reference:** `~/Projects/scanner/app/services/web_config/auth_validator.rb` + `spec/services/web_config/auth_validator_spec.rb` — copy BOTH verbatim (no adaptation needed; pure Ruby).

**Files:**
- Create: `app/services/web_config/auth_validator.rb`
- Test: `spec/services/web_config/auth_validator_spec.rb`

- [ ] **Step 1:** Copy the spec from `~/Projects/scanner/spec/services/web_config/auth_validator_spec.rb` verbatim into `spec/services/web_config/auth_validator_spec.rb`.
- [ ] **Step 2: Run — expect FAIL** (`uninitialized constant WebConfig::AuthValidator`):
`... bundle exec rspec spec/services/web_config/auth_validator_spec.rb`
- [ ] **Step 3:** Copy `~/Projects/scanner/app/services/web_config/auth_validator.rb` verbatim into `app/services/web_config/auth_validator.rb`. (Validates: `auth` is a Hash; only `cookies`/`headers`/`storage_state` keys; each cookie needs `name`+`value` and `url`-or-`domain`; `sameSite` ∈ Strict/Lax/None; boolean `secure`/`httpOnly`; ≤50 cookies; string headers; object `storage_state`.)
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: RuboCop + commit:**
```bash
... bundle exec rubocop -A app/services/web_config/auth_validator.rb spec/services/web_config/auth_validator_spec.rb
git add app/services/web_config/auth_validator.rb spec/services/web_config/auth_validator_spec.rb
git commit -m "feat(webchat-auth): add WebConfig::AuthValidator"
```

### Task 1.2: Wire validator + Host-strip into Target (TDD)

**Reference:** `~/Projects/scanner/app/models/target.rb` — the `web_config_is_valid` auth block, the `before_validation :strip_reserved_auth_headers, if: :webchat?`, and the private `strip_reserved_auth_headers` method (the **guarded** version that handles non-Hash `auth`).

**Files:**
- Modify: `app/models/target.rb` (the `before_validation` block, `web_config_is_valid`, add private method)
- Test: `spec/models/target_spec.rb` (extend the webchat/web_config validation section)

- [ ] **Step 1: Add failing specs** to `spec/models/target_spec.rb`. Add a `context "with auth block"` inside the web_config validation describe. (Port from `~/Projects/scanner/spec/models/target_spec.rb` — the `with auth block` context, including the `webchat_with_auth` helper, the valid/malformed/unsupported-key cases, the "strips a reserved Host header", "drops the auth.headers key when Host was the only header", "does not raise when auth is a non-object", and "does not raise when auth is an array" examples.) Match ai-scanner's existing webchat factory usage (set `model_type: "web_chatbot"` if a webchat build needs it per `target_spec.rb:92`).
- [ ] **Step 2: Run — expect FAIL:**
`... bundle exec rspec spec/models/target_spec.rb -e "with auth block"`
- [ ] **Step 3: Edit `app/models/target.rb`:**
  - (a) In `web_config_is_valid`, after the `response_container` blank check and before the optional-fields comment, add:
    ```ruby
    auth = config["auth"]
    if auth.present?
      WebConfig::AuthValidator.new(auth).errors.each { |msg| errors.add(:web_config, msg) }
    end
    ```
  - (b) After `before_validation :set_defaults_for_webchat`, add:
    ```ruby
    before_validation :strip_reserved_auth_headers, if: :webchat?
    ```
  - (c) Add the private method (copy from scanner — the guarded version):
    ```ruby
    def strip_reserved_auth_headers
      config = parsed_web_config
      auth = config["auth"] if config.is_a?(Hash)
      return unless auth.is_a?(Hash)

      headers = auth["headers"]
      return unless headers.is_a?(Hash)

      reserved = headers.keys.select { |k| k.to_s.casecmp?("host") }
      return if reserved.empty?

      reserved.each { |k| headers.delete(k) }
      auth.delete("headers") if headers.empty?
      self.web_config = config
    end
    ```
- [ ] **Step 4: Run — expect PASS** (new + existing web_config validation):
`... bundle exec rspec spec/models/target_spec.rb`
- [ ] **Step 5: RuboCop + commit:**
```bash
... bundle exec rubocop -A app/models/target.rb spec/models/target_spec.rb
git add app/models/target.rb spec/models/target_spec.rb
git commit -m "feat(webchat-auth): validate auth block and strip reserved Host header on Target"
```

---

## Phase 2 — Playwright auth injection (Chromium, no IP-pin)

### Task 2.1: Carry auth through PlaywrightService (TDD)

**Reference:** `~/Projects/scanner/app/services/browser_automation/playwright_service.rb` — the helpers `auth_payload`, `normalize_cookie`, `sanitize_headers`, `redact_for_log` (copy verbatim) and the auth injection in `validate_webchat_config` + `extract_page_structure`. **DO NOT port** `pin_auth_to_resolved_origin` / `pinned_auth` — ai-scanner has no IP-pinning.

**Files:**
- Modify: `app/services/browser_automation/playwright_service.rb`
- Test: `spec/services/browser_automation/playwright_service_spec.rb`

- [ ] **Step 1: Inspect ai-scanner's two methods first** to see the exact Chromium `newContext` block shape and whether they set `extraHTTPHeaders` today:
`cd /Users/olehperevertailo/Projects/ai-scanner && sed -n '147,200p;336,360p' app/services/browser_automation/playwright_service.rb`
(`validate_webchat_config` ≈ line 147, `extract_page_structure` ≈ line 336.)

- [ ] **Step 2: Add failing specs** to `spec/services/browser_automation/playwright_service_spec.rb`. ai-scanner stubs `Open3.capture3` directly (same as scanner). Inside the `#validate_webchat_config` describe, add (port from scanner's auth specs, but assert the data-file carries auth + the script excludes the literal values + `addCookies` present):

```ruby
    it "passes auth cookies, headers, and storage_state via the JSON data file" do
      script_content = nil
      data_content = nil
      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ { "success" => true, "errors" => [], "response_detected" => true }.to_json, "", double(success?: true) ]
      end
      auth = {
        "cookies" => [ { "name" => "session", "value" => "secret-cookie", "domain" => "example.com" } ],
        "headers" => { "Authorization" => "Bearer secret-token" },
        "storage_state" => { "cookies" => [], "origins" => [] }
      }
      service.validate_webchat_config(url, config.merge(auth: auth))
      expect(data_content.dig("auth", "cookies", 0, "value")).to eq("secret-cookie")
      expect(data_content.dig("auth", "headers", "Authorization")).to eq("Bearer secret-token")
      expect(data_content.dig("auth", "storage_state")).to eq({ "cookies" => [], "origins" => [] })
      expect(script_content).to include("addCookies")
      expect(script_content).not_to include("secret-cookie")
      expect(script_content).not_to include("secret-token")
    end

    it "strips a reserved Host header from auth and drops malformed/nil-value cookies" do
      data_content = nil
      allow(Open3).to receive(:capture3) do |env, _c, _s|
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ { "success" => true, "errors" => [], "response_detected" => true }.to_json, "", double(success?: true) ]
      end
      service.validate_webchat_config(url, config.merge(auth: {
        "headers" => { "Host" => "evil.com", "X-Api" => "ok" },
        "cookies" => [ { "name" => "s", "value" => nil, "domain" => "e.com" }, { "name" => "ok", "value" => "v", "domain" => "e.com" } ]
      }))
      expect(data_content.dig("auth", "headers")).to eq({ "X-Api" => "ok" })
      expect(data_content.dig("auth", "cookies").length).to eq(1)
      expect(data_content.dig("auth", "cookies", 0, "name")).to eq("ok")
    end

    it "ignores a non-hash auth instead of raising" do
      allow(Open3).to receive(:capture3) do |env, _c, _s|
        @d = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ { "success" => true, "errors" => [], "response_detected" => true }.to_json, "", double(success?: true) ]
      end
      expect { service.validate_webchat_config(url, config.merge(auth: "nope")) }.not_to raise_error
      expect(@d["auth"]).to be_nil
    end
```
(If ai-scanner's `#validate_webchat_config` describe lacks a symbol-keyed `config` let, add one mirroring scanner's: `let(:config) { { selectors: { input_field: "#chat-input", send_button: "#send-btn", response_container: ".chat-messages" } } }`.) Add a parallel `extract_page_structure` auth test passing `auth:` via `options`.

- [ ] **Step 3: Run — expect FAIL.**

- [ ] **Step 4: Add the private helpers** to `app/services/browser_automation/playwright_service.rb` (copy verbatim from `~/Projects/scanner/...:auth_payload/normalize_cookie/sanitize_headers/redact_for_log`):
```ruby
    def auth_payload(auth)
      return nil unless auth.is_a?(Hash)
      auth = auth.deep_stringify_keys
      cookies = Array(auth["cookies"]).filter_map { |c| normalize_cookie(c) }
      headers = sanitize_headers(auth["headers"])
      payload = {}
      payload["cookies"] = cookies if cookies.any?
      payload["headers"] = headers if headers.any?
      payload["storage_state"] = auth["storage_state"] if auth["storage_state"].is_a?(Hash)
      payload.presence
    end

    def normalize_cookie(cookie)
      return nil unless cookie.is_a?(Hash)
      c = cookie.deep_stringify_keys.slice("name", "value", "url", "domain", "path", "secure", "httpOnly", "sameSite", "expires")
      return nil unless c["name"].is_a?(String) && !c["name"].strip.empty? && c["value"].is_a?(String)
      c["path"] ||= "/" if c["domain"].present?
      c["sameSite"] = c["sameSite"].to_s.capitalize if c["sameSite"].present?
      c
    end

    def sanitize_headers(headers)
      return {} unless headers.is_a?(Hash)
      headers.deep_stringify_keys.reject { |k, _| k.casecmp?("host") }.transform_values(&:to_s)
    end

    def redact_for_log(text)
      Reports::FailureClassifier.sanitize_text(text.to_s)
    end
```

- [ ] **Step 5: Add `auth: auth_payload(...)` to the two `data` hashes** (NO `pinned_auth` / origin re-scoping):
  - `validate_webchat_config`'s data hash: `auth: auth_payload(config[:auth] || config["auth"])`
  - `extract_page_structure`'s data hash: `auth: auth_payload(options[:auth])`

- [ ] **Step 6: Inject auth into both Chromium `newContext` heredocs.** In each method's JS, after the `const browser = await chromium.launch(...)` and where it builds `const context = await browser.newContext({ ... }); const page = await context.newPage();`, change to (merging into whatever `extraHTTPHeaders` ai-scanner already sets — if none, this introduces it):
```js
            const __auth = __data.auth || {};
            const context = await browser.newContext({
              /* ...keep ai-scanner's existing options (viewport, ignoreHTTPSErrors, userAgent for extract) ... */
              ...(__auth.storage_state ? { storageState: __auth.storage_state } : {}),
              extraHTTPHeaders: Object.assign({}, __auth.headers || {} /* , <any existing extraHTTPHeaders ai-scanner sets> */ )
            });
            if (Array.isArray(__auth.cookies) && __auth.cookies.length) {
              await context.addCookies(__auth.cookies);
            }
            const page = await context.newPage();
```
Preserve any existing `newContext` options ai-scanner has (viewport, `ignoreHTTPSErrors`, the `userAgent: __data.user_agent` in `extract_page_structure`). If ai-scanner already passes `extraHTTPHeaders`, merge `__auth.headers` as the FIRST arg of `Object.assign` so the existing values win.

- [ ] **Step 7: Wire `redact_for_log`** into `execute_playwright_script`'s error-logging branches (copy scanner's wrapping of `output`/`error` in `redact_for_log(...)` at the no-JSON-found and non-zero-exit fallbacks). Add a spec:
```ruby
    it "redacts secrets from logged playwright output on failure" do
      allow(Open3).to receive(:capture3).and_return([ "", "boom Authorization: Bearer abcdef123456", double(success?: false) ])
      allow(Rails.logger).to receive(:error)
      result = service.send(:execute_playwright_script, "console.log(1)")
      expect(result["error"]).not_to include("abcdef123456")
    end
```

- [ ] **Step 8: Run the full PlaywrightService spec — expect PASS** (new auth specs + existing chromium/host specs unaffected):
`... bundle exec rspec spec/services/browser_automation/playwright_service_spec.rb`

- [ ] **Step 9: RuboCop + commit:**
```bash
... bundle exec rubocop -A app/services/browser_automation/playwright_service.rb spec/services/browser_automation/playwright_service_spec.rb
git add app/services/browser_automation/playwright_service.rb spec/services/browser_automation/playwright_service_spec.rb
git commit -m "feat(webchat-auth): apply cookies/headers/storageState in PlaywrightService (Chromium)"
```

---

## Phase 3 — Thread auth through callers (Ruby)

### Task 3.1: ValidateWebChatTarget forwards auth + sanitizes (TDD)

**Reference:** `~/Projects/scanner/app/services/validate_web_chat_target.rb` (+ its spec). Near-identical to ai-scanner — clean port.

**Files:** Modify `app/services/validate_web_chat_target.rb`; Test `spec/services/validate_web_chat_target_spec.rb`.

- [ ] **Step 1: Add failing specs** (port scanner's `with an auth block` context: "forwards auth to validate_webchat_config" + "sanitizes secrets out of validation_text on failure").
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Edit the service:** (a) `auth = config["auth"]` in `validate_web_chat`; (b) `perform_interaction_test(url, selectors, auth)`; (c) signature `perform_interaction_test(url, selectors, auth = nil)` and add `auth: auth` to the config hash passed to `validate_webchat_config`; (d) add private `sanitize(text) = Reports::FailureClassifier.sanitize_text(text)`; (e) wrap the three dynamic `validation_text` strings (failure branch, the inner rescue, the outer rescue) with `sanitize(...)`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: RuboCop + commit** (`feat(webchat-auth): forward auth in validation and scrub validation_text`).

### Task 3.2: AutoDetectWebchatSelectors auth kwarg + sanitized logs (TDD)

**Reference:** `~/Projects/scanner/app/services/auto_detect_webchat_selectors.rb` (+ spec). Clean port.

**Files:** Modify `app/services/auto_detect_webchat_selectors.rb`; Test `spec/services/auto_detect_webchat_selectors_spec.rb`.

- [ ] **Step 1: Add failing specs** (port "forwards auth to extract_page_structure and validate_webchat_config" + "sanitizes secrets from auto-detect failure logs").
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Edit:** `initialize(url, session_id: nil, auth: nil)` storing `@auth`; pass `auth: @auth` to `extract_page_structure` and into the `validate_detected_selectors` config; add private `sanitize(text) = Reports::FailureClassifier.sanitize_text(text.to_s)`; wrap the four dynamic log sites (invalid-result error, the `validation[:errors]` warn, the rescue `e.message` and `e.backtrace.join("\n")`) with `sanitize(...)`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: RuboCop + commit** (`feat(webchat-auth): forward auth through selector auto-detection and scrub its logs`).

### Task 3.3: Controller permits + echoes auth (TDD)

**Reference:** `~/Projects/scanner/app/controllers/admin/targets_controller.rb#auto_detect_selectors` (+ the controller spec example). **Only** port the `auto_detect_selectors` changes — IGNORE scanner's `rollout_preview_request?` branches (not part of this feature, absent in ai-scanner).

**Files:** Modify `app/controllers/admin/targets_controller.rb`; Test `spec/controllers/admin/targets_controller_spec.rb` (or `spec/requests/...` — use whichever ai-scanner already uses for `auto_detect_selectors`).

- [ ] **Step 1: Add a failing spec** ("forwards auth to the service and echoes it into the returned config") matching ai-scanner's existing auto_detect test setup (signed `session_id`, tenant/user before block).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Edit `auto_detect_selectors`:** after the session/SSRF guards and before constructing the detector, add `auth = params[:auth].respond_to?(:to_unsafe_h) ? params[:auth].to_unsafe_h : params[:auth]`; pass `auth: auth` to `AutoDetectWebchatSelectors.new`; in the success branch add `config[:auth] = auth if auth.present?` before the `render json`; in the rescue, wrap `e.message` AND `e.backtrace.join("\n")` with `Reports::FailureClassifier.sanitize_text(...)`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: RuboCop + commit** (`feat(webchat-auth): pass auth through the auto-detect endpoint`).

---

## Phase 4 — Log scrubbing & credential-file cleanup

### Task 4.1: Extend secret patterns + filter params (TDD)

**Reference:** scanner's `failure_classifier.rb` `SECRET_PATTERNS` (6 entries), `run_command.rb` (`COOKIE_OUTPUT_PATTERN` + `cookie|set_cookie`), `filter_parameter_logging.rb` (+3 keys).

**Files:** Modify `app/services/reports/failure_classifier.rb`, `app/services/run_command.rb`, `config/initializers/filter_parameter_logging.rb`; Tests append INSIDE the existing `spec/services/reports/failure_classifier_spec.rb` and `spec/services/run_command_spec.rb` top-level describes (do not open new ones).

- [ ] **Step 1: Add failing specs:**
  - FailureClassifier (inside the existing describe): `expect(described_class.sanitize_text("Cookie: session=abc123; theme=dark")).not_to include("session=abc123")`, `... "Authorization: Basic dXNlcjpwYXNz" ...).not_to include("dXNlcjpwYXNz")`, `... "X-Api-Token: super-secret-value" ...).not_to include("super-secret-value")`.
  - RunCommand: `cmd = described_class.new(["echo"]); out = cmd.send(:sanitize_output, "Cookie: a=secret1; b=secret2", truncate: false); expect(out).not_to include("secret1"); expect(out).not_to include("secret2")`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Edit:**
  - `failure_classifier.rb` `SECRET_PATTERNS`: add (in order) the Basic/Digest/NTLM scheme entry `[ /((?:Basic|Digest|NTLM|Negotiate)\s+)[A-Za-z0-9._~+\-\/=]+/i, '\1[REDACTED]' ]` (as the 2nd entry, after Bearer), the cookie-line entry `[ /((?:set-)?cookie\s*:\s*)[^\n]+/i, '\1[REDACTED]' ]`, and the x-* header entry `[ /(x-[\w-]*(?:key|token|auth|secret|cookie)[\w-]*\s*[=:]\s*)["']?[^"'\s,}]+/i, '\1[REDACTED]' ]`. (Copy the full 6-entry array from scanner to be safe.)
  - `run_command.rb`: add `cookie|set[_-]?cookie` to `SENSITIVE_OUTPUT_PATTERN`'s alternation; add `COOKIE_OUTPUT_PATTERN = /((?:set-)?cookie["']?\s*[=:]\s*).*/i`; chain `.gsub(COOKIE_OUTPUT_PATTERN, "\\1#{REDACTED}")` in `sanitize_output`.
  - `filter_parameter_logging.rb`: append `:auth, :cookies, :storage_state`.
- [ ] **Step 4: Run — expect PASS** (and `... rails runner "puts Rails.application.config.filter_parameters.include?(:auth)"` prints `true`).
- [ ] **Step 5: RuboCop + commit** (`feat(webchat-auth): redact cookies/Basic-auth in logs and filter auth params`).

### Task 4.2: RunGarakScan launch-failure cleanup (TDD)

**Reference:** scanner's `run_garak_scan.rb` `remove_web_config_file` + the `rescue StandardError → remove_web_config_file; raise`. **Adapt placement** to ai-scanner's `call` structure (it has `execute_scan`/`with_report_tenant`, no `AbortScan`). The rescue must wrap the top-level `call` body and re-raise.

**Files:** Modify `app/services/run_garak_scan.rb`; Test `spec/services/run_garak_scan_spec.rb` (webchat section; remember the global `RunGarakScan#call` stub → use `and_call_original`).

- [ ] **Step 1: Read ai-scanner's `call`/`execute_scan`** to choose the rescue site:
`cd /Users/olehperevertailo/Projects/ai-scanner && sed -n '19,100p' app/services/run_garak_scan.rb`
- [ ] **Step 2: Add a failing spec** (port scanner's "removes the web config file if the scan process fails to launch": stub `service.call` `and_call_original`, stub `target.status`/`all_probes_completed?`/`build_argv`/`build_env`/`log_file`(or ai-scanner's `scan_log_path`)/`MonitoringService.active?`, write `<uuid>_web.json`, make `RunCommand#call_async` raise, expect raise + file deleted). Adjust the stubbed method names to ai-scanner's (`scan_log_path`, `with_report_tenant`, `execute_scan` as needed).
- [ ] **Step 3: Run — expect FAIL.**
- [ ] **Step 4: Edit `app/services/run_garak_scan.rb`:** add a `rescue StandardError` to the top-level `call` that calls `remove_web_config_file` then `raise`; add the private method:
```ruby
    def remove_web_config_file
      path = CONFIG_PATH.join("#{report.uuid}_web.json")
      File.delete(path) if File.exist?(path)
    rescue StandardError => e
      Rails.logger.warn("[RunGarakScan] failed to remove web config file for #{report.uuid}: #{e.message}")
    end
```
(Use ai-scanner's actual `CONFIG_PATH` constant / `report.uuid` accessor. If ai-scanner already rescues `ImmediateExitError` inside `execute_scan`, ensure the new top-level rescue still runs — place cleanup so it fires for both spawn failures and immediate exits.)
- [ ] **Step 5: Run — expect PASS.**
- [ ] **Step 6: RuboCop + commit** (`feat(webchat-auth): remove credential file on scan launch failure`).

### Task 4.3: Python cleanup — db_notifier + run_garak (TDD)

**Reference:** scanner's `db_notifier.py` (`_web.json` outside the debug branch) + `run_garak.py` (`remove_web_config_file` helper, called in `signal_handler` + `finally`). + scanner's `test_cleanup_scan_files.py`, `test_remove_web_config_file.py`.

**Files:** Modify `script/db_notifier.py`, `script/run_garak.py`; Create `script/tests/test_cleanup_scan_files.py`, `script/tests/test_remove_web_config_file.py`.

- [ ] **Step 1: Create the two failing tests** — copy scanner's `script/tests/test_cleanup_scan_files.py` and `test_remove_web_config_file.py` verbatim. Adjust the import shims to ai-scanner's established pattern (it stubs `psycopg2` + `db_notifier` as ModuleType before importing `run_garak` — see `test_run_garak_signal_handler.py`). The signal-handler test patches `run_garak._main_pid`, `current_report_uuid`, `notify_report_stopped`, `remove_web_config_file` and asserts the latter is called.
- [ ] **Step 2: Run — expect FAIL:**
`... bash -lc 'cd /rails && python3 -m unittest discover -s script/tests -p "test_cleanup_scan_files.py" -p "test_remove_web_config_file.py"'`
- [ ] **Step 3: Edit `script/db_notifier.py#cleanup_scan_files`:** remove `<uuid>_web.json` from the debug-preservable `config_files` list and `files_to_delete.append(CONFIG_PATH / f"{report_uuid}_web.json")` unconditionally (before the `if debug_mode`). Update the docstring.
- [ ] **Step 4: Edit `script/run_garak.py`:** add `CONFIG_PATH` to the `from db_notifier import (...)` list; add the helper:
```python
def remove_web_config_file(report_uuid):
    """Delete the credential-bearing web config file (cookies/headers/storageState)."""
    try:
        (CONFIG_PATH / f"{report_uuid}_web.json").unlink(missing_ok=True)
    except Exception as e:
        logger.error(f"SECURITY: failed to delete credential web config file for {report_uuid}: {e}")
```
Call `remove_web_config_file(current_report_uuid)` in `signal_handler` (after `notify_report_stopped`, inside the `my_pid == _main_pid` branch) and `remove_web_config_file(report_uuid)` in `main()`'s `finally` (after `notify_report_stopped`).
- [ ] **Step 5: Run — expect PASS;** then full Python suite + py_compile:
`... bash -lc 'cd /rails && python3 -m unittest discover -s script/tests && python3 -m py_compile script/db_notifier.py script/run_garak.py'`
- [ ] **Step 6: Commit** (`feat(webchat-auth): always delete credential file + clean it on SIGTERM/finally`).

---

## Phase 5 — Wizard UI

### Task 5.1: `webchat-auth` Stimulus controller (TDD, vm harness)

**Reference:** `~/Projects/scanner/app/javascript/controllers/webchat_auth_controller.js` (copy verbatim — the latest version with `populateFromAuth`, `data-cookie-extra` stash in read/populate, empty-string cookie values kept, raw-storageState-on-invalid). Tests: scanner's tests at `~/Projects/scanner/script/tests/javascript_controller_tests.mjs` (the webchat-auth blocks) — but **rewrite in ai-scanner's vm/bare-assert style** (no `node:test`).

**Files:** Create `app/javascript/controllers/webchat_auth_controller.js`; Modify `script/tests/javascript_controller_tests.mjs`.

- [ ] **Step 1: Inspect ai-scanner's test harness** to copy its exact pattern (`loadControllerSource(filename, className)` + `vm.runInNewContext`, and how existing controllers instantiate + assert):
`cd /Users/olehperevertailo/Projects/ai-scanner && sed -n '1,60p' script/tests/javascript_controller_tests.mjs`
- [ ] **Step 2: Write failing tests** in ai-scanner's style at the end of `script/tests/javascript_controller_tests.mjs`. Port these behaviors from scanner (each as a bare `assert` block using ai-scanner's `loadControllerSource("webchat_auth_controller.js", "...")` loader): `buildAuthPayload` builds cookies/headers/storage_state; returns null for empty; keeps empty-string cookie value; keeps invalid storageState as raw text; `mergeAuthIntoConfig` sets/deletes auth; `readCookieRows` preserves `data-cookie-extra` advanced fields and prefers typed domain over stashed url; `populateFromAuth` hydrates rows + stashes extras; `serialize` writes auth into the textarea; `toggleVisibility` flips input type. (Since the harness has no `test()` wrapper, group each behavior under a `console.log`-style label or sequential asserts, matching how ai-scanner's existing controllers are tested.)
- [ ] **Step 3: Run — expect FAIL** (`Cannot find module .../webchat_auth_controller.js` or load error):
`cd /Users/olehperevertailo/Projects/ai-scanner && npm run test:js`
- [ ] **Step 4: Create `app/javascript/controllers/webchat_auth_controller.js`** — copy verbatim from `~/Projects/scanner/app/javascript/controllers/webchat_auth_controller.js`.
- [ ] **Step 5: Run — expect PASS** (all existing + new):
`npm run test:js`
- [ ] **Step 6: Commit** (`feat(webchat-auth): add webchat-auth Stimulus controller`).

### Task 5.2: Authentication wizard partial + wiring

**Reference:** `~/Projects/scanner/app/views/admin/targets/wizard/_step2_auth.html.erb` (verbatim) + the render line + `initializeWebConfig` `auth:{}` + `redactAuthForReview`.

**Files:** Create `app/views/admin/targets/wizard/_step2_auth.html.erb`; Modify `app/javascript/controllers/target_wizard_controller.js`, `app/views/admin/targets/wizard/_step2_configure.html.erb`; Test `script/tests/javascript_controller_tests.mjs`.

- [ ] **Step 1:** Copy `_step2_auth.html.erb` verbatim from scanner (uses `data-controller="toggle webchat-auth"`, masked value inputs, row templates; CSS tokens `input-base`/`btn-base`/`icon-lock`/`icon-plus`/`icon-trash` all already exist in ai-scanner).
- [ ] **Step 2:** In `app/views/admin/targets/wizard/_step2_configure.html.erb`, insert `<%= render "admin/targets/wizard/step2_auth" %>` inside the `data-target-wizard-target="webChatFields"` div, immediately before that div's closing `</div>` (after the web_config textarea block). Verify it's inside `webChatFields` (so it hides until webchat mode).
- [ ] **Step 3:** In `app/javascript/controllers/target_wizard_controller.js`: (a) add `auth: {}` to `initializeWebConfig`'s `defaultConfig`; (b) add the `redactAuthForReview(config)` method (copy from scanner); (c) in the review population, wrap the parsed config with `this.redactAuthForReview(...)` before `JSON.stringify`, and change the malformed-JSON catch to set `"(configuration contains invalid JSON)"` instead of dumping the raw config.
- [ ] **Step 4: Add a failing→passing JS test** (ai-scanner vm style) for `redactAuthForReview` (cookies→`N cookie(s) [hidden]`, headers→`M header(s) [hidden]`, storage_state→`[hidden]`, no secret substrings; config without auth unchanged). Run `npm run test:js` — expect PASS.
- [ ] **Step 5: Manual smoke** (dev container): open the new-target wizard, pick the Webchat provider, expand Authentication, add a cookie + header + storageState, confirm the hidden `web_config` JSON gains a matching `auth` block and step-3 review shows it redacted.
- [ ] **Step 6: Commit** (`feat(webchat-auth): add Authentication wizard section + redact auth in review`).

### Task 5.3: Auto-detect sends current auth (TDD)

**Reference:** `~/Projects/scanner/app/javascript/controllers/webchat_auto_detect_controller.js` — `currentAuth()` + auth in the Phase-3 fetch body.

**Files:** Modify `app/javascript/controllers/webchat_auto_detect_controller.js`; Test `script/tests/javascript_controller_tests.mjs`.

- [ ] **Step 1: Write failing tests** (vm style): `currentAuth()` returns `config.auth` from the textarea, or `null` when absent/invalid.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Edit:** add `currentAuth()` (parse the web_config textarea, return `config.auth || null`, catch → null); in `detect()`'s Phase-3 fetch body add `auth: this.currentAuth()`. Do NOT touch the Phase-1 (session-id) fetch. Do NOT re-introduce console.logs ai-scanner removed.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** (`feat(webchat-auth): send and preserve auth across selector auto-detect`).

---

## Phase 6 — Documentation

### Task 6.1: Document the auth schema

**Reference:** `~/Projects/scanner/docs/webchat-targets.md`.

**Files:** Create/extend ai-scanner's webchat docs (find via `grep -rl "web_config\|webchat" docs/`; if none, create `docs/webchat-targets.md`).

- [ ] **Step 1:** Document the `auth` block (cookies/headers/storage_state) with the JSON schema + field rules (name+value, url-or-domain, sameSite enum, 50-cookie cap, Host stripped), the encrypted-at-rest + log-scrubbed + credential-file-deleted guarantees, paste-only storageState, and that auth flows through validation/auto-detect/scan. Note the v1 trade-off that auth is visible in the editable `web_config` JSON (masked structured inputs + redacted review).
- [ ] **Step 2: Commit** (`docs(webchat-auth): document cookies/headers/storageState auth`).

---

## Final verification

- [ ] **Run all suites** (dev container):
```bash
docker compose -f docker-compose.dev.yml exec -T scanner bash -lc 'cd /rails && RAILS_ENV=test bundle exec rspec && python3 -m unittest discover -s script/tests && python3 -m py_compile script/db_notifier.py script/run_garak.py script/garak_plugins/web_chatbot.py'
npm run test:js
docker compose -f docker-compose.dev.yml exec -T scanner bash -lc 'cd /rails && bundle exec rubocop && bundle exec brakeman -q --no-pager'
```
Expected: all green; Brakeman 0 warnings.

- [ ] **Build verification (optional but recommended):** build the Docker image and confirm garak discovers the generator: `garak --list_generators 2>/dev/null | grep web_chatbot` shows `web_chatbot.WebChatbotGenerator`. This is the only check that the Chromium generator actually loads at scan time.

- [ ] **Manual integration pass:** configure a webchat target with a dummy cookie + bearer header against the mock-LLM (or a test page); run validate → auto-detect → a small scan; confirm auth flows through and never appears in `report.logs` / `validation_text`.

- [ ] **STOP — do not push.** Report the local commits; a maintainer opens the PR.

---

## Self-Review notes (author)

- **Scope coverage:** generator (0.1) + Dockerfile (0.2); validator + model (1.x); Playwright auth — Chromium, no IP-pin (2.1); callers (3.x); log-scrubbing + cleanup all paths (4.x); UI incl. redaction (5.x); docs (6.1). All shipped components mapped.
- **Deliberate omissions (vs scanner):** `pin_auth_to_resolved_origin`/`pinned_auth` (ai-scanner has no IP-pinning → cookies match the real host directly); Firefox prefs/`MOZ_DISABLE_CONTENT_SANDBOX` (Chromium); `rollout_preview_request?` controller branches (unrelated feature); `GarakConfigHelpers`/`AbortScan`/custom-probe machinery in run_garak_scan (not part of this feature).
- **Harness adaptations:** JS tests in ai-scanner's vm/bare-assert style (not `node:test`); Python generator test under `script/tests` unittest (no garak submodule/pytest).
- **No placeholders:** new files copy a named scanner source; modified files list the exact changes + code. The scanner repo is the canonical reference for any verbatim copy.

## Open questions

None blocking. One verification-time check: confirm the Dockerfile `python3.13` site-packages path still matches the venv's Python at build (it governs all plugin COPYs).
