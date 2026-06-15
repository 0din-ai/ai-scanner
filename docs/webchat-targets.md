# Web-Chat Targets

Web-chat targets let you run security scans against chatbot interfaces embedded in web pages. Instead of hitting a REST or OpenRouter API endpoint, the scanner drives a real browser (Playwright/Chromium) to interact with the chat UI — filling the input field, clicking send, and reading the response.

## Configuration (`web_config`)

A web-chat target stores its browser automation parameters as JSON in the encrypted `web_config` field. The full schema is:

```json
{
  "url": "https://example.com/chat",
  "selectors": {
    "input_field": "textarea#chat-input",
    "response_container": "div.chat-response",
    "send_button": "button[type='submit']"
  },
  "wait_times": {
    "page_load": 30000,
    "response": 5000
  },
  "auth": { }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `url` | Yes | Full URL of the chat page |
| `selectors.input_field` | Yes | CSS selector for the chat input element |
| `selectors.response_container` | Yes | CSS selector for the response area |
| `selectors.send_button` | No | CSS selector for the send button (optional if Enter key submits) |
| `wait_times.page_load` | No | Milliseconds to wait for initial page load (default: 30000) |
| `wait_times.response` | No | Milliseconds to wait for a chat response (default: 5000) |
| `auth` | No | Authentication credentials — see below |

### Auto-Detect Selectors

The target creation wizard includes an **Auto-Detect Selectors** button. Clicking it opens a live browser session to the configured URL and attempts to locate the input field, response container, and send button automatically. Any configured `auth` credentials are applied during auto-detect, so login-gated pages can be configured at creation time.

---

## Authentication (optional)

The optional `auth` block inside `web_config` lets you attach session credentials to every browser context the scanner opens. This covers three complementary mechanisms — use any combination:

```json
"auth": {
  "cookies": [
    {
      "name": "session",
      "value": "abc123...",
      "domain": "example.com",
      "path": "/",
      "secure": true,
      "httpOnly": true,
      "sameSite": "Lax"
    }
  ],
  "headers": {
    "Authorization": "Bearer eyJ..."
  },
  "storage_state": {
    "cookies": [],
    "origins": []
  }
}
```

All three sub-keys (`cookies`, `headers`, `storage_state`) are optional. An absent or empty `auth` block behaves exactly as before this feature was added.

### Cookies (`auth.cookies`)

An array of Playwright cookie objects injected via `context.addCookies()` before the page loads.

| Cookie field | Required | Notes |
|---|---|---|
| `name` | Yes | Cookie name (non-blank string) |
| `value` | Yes | Cookie value (string) |
| `domain` | Conditional | Required unless `url` is provided |
| `url` | Conditional | Required unless `domain` is provided (Playwright `addCookies` rule) |
| `path` | No | Defaults to `"/"` when `domain` is set and `path` is omitted |
| `secure` | No | Boolean |
| `httpOnly` | No | Boolean |
| `sameSite` | No | One of `Strict`, `Lax`, or `None` |

Each cookie must provide either `domain` or `url` — not necessarily both. A maximum of **50 cookies** may be supplied.

### Headers (`auth.headers`)

A flat string-to-string map of HTTP headers added to every request in the browser context via `extraHTTPHeaders`.

```json
"headers": {
  "Authorization": "Bearer eyJ...",
  "X-Custom-Token": "..."
}
```

> **Note:** A user-supplied `Host` header is silently ignored. `Host` is a reserved header — it is stripped from `auth.headers` both when the target is saved and again before the browser context is built — so any `Host` value you provide has no effect.

### Playwright `storage_state` (`auth.storage_state`)

A Playwright [`storageState`](https://playwright.dev/docs/api/class-browsercontext#browser-context-storage-state) object (cookies + `localStorage`/`sessionStorage` origins) passed directly to `browser.newContext({ storageState: ... })`.

```json
"storage_state": {
  "cookies": [ ... ],
  "origins": [
    {
      "origin": "https://example.com",
      "localStorage": [ { "name": "token", "value": "..." } ]
    }
  ]
}
```

The wizard accepts this as a **paste-only** JSON textarea in v1. To generate a `storageState`, authenticate manually in a browser and export the state with Playwright's `browserContext.storageState()` API or via the Playwright Inspector/codegen tool.

A login-recorder flow (capturing credentials automatically) and cookie near-expiry warnings are planned for a future release.

### Auth coverage

Credentials configured in `auth` are applied consistently across all browser paths:

| Path | Auth applied |
|---|---|
| Target validation (`ValidateWebChatTarget`) | Yes |
| Selector auto-detect (`AutoDetectWebchatSelectors`) | Yes |
| Scan run (`WebChatbotGenerator`) | Yes |
| PDF generation / screenshot utilities | No (those paths use internal URLs and have no web-chat target) |

---

## Security

### Encryption at rest

The entire `web_config` field — including the `auth` block — is **encrypted at rest** using Rails ActiveRecord Encryption with per-tenant key isolation (`Encryption::TenantKeyProvider`). Auth credentials are never stored in plaintext in the database.

### Log scrubbing

Auth values are protected from appearing in logs by multiple layers:

- Auth is passed to the browser exclusively through a temporary data file, never string-interpolated into the Playwright script. This means cookie values and tokens never appear in the logged script text.
- Playwright stdout/stderr captured during scans is redacted before logging.
- The `validation_text` stored on the target and rendered in the UI is sanitized before persistence so auth values cannot surface there.
- Rails `filter_parameter_logging` filters the `auth`, `cookies`, and `storage_state` request parameters from Rails logs.
- The scanner's failure classifier and subprocess output filter patterns cover cookie strings, `storageState` blobs, and arbitrary auth-header values.

### Credential file cleanup

During a scan, the scanner writes a temporary generator config file (`storage/config/<uuid>_web.json`) that contains the full `web_config`, including `auth`. This file is **unconditionally deleted** after every scan run — including debug-mode runs and on early termination (SIGTERM) — so credentials do not persist on disk between scans.

---

## Browser engine note

ai-scanner drives **Chromium** via Playwright (launched with `--no-sandbox` in the container). The `auth` schema and Playwright APIs (`addCookies`, `extraHTTPHeaders`, `storageState`) are engine-agnostic, so the configuration above applies unchanged regardless of the underlying browser.
