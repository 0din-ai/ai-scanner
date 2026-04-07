#!/usr/bin/env python3
"""
Regression tests for run_garak.py signal handler behavior under fork.

These tests verify that:
1. The parent (main) process correctly performs cleanup on SIGTERM.
2. Forked child processes do NOT execute parent cleanup on SIGTERM.

Bug context: signal handlers registered at module-level with signal.signal()
are inherited by child processes created via os.fork(). When garak's internal
code forks, the child inherits the parent's SIGTERM handler. If the child
receives SIGTERM it runs signal_handler, which calls notify_report_stopped —
clearing the parent's PID in the database and corrupting lifecycle state.
"""

import os
import signal
import sys
import tempfile
import unittest
from types import ModuleType
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Mock db_notifier (and its transitive dependency psycopg2) BEFORE importing
# run_garak, because run_garak performs a module-level
#     from db_notifier import ...
# which would fail without a real PostgreSQL driver.
# ---------------------------------------------------------------------------

_mock_db = ModuleType("db_notifier")
_mock_db.notify_report_running = MagicMock(return_value=True)
_mock_db.notify_report_ready = MagicMock(return_value=True)
_mock_db.notify_report_ready_from_synced = MagicMock(return_value=True)
_mock_db.notify_report_stopped = MagicMock(return_value=True)
_mock_db.load_existing_jsonl_prefix = MagicMock(return_value="")
_mock_db.HeartbeatThread = MagicMock
_mock_db.JournalSyncThread = MagicMock
_mock_db.REPORTS_PATH = "/tmp/fake_reports"

# psycopg2 stub so any stray import doesn't blow up
_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = Exception
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
sys.modules["psycopg2"] = _mock_psycopg2
sys.modules["psycopg2.pool"] = _mock_psycopg2.pool

sys.modules["db_notifier"] = _mock_db

# Add script/ to sys.path so `import run_garak` resolves
SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, SCRIPT_DIR)

# Save original signal handlers BEFORE importing run_garak (which overwrites them)
_orig_sigterm = signal.getsignal(signal.SIGTERM)
_orig_sigint = signal.getsignal(signal.SIGINT)

import run_garak  # noqa: E402  (registers global SIGTERM/SIGINT handlers)


class TestParentSignalHandler(unittest.TestCase):
    """Baseline: the parent process SHOULD perform cleanup on SIGTERM."""

    def setUp(self):
        self._saved_uuid = run_garak.current_report_uuid
        self._saved_hb = run_garak.current_heartbeat
        self._saved_js = run_garak.current_journal_sync

    def tearDown(self):
        run_garak.current_report_uuid = self._saved_uuid
        run_garak.current_heartbeat = self._saved_hb
        run_garak.current_journal_sync = self._saved_js

    def test_parent_calls_notify_report_stopped(self):
        """Parent process performs cleanup when signal_handler fires."""
        run_garak.current_report_uuid = "parent-test-uuid"
        run_garak.current_heartbeat = None
        run_garak.current_journal_sync = None

        with patch.object(run_garak, "notify_report_stopped", return_value=True) as mock_stopped:
            with self.assertRaises(SystemExit):
                run_garak.signal_handler(signal.SIGTERM, None)
            mock_stopped.assert_called_once_with("parent-test-uuid")

    def test_parent_stops_heartbeat_and_journal_sync(self):
        """Parent process stops heartbeat and journal sync threads."""
        mock_hb = MagicMock()
        mock_js = MagicMock()
        run_garak.current_report_uuid = "parent-test-uuid"
        run_garak.current_heartbeat = mock_hb
        run_garak.current_journal_sync = mock_js

        with patch.object(run_garak, "notify_report_stopped", return_value=True):
            with self.assertRaises(SystemExit):
                run_garak.signal_handler(signal.SIGTERM, None)

        mock_hb.stop.assert_called_once()
        mock_js.stop.assert_called_once()


