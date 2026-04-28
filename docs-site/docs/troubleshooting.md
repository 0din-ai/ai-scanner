---
sidebar_position: 6
---

# Troubleshooting

## Startup Errors

### `key must be 16 bytes`

```
ArgumentError: key must be 16 bytes
```

**Cause:** `SECRET_KEY_BASE` is not set, or is set to the placeholder value from `.env.example`.

**Fix:** Generate a proper key and set it in `.env`:

```bash
openssl rand -hex 64
```

```bash title=".env"
SECRET_KEY_BASE=<paste the generated 128-character hex string here>
```

---

### `Missing active_record_encryption keys`

```
RuntimeError: Missing active_record_encryption keys and no RAILS_MASTER_KEY available.
```

**Cause:** Same as above — `SECRET_KEY_BASE` is missing or invalid. Scanner derives its encryption keys from `SECRET_KEY_BASE`.

**Fix:** Set a valid `SECRET_KEY_BASE` as described above, then restart:

```bash
docker compose down
docker compose up -d
```

---

### `connection refused` on startup

```
PG::ConnectionBad: connection refused
```

**Cause:** PostgreSQL container isn't ready yet when Scanner tries to connect.

**Fix:** Docker Compose's health check should handle this automatically. If the error persists, increase the startup wait time or check that your `POSTGRES_PASSWORD` matches in both the `postgres` service config and the `scanner` service's environment.

---

## Port & Access Issues

### Can't access Scanner on port 80

**Cause:** Port 80 requires root on Linux, or may be blocked by your firewall or another service.

**Fix:** Change the port in `.env`:

```bash title=".env"
PORT=8080
```

Then restart: `docker compose up -d`. Access at `http://localhost:8080`.

---

### Session / cookie issues behind a reverse proxy

**Symptom:** Logged-in users are redirected to login repeatedly.

**Cause:** Missing `ASSUME_SSL=true` when running behind HTTPS.

**Fix:**

```bash title=".env"
ASSUME_SSL=true
```

---

## Database Issues

### Lost data after `docker compose down`

**Cause:** `docker compose down --volumes` (or `-v`) was run, which deletes the `postgres_data` volume.

**Fix:** Don't use `--volumes` unless intentionally resetting. Use `docker compose down` (no flags) to stop containers while preserving data.

Note: `docker compose stop` and `docker compose down` (without `--volumes`) both preserve data.

---

### Migrations not running automatically

**Fix:** Run manually after each update:

```bash
docker compose exec scanner rails db:migrate
```

---

## Scan Issues

### Scans failing with rate limit errors

**Symptom:** Scans complete with many failed attempts and rate limit errors in the logs.

**Fix:** Reduce `PARALLEL_ATTEMPTS` for that target. Set it as a per-target environment variable in the Scanner UI:

| Provider | Recommended Setting |
|---|---|
| OpenAI | 5–10 |
| Anthropic | 3–5 |
| Local models | 20–50 |

---

### Scan stuck in "Running" state

**Cause:** The Scanner container may have been restarted mid-scan. Interrupted scans should be retried automatically by `RetryInterruptedReportsJob`.

**Fix:** Wait a few minutes — the retry job runs periodically. If the scan stays stuck, check the logs:

```bash
docker compose logs scanner | grep -i "interrupt\|retry"
```

For per-report execution details, open the report while it is pending, starting, running, or processing. Activity Stream appears automatically for authenticated users; select **View activity** to expand timeline entries, the raw JSONL tail, and execution logs. Running scans show a bounded live log tail from the database, including offset, truncation, and last-updated metadata. For terminal reports, `?debug=true` remains an optional troubleshooting fallback for final execution logs.

---

## SIEM Integration Issues

### Rsyslog receiver not getting messages

**Check 1: RFC 3164 format compatibility**

Scanner sends syslog in **RFC 3164 (BSD syslog)** format. If your receiver expects RFC 5424, it may silently drop or misparse messages. Configure your receiver for RFC 3164:

```
# rsyslog imtcp example
module(load="imtcp")
input(type="imtcp" port="514")
```

**Check 2: PRI value**

Scanner uses PRI `<134>` (facility=`local0`, severity=`info`). If your receiver filters by facility or severity, ensure `local0` / `info` is allowed.

**Check 3: Firewall**

Ensure the Scanner container can reach your syslog server on the configured port.

---

### Splunk HEC returning 403

**Cause:** Invalid or expired HEC token, or HEC is disabled in Splunk.

**Fix:** Regenerate the token in Splunk (Settings → Data Inputs → HTTP Event Collector) and update the integration in Scanner.

---

### Test Integration button shows success but no data arrives

**Cause:** The test sends a connection-level test message. If Splunk index routing or rsyslog filters are configured to drop the test message, the connection succeeds but data is filtered out.

**Fix:** Run a real scan and check your SIEM for Scanner data. Look for `source=scanner_app` (Rsyslog) or the HEC index you configured (Splunk).

---

## PDF Export Issues

### PDF export shows login page

**Cause:** Known issue in older releases where PDF generation loaded the authenticated page without session context.

**Fix:** Update to the latest Scanner release — this issue has been fixed. Pull the latest image:

```bash
docker compose pull scanner
docker compose up -d
```

---

## Login Issues

### Forgot admin password

Reset it via the Rails console:

```bash
docker compose exec scanner rails console
```

```ruby
user = User.find_by(email: 'admin@example.com')
user.update!(password: 'new_secure_password', password_confirmation: 'new_secure_password')
```

---

## Getting More Help

- **Check the logs:** `docker compose logs -f scanner`
- **GitHub Issues:** [github.com/0din-ai/ai-scanner/issues](https://github.com/0din-ai/ai-scanner/issues)
- **Security issues:** See [SECURITY.md](https://github.com/0din-ai/ai-scanner/blob/main/SECURITY.md) — do not open public issues for security vulnerabilities
