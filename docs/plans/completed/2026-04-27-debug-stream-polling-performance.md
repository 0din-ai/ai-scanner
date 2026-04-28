# Debug Stream Polling Performance and Activity Stream Implementation Plan

## Overview

Implement the debug stream performance fix and remove `?debug=true` as the normal requirement for live Activity Stream visibility in ai-scanner.

Keep the implementation public-friendly for the open-source ai-scanner repo: no committed private paths, internal PR references, or private deployment-only wording in production code/docs.

## Context

Current ai-scanner behavior:
- `Reports::DebugStreamPayload.new(report).call` hydrates `report.raw_report_data` and parses `raw_report_data.jsonl_data`.
- `BroadcastReportDebugJob` runs every 10 seconds for watched polling-status reports and builds the full payload before it knows whether JSONL/log inputs changed.
- Admin and report-details pages still require `params[:debug] == 'true'` to render logs/debug stream.

Behavior to implement in ai-scanner:
- `app/helpers/reports_helper.rb` has `activity_stream_active_status_for_report?` and `show_activity_stream_for_report?`.
- Active/pending reports show an Activity Stream without `?debug=true`.
- Timeline / Raw JSONL / Execution Logs are collapsed behind a “View activity” button.
- PDF mode does not show the stream.
- Show actions do not start watcher leases directly from `params[:debug]`; the mounted lease controller calls `refresh_debug_lease` on connect.

Important ai-scanner adaptation:
- Do not copy stricter `user&.super_admin?` semantics from external references blindly. ai-scanner currently allows authenticated same-company users to access the debug stream routes. Use `user.present?` plus existing authorization unless an existing ai-scanner policy indicates a stricter rule.
- Do not implement the optional Phase 2 JSONL offset/snapshot schema change unless Phase 1 cannot pass tests. The intended implementation is no-schema-change fingerprint gating.

## Success Criteria

Active/pending admin and report-details pages render Activity Stream without `?debug=true`; advanced details stay collapsed by default; PDF mode stays excluded; watched report polling skips payload construction when scalar metadata is unchanged; focused specs pass.

## Validation Commands

Run focused tests after implementation:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/services/reports/debug_stream_fingerprint_spec.rb \
  spec/services/reports/debug_stream_payload_spec.rb \
  spec/jobs/broadcast_report_debug_job_spec.rb \
  spec/requests/report_debug_stream_spec.rb
```

Run targeted RuboCop:

```bash
bundle exec rubocop \
  app/services/reports/debug_stream_fingerprint.rb \
  app/services/reports/debug_stream_payload.rb \
  app/jobs/broadcast_report_debug_job.rb \
  app/helpers/reports_helper.rb \
  spec/services/reports/debug_stream_fingerprint_spec.rb \
  spec/services/reports/debug_stream_payload_spec.rb \
  spec/jobs/broadcast_report_debug_job_spec.rb \
  spec/requests/report_debug_stream_spec.rb
```

If host DB cannot resolve `postgres`, use a disposable local Postgres or the ai-scanner dev-container testing workflow.

### Task 1: Add metadata-only debug stream fingerprints

- [x] Create `app/services/reports/debug_stream_fingerprint.rb`.
- [x] Implement a service returning `nil` when the report is missing and otherwise returning a hash with scalar metadata and `:digest`.
- [x] Query `reports`, `raw_report_data`, and `report_debug_logs` with `LEFT JOIN`s without selecting `raw_report_data.jsonl_data`, `report_debug_logs.logs`, or `report_debug_logs.tail`.
- [x] Include status, report updated timestamp, raw row updated timestamp, optional `octet_length(raw_report_data.jsonl_data)` as `raw_jsonl_bytes`, tail offset, tail digest, tail synced timestamp, and tail truncated state.
- [x] Exclude plain `report_debug_logs.updated_at` from the digest if tail metadata is otherwise unchanged, so timestamp-only touches do not force payload rebuilds.
- [x] Add `spec/services/reports/debug_stream_fingerprint_spec.rb` covering unchanged digest stability, raw JSONL changes, tail digest changes, missing raw data, missing debug log, and missing report.
- [x] Run the new fingerprint spec and fix failures.

### Task 2: Gate `BroadcastReportDebugJob` before payload construction

- [x] Modify `app/jobs/broadcast_report_debug_job.rb` to compute `Reports::DebugStreamFingerprint` after report reload and before `Reports::DebugStreamPayload.new(report).call`.
- [x] Add a cache key such as `broadcast_report_debug:fingerprint:#{report_id}`.
- [x] If the current fingerprint digest equals the cached fingerprint, skip payload construction and broadcasting while preserving current re-enqueue behavior for watched polling-status reports.
- [x] Write the cached fingerprint only after payload construction and broadcast-digest handling complete successfully.
- [x] Keep the existing rendered payload digest comparison as a second-stage guard.
- [x] Keep existing watcher, poller lease, and `limits_concurrency` behavior intact.
- [x] Update `spec/jobs/broadcast_report_debug_job_spec.rb` to prove unchanged fingerprint does not instantiate/build `Reports::DebugStreamPayload`, but still re-enqueues polling reports.
- [x] Update job specs proving raw JSONL changes and live-tail digest changes still broadcast.
- [x] Preserve existing behavior for missing raw data/status-only activity and terminal reports.

### Task 3: Memoize JSONL access inside `Reports::DebugStreamPayload`