class TestChildSignalHandlerSafety(unittest.TestCase):
    """Forked child processes must NOT run parent cleanup.

    The signal_handler checks _main_pid and calls os._exit(1) in children,
    preventing inherited handlers from corrupting parent lifecycle state.
    """

    def setUp(self):
        self._saved_uuid = run_garak.current_report_uuid
        self._saved_hb = run_garak.current_heartbeat
        self._saved_js = run_garak.current_journal_sync

    def tearDown(self):
        run_garak.current_report_uuid = self._saved_uuid
        run_garak.current_heartbeat = self._saved_hb
        run_garak.current_journal_sync = self._saved_js

    def test_forked_child_does_not_call_notify_report_stopped(self):
        """A forked child receiving SIGTERM must not clear the parent PID.

        The child inherits signal_handler via fork() but the _main_pid guard
        detects the PID mismatch and calls os._exit(1) without cleanup.
        """
        fd, marker_file = tempfile.mkstemp(prefix="garak_child_cleanup_")
        os.close(fd)
        os.unlink(marker_file)  # Remove; test checks if child recreates it

        # Replace notify_report_stopped with a version that writes a marker
        original_fn = run_garak.notify_report_stopped

        def tracking_stopped(uuid):
            with open(marker_file, "w") as f:
                f.write(f"cleanup_called_by_pid_{os.getpid()}")
            return True

        run_garak.notify_report_stopped = tracking_stopped
        run_garak.current_report_uuid = "child-test-uuid"
        run_garak.current_heartbeat = None
        run_garak.current_journal_sync = None

        parent_pid = os.getpid()

        pid = os.fork()
        if pid == 0:
            # ---- Child process ----
            try:
                run_garak.signal_handler(signal.SIGTERM, None)
            except SystemExit:
                pass
            # Hard exit so child never returns into test runner
            os._exit(0)
        else:
            # ---- Parent process ----
            _, status = os.waitpid(pid, 0)

            cleanup_called_by_child = os.path.exists(marker_file)

            # Restore
            run_garak.notify_report_stopped = original_fn
            run_garak.current_report_uuid = self._saved_uuid
            if os.path.exists(marker_file):
                os.unlink(marker_file)

            self.assertFalse(
                cleanup_called_by_child,
                "Forked child process must NOT call notify_report_stopped "
                "(parent cleanup). The child inherited the global signal_handler "
                "and executed parent-only cleanup code.",
            )

    def test_forked_child_does_not_stop_heartbeat(self):
        """A forked child must not stop the parent heartbeat thread."""
        fd, marker_file = tempfile.mkstemp(prefix="garak_child_hb_")
        os.close(fd)
        os.unlink(marker_file)  # Remove; test checks if child recreates it

        mock_hb = MagicMock()
        # Track stop() calls via a marker file (mock state doesn't cross fork)
        def tracking_hb_stop():
            with open(marker_file, "w") as f:
                f.write(f"hb_stopped_by_pid_{os.getpid()}")

        mock_hb.stop = tracking_hb_stop

        run_garak.current_report_uuid = "child-hb-uuid"
        run_garak.current_heartbeat = mock_hb
        run_garak.current_journal_sync = None

        original_fn = run_garak.notify_report_stopped
        run_garak.notify_report_stopped = MagicMock(return_value=True)

        pid = os.fork()
        if pid == 0:
            try:
                run_garak.signal_handler(signal.SIGTERM, None)
            except SystemExit:
                pass
            os._exit(0)
        else:
            os.waitpid(pid, 0)

            hb_stopped_by_child = os.path.exists(marker_file)

            run_garak.notify_report_stopped = original_fn
            run_garak.current_heartbeat = self._saved_hb
            if os.path.exists(marker_file):
                os.unlink(marker_file)

            self.assertFalse(
                hb_stopped_by_child,
                "Forked child process must NOT stop the parent heartbeat thread.",
            )


# Restore original signal handlers so test runner isn't affected
signal.signal(signal.SIGTERM, _orig_sigterm)
signal.signal(signal.SIGINT, _orig_sigint)

if __name__ == "__main__":
    unittest.main()
