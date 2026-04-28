---
sidebar_position: 4
---

# Upgrading

## Upgrade Procedure

### Option A: Pre-built Image

```bash
# Pull the latest image
docker compose pull scanner

# Restart with new image
docker compose up -d

# Run any pending migrations
docker compose exec scanner rails db:migrate
```

### Option B: Built from Source

```bash
# Pull latest changes
git pull

# Rebuild the scanner image
docker compose build scanner

# Restart
docker compose up -d

# Run any pending migrations
docker compose exec scanner rails db:migrate
```

:::tip Always run db:migrate after upgrading
Even if a release doesn't mention schema changes, running `db:migrate` is safe (it's a no-op if there's nothing to migrate) and protects you from silent migration gaps.
:::

## Checking the Current Version

```bash
docker compose exec scanner rails runner "puts Rails.application.config.version rescue 'unknown'"
```

Or check the GitHub [releases page](https://github.com/0din-ai/ai-scanner/releases) to see the latest version and release notes.

## Before Upgrading

1. **Read the release notes** — check the [Releases page](https://github.com/0din-ai/ai-scanner/releases) for breaking changes
2. **Back up your database** — especially before major version upgrades

```bash
# Dump the database
docker compose exec postgres pg_dump -U scanner scanner_production > backup_$(date +%Y%m%d).sql
```

## Report Log Storage Migration

Recent versions store report execution logs in `report_debug_logs` instead of `reports.logs`. The migration backfills existing final logs into `report_debug_logs.logs` and stores live debug tails in `report_debug_logs.tail`. Run migrations after upgrading:

```bash
docker compose exec scanner rails db:migrate
```

Rails callers should continue to use `Report#logs`. Direct SQL/reporting integrations must join `report_debug_logs` and read `report_debug_logs.logs` after this migration because the legacy `reports.logs` column is removed. Rolling the migration back restores final logs to `reports.logs`; transient live tails are not preserved on rollback.

## Rollback

If an upgrade causes issues:

```bash
# Pin to a specific image version
# Edit docker-compose.yml: image: ghcr.io/0din-ai/scanner:v1.2.3

docker compose up -d
```

Database rollback is only possible if the migrations are reversible. Most Scanner migrations are written to be reversible, but check the release notes for any exceptions.

## Zero-Downtime Upgrades

Scanner's single-process architecture (Puma + Solid Queue in-process) doesn't currently support hot rolling upgrades. Expect a brief restart window (~30 seconds) during upgrades.

For environments requiring zero downtime, deploy a blue-green stack (two separate compose stacks behind a load balancer) and switch traffic after the new stack is healthy.