- [x] Modify `app/services/reports/debug_stream_payload.rb` so a single payload build reads `raw_report_data.jsonl_data` at most once.
- [x] Add a private `jsonl_data` helper memoizing `raw_report_data&.jsonl_data.to_s`.
- [x] Update `parse_jsonl` to use the memoized string instead of calling `raw_report_data.jsonl_data` repeatedly.
- [x] Update `compute_digest` so it does not cause another raw JSONL read after parsing.
- [x] Preserve malformed JSONL handling, bounded `RAW_TAIL_LINES`, bounded `TIMELINE_TAIL_LIMIT`, live-tail logs, full terminal logs, and activity summary behavior.
- [x] Add/adjust `spec/services/reports/debug_stream_payload_spec.rb` to prove `jsonl_data` is called only once per `#call` and existing behavior remains unchanged.

### Task 4: Add Activity Stream visibility helpers

- [x] Modify `app/helpers/reports_helper.rb` to add `activity_stream_active_status_for_report?(report)` for active/pending Activity Stream visibility, using `(Report::DEBUG_BROADCAST_ACTIVE_STATUSES + %w[pending]).uniq`.
- [x] Add `show_activity_stream_for_report?(report, params:, user:, pdf_mode: false)` that returns false in PDF mode, false without an authenticated user, and true for active/pending reports or optional `?debug=true` fallback.
- [x] Use ai-scanner-appropriate authorization: do not add stricter `super_admin?` gating unless existing ai-scanner policies require it.
- [x] Add request/helper coverage proving active/pending reports can render Activity Stream without a debug query and terminal reports do not render by default unless the optional fallback is intentionally kept.

### Task 5: Add collapsed Activity Stream card UI

- [x] Create `app/views/admin/reports/_activity_stream_card.html.erb` for the collapsed Activity Stream card structure.
- [x] Modify `app/views/admin/reports/_activity_stream_summary.html.erb` so it displays the richer Activity Stream summary: title, LIVE badge for active streams, last updated state, status label, progress text, and explanatory copy.
- [x] Create `app/javascript/controllers/activity_stream_controller.js`: collapsed by default, “View activity” / “Hide activity” label toggling, `aria-expanded`, and focus handling.
- [x] Render the existing `admin/reports/debug_panel_stream` inside the collapsed advanced details area, preserving `report-debug-stream-content` and `report-activity-stream-summary` IDs used by Turbo broadcasts.
- [x] Preserve existing `debug-logs`, `log-viewer`, search/filter controls, and execution log rendering.
- [x] Continue using ai-scanner’s existing `debug_stream_lease_controller` for lease refresh unless a local test proves a different controller is necessary.

### Task 6: Remove `?debug=true` from normal report rendering

- [x] Modify `app/views/admin/reports/_show_v2.html.erb` to render the Activity Stream card when `show_activity_stream_for_report?(report, params: params, user: current_user)` is true, without requiring `params[:debug] == 'true'`.
- [x] Mount the lease controller around the Activity Stream card with `refresh_debug_lease_report_path(report)` and keep Turbo stream subscription only for active statuses.
- [x] Modify `app/views/report_details/show.html.erb` to use `show_activity_stream_for_report?(@report, params: params, user: current_user, pdf_mode: pdf_mode)` instead of `params[:debug] == 'true' && !pdf_mode`.
- [x] Mount the report-details lease controller with `refresh_debug_lease_report_detail_path(@report)` and keep Turbo stream subscription only for active statuses.
- [x] Remove direct `refresh_debug_stream_watcher if params[:debug] == "true"` activation from `Admin::ReportsController#show` and `ReportDetailsController#show`; the mounted lease controller should start/refresh watchers on connect.
- [x] Keep `refresh_debug_lease` endpoints as the watcher-start mechanism and preserve authorization/tenant behavior.

### Task 7: Update request specs and docs for no-query Activity Stream

- [x] Update `spec/requests/report_debug_stream_spec.rb` so `get report_path(running_report)` without debug query renders `report-activity-stream`, `report-activity-stream-summary`, `report-debug-stream-content`, lease controller attributes, and Turbo subscription.
- [x] Update `spec/requests/report_debug_stream_spec.rb` so `get report_detail_path(running_report)` without debug query renders the same Activity Stream structure.
- [x] Keep or add specs proving PDF mode does not render Activity Stream.
- [x] Keep or add specs proving unauthorized/other-company keepalive requests are rejected and do not create watcher leases.
- [x] Keep or add specs proving lease endpoints enqueue `BroadcastReportDebugJob` for pending, starting, running, and processing reports.
- [x] Update docs that currently say to append `?debug=true`: `docs-site/docs/development/architecture.md`, `docs-site/docs/troubleshooting.md`, `docs-site/docs/user-guide/reports.md`, and `docs-site/docs/user-guide/scanning.md`.
- [x] Replace user-facing “append `?debug=true`” guidance with “active reports show Activity Stream automatically; use View activity to expand timeline entries, the raw JSONL tail, and execution logs.”
- [x] If keeping `?debug=true` fallback for terminal reports, describe it only as an optional troubleshooting fallback, not the normal live-scan path.

### Task 8: Validate, clean up, and keep changes local

- [x] Run the focused RSpec command from the Validation Commands section.
- [x] Run the targeted RuboCop command from the Validation Commands section.
- [x] Run any JavaScript controller tests if the new `activity_stream_controller.js` needs coverage in `script/tests/javascript_controller_tests.mjs`.
- [x] Inspect `git status --short` and ensure no private paths or internal references are present in tracked source/docs changes.
- [x] Do not push.
