#!/usr/bin/env python3
"""
Regression tests for run_garak.py handling of a failed "running" status write.

Bug context: notify_report_running() is the only writer of reports.status =
'running'. When it failed, main() discarded the result and started the scan
anyway. The report stayed in 'starting', so HeartbeatThread's UPDATE (which
matches ... AND status = 'running') affected zero rows, which the thread reads
as "status changed" and answers with SIGTERM to its own process -- killing a
healthy scan ~30s in. CheckStaleReportsJob then retried the report up to
MAX_START_RETRIES times and finally reported "Failed after 3 start attempts.
Each attempt timed out", which is misleading: every process started fine.

Failing fast instead costs one attempt rather than four and lets the
'starting' reaper retry from a clean state.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

_mock_db = ModuleType("db_notifier")
_mock_db.notify_report_running = MagicMock(return_value=True)
_mock_db.notify_report_ready = MagicMock(return_value=True)
_mock_db.notify_report_ready_from_synced = MagicMock(return_value=True)
_mock_db.notify_report_stopped = MagicMock(return_value=True)
_mock_db.load_existing_jsonl_prefix = MagicMock(return_value="")
_mock_db.get_log_file_path = MagicMock(return_value=Path("/tmp/fake_reports/report.log"))
_mock_db.HeartbeatThread = MagicMock
_mock_db.JournalSyncThread = MagicMock
# Path (not str): run_garak builds paths with the `/` operator.
_mock_db.REPORTS_PATH = Path("/tmp/fake_reports")
_mock_db.CONFIG_PATH = Path("/tmp/fake_reports/config")

_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = Exception
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
_mock_psycopg2.pool.ThreadedConnectionPool = MagicMock
sys.modules["psycopg2"] = _mock_psycopg2
sys.modules["psycopg2.pool"] = _mock_psycopg2.pool

_original_db_notifier = sys.modules.get("db_notifier")
sys.modules["db_notifier"] = _mock_db

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, SCRIPT_DIR)

try:
    import run_garak  # noqa: E402
finally:
    if _original_db_notifier is None:
        sys.modules.pop("db_notifier", None)
    else:
        sys.modules["db_notifier"] = _original_db_notifier

# Rails mints this when it claims the attempt and passes it in the process env.
TOKEN = "11111111-2222-3333-4444-555555555555"


class TestRunningNotificationFailureIsFatal(unittest.TestCase):
    def _run_main(self, running_result, uuid="report-uuid-123", config_dir=None, token=TOKEN,
                  stopped_result=True):
        # run_garak is imported once per process, so whichever test module imports it
        # first supplies these module-level constants. Pin them here (as Path, since
        # run_garak builds paths with `/`) so this test does not depend on that order.
        tmp = Path(tempfile.mkdtemp())
        config_dir = config_dir or (tmp / "config")
        config_dir.mkdir(parents=True, exist_ok=True)
        with patch.object(run_garak, "REPORTS_PATH", tmp), \
             patch.object(run_garak, "CONFIG_PATH", config_dir), \
             patch.object(run_garak, "notify_report_running", return_value=running_result), \
             patch.object(run_garak, "run_garak_scan", return_value=0) as mock_scan, \
             patch.object(run_garak, "HeartbeatThread") as mock_heartbeat, \
             patch.object(run_garak, "JournalSyncThread"), \
             patch.object(run_garak, "notify_report_ready", return_value=True), \
             patch.object(run_garak, "notify_report_ready_from_synced", return_value=True), \
             patch.object(run_garak, "notify_report_stopped", return_value=stopped_result) as mock_stopped, \
             patch.object(run_garak, "load_existing_jsonl_prefix", return_value=""), \
             patch.object(run_garak, "get_log_file_path", return_value=tmp / "report.log"), \
             patch.object(sys, "argv", ["run_garak.py", uuid]), \
             patch.dict(os.environ, {}):
            if token:
                os.environ["SCAN_EXECUTION_TOKEN"] = token
            else:
                os.environ.pop("SCAN_EXECUTION_TOKEN", None)
            with self.assertRaises(SystemExit) as ctx:
                run_garak.main()
        return ctx.exception.code, mock_scan, mock_heartbeat, mock_stopped

    def test_exits_nonzero_and_skips_the_scan_when_the_running_write_fails(self):
        code, mock_scan, mock_heartbeat, _stopped = self._run_main(running_result=False)

        self.assertEqual(code, 1)
        # Starting the scan would guarantee a SIGTERM from the heartbeat ~30s later.
        mock_scan.assert_not_called()
        mock_heartbeat.assert_not_called()

    def test_removes_the_credential_web_config_on_the_abort_path(self):
        """The abort returns before main()'s try/finally, so it must delete the
        credential-bearing <uuid>_web.json itself. Rails writes that file before
        launching this process, and once the process is accepted as started its own
        startup rescue no longer removes it."""
        config_dir = Path(tempfile.mkdtemp())
        web_config = config_dir / "report-uuid-123_web.json"
        web_config.write_text('{"cookies": [{"name": "session", "value": "secret"}]}')

        code, _scan, _hb, _stopped = self._run_main(running_result=False, config_dir=config_dir)

        self.assertEqual(code, 1)
        self.assertFalse(web_config.exists(), "credential web config left on disk")

    def test_clears_the_recorded_pid_on_the_abort_path(self):
        """notify_report_running() can return False after the reports row is already
        committed: the pool hands out autocommit connections, so the status/pid UPDATE
        lands before the report_debug_logs statement that follows can fail. Without
        this, a dead process stays recorded as running until the reaper notices.
        The call is PID-safe, so it is a no-op when nothing was recorded."""
        code, _scan, _hb, mock_stopped = self._run_main(running_result=False)

        self.assertEqual(code, 1)
        mock_stopped.assert_called_once_with("report-uuid-123", TOKEN)

    def test_still_runs_the_scan_when_the_running_write_succeeds(self):
        code, mock_scan, _mock_heartbeat, _stopped = self._run_main(running_result=True)

        self.assertEqual(code, 0)
        mock_scan.assert_called_once()

    def test_keeps_the_credential_config_when_another_attempt_owns_the_report(self):
        # <uuid>_web.json is keyed on the report UUID alone, so it is the same file a
        # replacement attempt is already using. notify_report_stopped declining is how
        # this process learns it is no longer the owner.
        config_dir = Path(tempfile.mkdtemp()) / "config"
        config_dir.mkdir(parents=True)
        web_config = config_dir / "report-uuid-123_web.json"
        web_config.write_text("{}")

        self._run_main(running_result=False, config_dir=config_dir, stopped_result=False)

        self.assertTrue(
            web_config.exists(),
            "a superseded process deleted the live attempt's credential file",
        )

    def test_removes_the_credential_config_when_ownership_cleanup_errors(self):
        # A None result means the release could not be determined -- a database outage,
        # say -- not that another attempt owns the report. Only a definitive mismatch
        # may keep credentials on disk; nothing else runs after this exit.
        config_dir = Path(tempfile.mkdtemp()) / "config"
        config_dir.mkdir(parents=True)
        web_config = config_dir / "report-uuid-123_web.json"
        web_config.write_text('{"cookies": [{"name": "session", "value": "secret"}]}')

        self._run_main(running_result=False, config_dir=config_dir, stopped_result=None)

        self.assertFalse(web_config.exists(), "credential web config left on disk")

    def test_refuses_to_start_without_an_execution_token(self):
        # Rails could only omit the token if the attempt was already revoked. Every
        # write this process makes would be rejected, so running the scan would burn
        # a full scan's work to produce nothing. Fail immediately, with a reason.
        code, mock_scan, mock_heartbeat, _stopped = self._run_main(
            running_result=True, token=None
        )

        self.assertEqual(code, 1)
        mock_scan.assert_not_called()
        mock_heartbeat.assert_not_called()

    def test_validation_runs_do_not_need_an_execution_token(self):
        # Validation runs have no report row to own, so there is nothing to fence.
        code, mock_scan, _hb, _stopped = self._run_main(
            running_result=True, uuid="validation_abc", token=None
        )

        self.assertEqual(code, 0)
        mock_scan.assert_called_once()

    def test_validation_runs_do_not_require_the_running_write(self):
        # Validation runs have no database report record, so they never notify.
        code, mock_scan, mock_heartbeat, _stopped = self._run_main(
            running_result=False, uuid="validation_abc"
        )

        self.assertEqual(code, 0)
        mock_scan.assert_called_once()
        mock_heartbeat.assert_not_called()


if __name__ == "__main__":
    unittest.main()
