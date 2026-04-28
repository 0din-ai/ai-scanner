---
sidebar_position: 4
---

# Reports

A report is generated after each completed scan. It contains the full results of every probe attempt made against your target.

For troubleshooting queued or active reports, Activity Stream appears automatically for authenticated users while a report is pending, starting, running, or processing. Select **View activity** to expand timeline entries, the raw JSONL tail, and execution logs. Running scans display the live database-backed log tail; terminal reports can use the optional `?debug=true` fallback to show final logs. The log viewer supports search plus PASS/FAIL filters.

## Report Structure

### Summary

The top of every report shows:

- **Attack Success Rate (ASR)** — overall percentage of probes that succeeded in eliciting problematic responses
- **Scan duration** — how long the scan took
- **Target** — which AI model was tested
- **Probe count** — number of probe families included

### Probe Results

A breakdown by probe family showing:

- **Family name** — the vulnerability category
- **ASR for this family** — how well the model resisted this class of probes
- **Attempts** — total attempts run for this family
- **Passed / Failed** — attempt counts

### Attempt Detail

Expand any probe to see every individual attempt:

- The **prompt** sent to the model
- The **response** received
- Whether the attempt **passed or failed** (from a security perspective — a "failed" attempt means the model responded in a way the detector flagged as problematic)
- The **detector** that evaluated the response

## Understanding ASR

See [Core Concepts → ASR](./core-concepts#attack-success-rate-asr) for a full explanation of the scoring scale.

A high ASR on a probe family means your model is frequently responding in ways that could be exploited. Lower is better.

## Trend Tracking

When you run the same scan configuration repeatedly over time, the report list shows ASR trend arrows — whether your model's security posture is improving, worsening, or staying the same between runs.

This is particularly useful for:
- Measuring the impact of system prompt changes
- Tracking security regressions after model updates
- Demonstrating improvement to stakeholders

## Exporting Reports

### PDF Export

Click **Export PDF** from any report view to download a formatted report. The PDF includes:

- Executive summary with ASR scores
- Per-probe family breakdown
- Full attempt detail

PDF exports are suitable for sharing with security teams, compliance reviewers, or AI system owners.

### SIEM Integration

If you've configured a Splunk or Rsyslog integration, scan results are automatically forwarded when the scan completes. See [Integrations](./integrations) for setup.

## Report Retention

Reports are kept for **90 days** by default. This is configurable via `RETENTION_DAYS` in your environment. The retention job runs nightly.
