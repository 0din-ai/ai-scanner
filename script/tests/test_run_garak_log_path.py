#!/usr/bin/env python3
"""
Tests for run_garak JournalSyncThread setup.
"""

import os
import signal
import sys
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
_mock_db.REPORTS_PATH = Path("/tmp/fake_reports")

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

_original_db_notifier = sys.modules.get("db_notifier")
_original_run_garak = sys.modules.pop("run_garak", None)
_orig_sigterm = signal.getsignal(signal.SIGTERM)
_orig_sigint = signal.getsignal(signal.SIGINT)
sys.modules["db_notifier"] = _mock_db

try:
    import run_garak as _run_garak  # noqa: E402
finally:
    if _original_db_notifier is None:
        sys.modules.pop("db_notifier", None)
    else:
        sys.modules["db_notifier"] = _original_db_notifier

    if _original_run_garak is None:
        sys.modules.pop("run_garak", None)
    else:
        sys.modules["run_garak"] = _original_run_garak

    signal.signal(signal.SIGTERM, _orig_sigterm)
    signal.signal(signal.SIGINT, _orig_sigint)

run_garak = _run_garak


class TestRunGarakJournalSyncLogPath(unittest.TestCase):
    def setUp(self):
        self._saved_uuid = run_garak.current_report_uuid
        self._saved_hb = run_garak.current_heartbeat
        self._saved_js = run_garak.current_journal_sync

    def tearDown(self):
        run_garak.current_report_uuid = self._saved_uuid
        run_garak.current_heartbeat = self._saved_hb
        run_garak.current_journal_sync = self._saved_js

    def test_main_passes_log_path_to_journal_sync_for_non_validation_runs(self):
        argv = [
            "run_garak.py",
            "report-uuid",
            "--target_type",
            "rest.RestGenerator",
            "--target_name",
            "rest",
        ]
        log_path = Path("/tmp/report-uuid.log")
        journal_sync = MagicMock()
        journal_sync.stop.return_value = True
        heartbeat = MagicMock()

        with patch.object(sys, "argv", argv), \
             patch.object(run_garak, "notify_report_running", return_value=True), \
             patch.object(run_garak, "HeartbeatThread", return_value=heartbeat), \
             patch.object(run_garak, "load_existing_jsonl_prefix", return_value="prefix-data"), \
             patch.object(run_garak, "get_log_file_path", return_value=log_path), \
             patch.object(run_garak, "JournalSyncThread", return_value=journal_sync) as mock_journal_sync, \
             patch.object(run_garak, "run_garak_scan", return_value=0), \
             patch.object(run_garak, "notify_report_ready_from_synced", return_value=True), \
             patch.object(run_garak, "notify_report_stopped", return_value=True), \
             patch("sys.exit") as mock_exit:
            run_garak.main()

        mock_journal_sync.assert_called_once_with(
            "report-uuid",
            run_garak.REPORTS_PATH / "report-uuid.report.jsonl",
            prefix="prefix-data",
            log_path=log_path,
        )
        journal_sync.start.assert_called_once()
        journal_sync.stop.assert_called_once()
        heartbeat.start.assert_called_once()
        heartbeat.stop.assert_called_once()
        mock_exit.assert_called_once_with(0)


if __name__ == "__main__":
    unittest.main()
