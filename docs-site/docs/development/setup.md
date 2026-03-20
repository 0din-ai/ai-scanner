---
sidebar_position: 1
---

# Development Setup

## Prerequisites

- **Docker** and **Docker Compose** v2
- **Git**
- A text editor

No local Ruby, Node.js, or Python installation is required — everything runs in Docker.

## Getting Started

```bash
git clone https://github.com/0din-ai/ai-scanner.git
cd ai-scanner
cp .env.example .env
```

Edit `.env` and set:

```bash
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=dev_password
```

Build and start the dev environment:

```bash
docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml up
```

The database is set up automatically on first boot. Once you see `Listening on`, open `http://localhost` and log in with `admin@example.com` / `password`.

## Dev vs Production Compose

| Aspect | `docker-compose.dev.yml` | `docker-compose.yml` |
|---|---|---|
| Source code | Mounted as volume (live reload) | Copied into image |
| Dockerfile | `Dockerfile.dev` | `Dockerfile` |
| Purpose | Development iteration | Production / integration testing |

Use the dev compose file for day-to-day development — changes to Ruby files are picked up automatically by Puma's file watcher.

## Running Rails Commands

Open a shell inside the running scanner container:

```bash
docker compose -f docker-compose.dev.yml exec scanner /bin/bash
```

Then use standard Rails commands:

```bash
rails console
rails db:migrate
rails routes | grep scan
```

## Debugging

Place `binding.pry` or `debugger` anywhere in Ruby code to set a breakpoint. The breakpoint will activate in the terminal running `docker compose up` — look for the Pry prompt there.

```ruby
def create
  binding.pry  # execution stops here
  @scan = Scan.new(scan_params)
  # ...
end
```

## Background Jobs

Solid Queue runs in-process with Puma (same container). Background jobs are visible in the Rails logs. To manually run a job in the console:

```bash
rails console
SyncProbesJob.perform_now
```

## Mock LLM

The dev compose file starts the Mock LLM server automatically. It's available at `http://mock-llm:9292` from within the Docker network (endpoint: `/api/v1/mock_llm/chat`). Use it to run scans during development without API keys.

## Port Conflicts

If port 80 is in use on your development machine, set `PORT` in `.env`:

```bash
PORT=3000
```

Access Scanner at `http://localhost:3000`.
