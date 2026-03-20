---
sidebar_position: 8
---

# Mock LLM

The **Mock LLM** is a lightweight test server included in Scanner's Docker Compose setup. It simulates AI model responses without requiring any API keys or external services.

## Purpose

Use the Mock LLM to:
- Validate your Scanner installation before connecting to a real AI provider
- Test your scan configuration and probe selection
- Understand what a scan report looks like with known outcomes
- Develop and test custom probe sources

## Modes

The Mock LLM supports three response modes that simulate different model behaviors. The mode is specified via the `mode` field in the JSON request body (or the `X-Mock-Mode` HTTP header). If no mode is specified, it defaults to `mixed`.

| Mode | Behavior | Use Case |
|---|---|---|
| `safe` | Always responds safely — all probes pass | Verify Scanner correctly scores a "good" model |
| `vulnerable` | Always responds vulnerably — all probes fail | Verify Scanner correctly scores a "bad" model |
| `mixed` | Mix of safe and vulnerable responses (default) | Realistic-looking test report with partial ASR |

## Connecting a Target

Create a target using `rest.RestGenerator` and the Mock LLM's internal Docker hostname:

| Field | Value |
|---|---|
| **Model Type** | `rest.RestGenerator` |
| **Model** | `http://mock-llm:9292/api/v1/mock_llm/chat` |

The hostname `mock-llm` is the Docker Compose service name — it's only resolvable from within the Docker network (i.e., from the `scanner` container).

The default mode is `mixed`. To force a specific mode, add `X-Mock-Mode: vulnerable` (or `safe`) as a custom request header in your target's JSON config.

## Expected Results

| Mode | Expected ASR |
|---|---|
| `safe` | ~0% |
| `vulnerable` | ~100% |
| `mixed` | ~50% |

Use `vulnerable` mode for your [first scan](../getting-started/first-scan) to see what a report with significant findings looks like.

## Mock LLM in Development

When running the dev environment (`docker compose -f docker-compose.dev.yml up`), the Mock LLM is also started automatically. The same endpoints are available.

## Source Code

The Mock LLM is a small Ruby Rack application located in `mock-llm/` at the repo root. It's intentionally minimal — if you need more sophisticated simulation (e.g., specific response patterns), you can modify it directly.
