# Port stuck-running report lifecycle fix from scanner to ai-scanner

> For Hermes: use the ralphex skill against this plan file in `/Users/olehperevertailo/Projects/ai-scanner`. Stream progress from `.ralphex/progress/progress-2026-04-07-port-stuck-running-report-lifecycle-fix.txt`.

## Overview

Port the verified stuck-running report lifecycle fix from the private scanner repo into ai-scanner without pushing anything to GitHub. The private scanner fix addressed a real production bug where garak child processes inherited the global SIGTERM cleanup handler, executed parent-only cleanup, and could leave reports stuck in `running` because the parent heartbeat continued while PID state was corrupted. ai-scanner currently still has the pre-fix patterns.

## Important constraints

- This is the public/open-source repo at `/Users/olehperevertailo/Projects/ai-scanner`.
- Work on the local branch only.
- Do **not** push.
- Do **not** open a PR.
- Keep the branch local for review.

## Verified pre-port findings in ai-scanner

Equivalent files exist and still contain the old behavior:

- `script/run_garak.py`
  - global `signal_handler` still does unconditional cleanup in forked children
  - handlers are registered globally
- `script/db_notifier.py`
  - `notify_report_stopped` still does unconditional `UPDATE reports SET pid = NULL ... WHERE uuid = %s`
- `app/jobs/check_stale_reports_job.rb`
  - only 3 checks exist (stale heartbeat, never-started running, stuck starting)
  - no orphaned-running detection for `running + pid=nil + heartbeat present`
- `app/jobs/retry_interrupted_reports_job.rb`
  - clears `heartbeat_at` but does not clear `pid`

Equivalent spec files exist in ai-scanner:

- `spec/services/run_garak_scan_spec.rb`
- `spec/jobs/check_stale_reports_job_spec.rb`
- `spec/jobs/retry_interrupted_reports_job_spec.rb`
- `spec/integration/interrupted_reports_lifecycle_spec.rb`
- `spec/e2e/interrupted_reports_e2e_spec.rb`

## Architecture / implementation strategy

Port the minimal proven fix set from scanner, preserving ai-scanner’s local structure and test style:

1. Make `run_garak.py` child-safe under Linux `fork`
2. Add owner-PID guard to `notify_report_stopped`
3. Add orphaned-running detection to `CheckStaleReportsJob`
4. Clear stale PID in `RetryInterruptedReportsJob`
5. Port the regression tests and then adjust any ai-scanner-specific stale-heartbeat fixtures so they reflect the new recovery rules

## Files expected to change

- `script/run_garak.py`
- `script/db_notifier.py`
- `app/jobs/check_stale_reports_job.rb`
- `app/jobs/retry_interrupted_reports_job.rb`
- `spec/jobs/check_stale_reports_job_spec.rb`
- `spec/jobs/retry_interrupted_reports_job_spec.rb`
- `spec/integration/interrupted_reports_lifecycle_spec.rb`
- `spec/e2e/interrupted_reports_e2e_spec.rb`
- create Python tests if absent:
  - `script/tests/test_run_garak_signal_handler.py`
  - `script/tests/test_db_notifier_pid_guard.py`

## Success criteria

- Forked garak child processes do not run parent report cleanup.
- `notify_report_stopped` only clears PID when called by the owning process.
- Orphaned `running` reports with `pid=nil` and a heartbeat are interrupted/recovered instead of lingering forever.
- Retried interrupted reports clear stale PID state.
- Relevant Ruby and Python regression tests pass locally.
- No changes are pushed to GitHub.

## Validation commands

Run directly from this repo working tree (host environment), not via docker-compose dev, to avoid container-name collisions with the private scanner repo.

Focused Ruby validation:

```bash
cd /Users/olehperevertailo/Projects/ai-scanner && \
RAILS_ENV=test bundle exec rspec \
  spec/e2e/interrupted_reports_e2e_spec.rb \
  spec/jobs/check_stale_reports_job_spec.rb \
  spec/jobs/retry_interrupted_reports_job_spec.rb \
  spec/integration/interrupted_reports_lifecycle_spec.rb
```

