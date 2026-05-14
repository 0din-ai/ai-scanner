---
sidebar_position: 1
---

# Quick Start

Get Scanner running with Docker in under 5 minutes.

## Prerequisites

- **Git** (for Option B)
- **Docker** and **Docker Compose** v2 (`docker compose`, not `docker-compose`)
- **2 GiB RAM** and **10 GiB disk** available

## Option A: Pre-built Image (Recommended)

The fastest way to get started — no source code required.

```bash
# Download the production compose file and environment template
curl -O https://raw.githubusercontent.com/0din-ai/ai-scanner/main/dist/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/0din-ai/ai-scanner/main/.env.example
```

Open `.env` in your editor and set three required values:

```bash
# Generate a secret key — run this and copy the output:
openssl rand -hex 64
```

```bash title=".env"
SECRET_KEY_BASE=<paste your generated key here>
POSTGRES_PASSWORD=choose_a_strong_password
ADMIN_INITIAL_PASSWORD=<paste a generated admin password here>
```

:::warning Don't skip SECRET_KEY_BASE
`SECRET_KEY_BASE` is required for startup. The app will fail with `key must be 16 bytes` or `Missing active_record_encryption keys` if it is missing or set to the placeholder value.
:::

Then start Scanner:

```bash
docker compose up -d
```

## Option B: Build from Source

```bash
git clone https://github.com/0din-ai/ai-scanner.git
cd ai-scanner
cp .env.example .env
```

Edit `.env` as above (set `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, and `ADMIN_INITIAL_PASSWORD`), then:

```bash
docker compose build scanner
docker compose up -d
```

## Choosing a Port

By default Scanner listens on **port 80**. If port 80 is unavailable on your machine (common on developer workstations due to firewall rules or other services), update `PORT` in your `.env`:

```bash title=".env"
PORT=8080
```

Then access Scanner at `http://localhost:8080`.

## Verifying Startup

Watch the logs until the app is ready:

```bash
docker compose logs -f scanner
```

You should see output like:

```
scanner  | Extracting community probes from garak...
scanner  | Extracted 179 community probes to /rails/config/probes/community_probes.json
scanner  | => Booting Puma
scanner  | => Rails 8.x application starting in production
scanner  | * Listening on http://0.0.0.0:80
scanner  | Use Ctrl-C to stop
```

Once you see `Listening on`, Scanner is ready.

## Log In

Open `http://localhost` (or your configured port) and log in with the initial credentials:

| Field | Value |
|---|---|
| Email | `admin@example.com` unless you set `ADMIN_EMAIL` |
| Password | The `ADMIN_INITIAL_PASSWORD` value from your `.env` file |

:::danger Change your password immediately
The initial password is only used when the admin account is created on first boot. Go to your profile settings and change it before doing anything else.
:::

The admin email and initial password can be customized before first boot via `ADMIN_EMAIL` and `ADMIN_INITIAL_PASSWORD` environment variables.

## What's Next

- **Run your first scan** → [First Scan](./first-scan) — uses the built-in Mock LLM, no API keys needed
- **Connect a real AI target** → [Targets](../user-guide/targets)
- **Configure API keys** → [Environment Variables](../user-guide/environment-variables)
- **Deploy to production** → [Production Docker Compose](../deployment/docker-compose)
