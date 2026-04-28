---
sidebar_position: 6
---

# Environment Variables

Scanner uses environment variables for two purposes:

1. **System configuration** — set in your `.env` file (read by Docker Compose)
2. **AI provider API keys** — managed via the Scanner UI and stored encrypted per-target

## System Configuration

Set these in your root `.env` file before starting Scanner.

### Required

| Variable | Description |
|---|---|
| `SECRET_KEY_BASE` | Secret key for sessions and encryption. Generate with `openssl rand -hex 64`. |
| `POSTGRES_PASSWORD` | PostgreSQL database password. |

### Network & Port

| Variable | Default | Description |
|---|---|---|
| `PORT` | `80` | Host port Scanner is accessible on. Change if port 80 is unavailable. |
| `ASSUME_SSL` | `false` | Set to `true` when running behind a TLS-terminating proxy. |
| `SESSION_COOKIE_DOMAIN` | — | Required when `ACTION_CABLE_URL` uses a different subdomain (e.g., `.scanner.example.com`). |
| `ACTION_CABLE_URL` | — | WebSocket URL when WebSockets are on a different host (e.g., `wss://ws.scanner.example.com/cable`). |

### Database

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_USER` | `scanner` | Database username. |
| `POSTGRES_HOST` | `postgres` | Hostname (only needed for external PostgreSQL). |
| `POSTGRES_PORT` | `5432` | Port number. |
| `DATABASE_URL` | — | Full PostgreSQL URL. Overrides individual `POSTGRES_*` vars. |

See [Database Configuration](../deployment/database) for `DATABASE_URL` format and managed PostgreSQL setup.

### Scanning Behavior

| Variable | Default | Description |
|---|---|---|
| `EVALUATION_THRESHOLD` | `0.2` | Controls vulnerability detection strictness. Lower = stricter. |
| `RETENTION_DAYS` | `90` | Days to keep reports before automatic deletion. |
| `DEBUG_LOG_TAIL_BYTES` | `131072` | Maximum bytes synced into live report execution-log tails. Set to `0` to disable live-tail reads. Blank, non-integer, or negative values fall back to the default. This is read by the Python runner at startup, applies globally, and requires restarting Scanner after changes. |

### Logging

| Variable | Default | Description |
|---|---|---|
| `RAILS_LOG_LEVEL` | `info` | Log verbosity: `debug`, `info`, `warn`, `error`. |

### Admin Seed Account

| Variable | Default | Description |
|---|---|---|
| `ADMIN_EMAIL` | `admin@example.com` | Initial admin email (used only on first boot). |
| `ADMIN_INITIAL_PASSWORD` | `password` | Initial admin password (used only on first boot). |

---

## AI Provider API Keys (via UI)

API keys for AI providers are configured through the Scanner UI, not in `.env`. This keeps secrets scoped per-tenant and encrypted at rest.

### How to Configure API Keys

1. Log in to Scanner
2. Navigate to **Configuration → Environment Variables**
3. Click **New Environment Variable**
4. Set:
   - **Target** — leave blank for global, or select a specific target
   - **Name** — the variable name (see table below)
   - **Value** — your API key

### Supported API Key Variables

#### OpenAI
- `OPENAI_API_KEY` — Your OpenAI API key (`sk-...`)
  - Get it: [platform.openai.com/account/api-keys](https://platform.openai.com/account/api-keys)

#### OpenRouter
- `OPENROUTER_API_KEY`
  - Get it: [openrouter.ai/keys](https://openrouter.ai/keys)

#### Azure OpenAI
- `AZURE_API_KEY`
- `AZURE_ENDPOINT` — Your Azure resource endpoint URL
- `AZURE_MODEL_NAME` — Deployment name

#### Anthropic
- `ANTHROPIC_API_KEY`
  - Get it: [console.anthropic.com/account/keys](https://console.anthropic.com/account/keys)

#### Groq
- `GROQ_API_KEY`
  - Get it: [console.groq.com/keys](https://console.groq.com/keys)

#### Replicate
- `REPLICATE_API_TOKEN` (`r8-...`)
  - Get it: [replicate.com/account/api-tokens](https://replicate.com/account/api-tokens)

#### Hugging Face
- `HF_TOKEN`
  - Get it: [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

#### Cohere
- `COHERE_API_KEY`
  - Get it: [dashboard.cohere.ai/api-keys](https://dashboard.cohere.ai/api-keys)

### Global vs. Target-Specific Variables

**Global variables** (no target selected) apply to all scans. **Target-specific variables** override globals for that target only.

Use target-specific keys to:
- Use different credentials for production vs. test targets
- Limit credential exposure if a key is compromised
- Test the same model with different API plans

**Priority:** target-specific → global (target-specific always wins)

### Evaluation Threshold Tuning

| Environment | Recommended `EVALUATION_THRESHOLD` |
|---|---|
| Production (strict) | `0.1` – `0.15` |
| Development / testing | `0.2` – `0.3` |
| Initial exploration | `0.3` – `0.5` |