Focused Python validation (if the tests are added):

```bash
cd /Users/olehperevertailo/Projects/ai-scanner && \
python3 -m unittest \
  script/tests/test_run_garak_signal_handler.py \
  script/tests/test_db_notifier_pid_guard.py -v
```

Broader verification if needed after the focused set is green:

```bash
cd /Users/olehperevertailo/Projects/ai-scanner && RAILS_ENV=test bundle exec rspec
```

## Task breakdown

### Task 1: Add failing Python regression coverage for inherited child cleanup

- [x] Inspect `script/run_garak.py` and determine the lightest-weight way to test `signal_handler` behavior directly.
- [x] Create `script/tests/test_run_garak_signal_handler.py` if it does not exist.
- [x] Add failing tests that prove forked child processes currently execute parent cleanup when signaled.
- [x] Keep the tests lightweight by mocking `db_notifier` and avoiding real DB/garak execution.
- [x] Run the Python test file and verify the child-process cases fail while baseline parent behavior still passes.

### Task 2: Port the parent-only SIGTERM cleanup fix into `script/run_garak.py`

- [x] Capture the main process PID at startup.
- [x] Add PID/PPID logging to the signal handler.
- [x] Ensure only the original main process performs report cleanup.
- [x] Use hard child exit semantics so forked children cannot unwind into parent cleanup frames.
- [x] Update the Python regression tests to pass.
- [x] Commit only the relevant files for this task.

### Task 3: Port the PID-match guard into `script/db_notifier.py`

- [x] Change `notify_report_stopped` so it only clears the PID when the stored PID matches the current process PID.
- [x] Add a Python test file for the PID-match guard if needed (`script/tests/test_db_notifier_pid_guard.py`).
- [x] Verify graceful behavior on mismatch and success on owner match.
- [x] Run both Python test files.
- [x] Commit the task.

### Task 4: Add orphaned-running detection to `CheckStaleReportsJob`

- [x] Add failing Ruby specs for the prod-shaped orphaned state: `running`, `pid=nil`, heartbeat present, no real progress.
- [x] Implement a new orphaned-running detection path in `app/jobs/check_stale_reports_job.rb`.
- [x] Preserve the existing stale-heartbeat and never-started behavior.
- [x] Update job comments to reflect the extra detection path.
- [x] Run `spec/jobs/check_stale_reports_job_spec.rb` and make it pass.
- [x] Commit the task.

### Task 5: Clear PID when requeueing interrupted reports

- [x] Add `pid: nil` in `RetryInterruptedReportsJob` alongside `heartbeat_at: nil`.
- [x] Add a focused spec proving stale PID state is cleared on retry.
- [x] Run `spec/jobs/retry_interrupted_reports_job_spec.rb` and make it pass.
- [x] Commit the task.

### Task 6: Port the lifecycle/integration coverage

- [ ] Extend `spec/integration/interrupted_reports_lifecycle_spec.rb` to cover orphaned-running recovery.
- [ ] Extend `spec/e2e/interrupted_reports_e2e_spec.rb` if needed to align with the new stale/orphan semantics.
- [ ] If any pre-existing fixtures assumed “healthy running report with heartbeat but no pid,” fix those tests to represent valid healthy state.
- [ ] Run the focused Ruby validation suite and make it pass.
- [ ] Commit the task.

### Task 7: Final local-only verification and summary

- [ ] Run the focused Ruby and Python validation suite again.
- [ ] Inspect diffs to ensure changes are limited to the intended files.
- [ ] Confirm no push/PR was performed.
- [ ] Summarize:
  - root cause
  - safeguards added
  - tests proving the port
  - whether any ai-scanner-specific follow-up remains

## Notes for the implementer

- Port the proven fix, do not redesign the lifecycle.
- Prefer the scanner implementation as the source of truth, but adapt only where ai-scanner differs structurally.
- If a review or test reveals that ai-scanner’s stale heartbeat query needs the same `updated_at` safety window behavior as scanner, port that too.
- Keep all work local. No push, no PR, no remote side effects.
