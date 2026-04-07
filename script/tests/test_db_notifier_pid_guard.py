#!/usr/bin/env python3
"""
Tests for the PID-match guard in db_notifier.notify_report_stopped.

The guard ensures that only the owning process (the one whose PID is stored
in the reports table) can clear the PID. A forked child process calling
notify_report_stopped will have a different os.getpid(), so the UPDATE's
WHERE clause won't match and the PID remains intact.
"""

import os
import sys
import unittest
from types import ModuleType
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Stub psycopg2 before importing db_notifier
# ---------------------------------------------------------------------------
_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = type("OperationalError", (Exception,), {})
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
_mock_psycopg2.pool.ThreadedConnectionPool = MagicMock
sys.modules.setdefault("psycopg2", _mock_psycopg2)
sys.modules.setdefault("psycopg2.pool", _mock_psycopg2.pool)

# Add script/ to sys.path
SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

# When run together with test_run_garak_signal_handler, db_notifier may already
# be cached as a lightweight mock (no pooled_connection). Force a fresh import
# of the real module so we can test the actual notify_report_stopped function.
if "db_notifier" in sys.modules:
    cached = sys.modules["db_notifier"]
    if not hasattr(cached, "pooled_connection"):
        del sys.modules["db_notifier"]
        # Also ensure psycopg2.pool stub has ThreadedConnectionPool for reimport
        _pool_mod = sys.modules.get("psycopg2.pool")
        if _pool_mod and not hasattr(_pool_mod, "ThreadedConnectionPool"):
            _pool_mod.ThreadedConnectionPool = MagicMock

import db_notifier  # noqa: E402


class TestNotifyReportStoppedPidGuard(unittest.TestCase):
    """notify_report_stopped only clears PID when stored PID matches caller."""

    def _make_mock_conn(self, rowcount=1):
        """Build a mock pooled connection with a cursor that returns rowcount."""
        mock_cur = MagicMock()
        mock_cur.rowcount = rowcount
        mock_cur.__enter__ = MagicMock(return_value=mock_cur)
        mock_cur.__exit__ = MagicMock(return_value=False)

        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)

        return mock_conn, mock_cur

    @patch("db_notifier.pooled_connection")
    def test_owner_pid_clears_successfully(self, mock_pooled):
        """When stored PID matches caller PID, UPDATE succeeds (rowcount=1)."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        my_pid = os.getpid()
        result = db_notifier.notify_report_stopped("test-uuid-owner")

        self.assertTrue(result)

        # Verify the SQL includes the PID match clause
        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]

        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-owner", my_pid))

    @patch("db_notifier.pooled_connection")
    def test_mismatched_pid_does_not_clear(self, mock_pooled):
        """When stored PID doesn't match, UPDATE is a no-op (rowcount=0)."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0)
        mock_pooled.return_value = mock_conn

        # Pass a PID that would be different from stored PID
        result = db_notifier.notify_report_stopped("test-uuid-child", expected_pid=99999)

        self.assertFalse(result)

        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]
        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-child", 99999))

    @patch("db_notifier.pooled_connection")
    def test_explicit_expected_pid_overrides_getpid(self, mock_pooled):
        """The expected_pid parameter overrides os.getpid() in the query."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        explicit_pid = 12345
        result = db_notifier.notify_report_stopped("test-uuid-explicit", expected_pid=explicit_pid)

        self.assertTrue(result)

        executed_params = mock_cur.execute.call_args[0][1]
        self.assertEqual(executed_params, ("test-uuid-explicit", explicit_pid))

    @patch("db_notifier.pooled_connection")
    def test_defaults_to_current_pid(self, mock_pooled):
        """When expected_pid is omitted, os.getpid() is used."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        result = db_notifier.notify_report_stopped("test-uuid-default")

        executed_params = mock_cur.execute.call_args[0][1]
        self.assertEqual(executed_params[1], os.getpid())

    @patch("db_notifier.pooled_connection")
    def test_exception_returns_false(self, mock_pooled):
        """Database errors are caught and return False."""
        mock_pooled.side_effect = Exception("connection failed")

        result = db_notifier.notify_report_stopped("test-uuid-err")
        self.assertFalse(result)

    @patch("db_notifier.pooled_connection")
    def test_forked_child_pid_mismatch(self, mock_pooled):
        """Simulates a forked child: different PID means rowcount=0."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0)
        mock_pooled.return_value = mock_conn

        # Simulate child with PID different from the parent's stored PID
        parent_pid = os.getpid()
        child_pid = parent_pid + 1  # Would be different after fork

        result = db_notifier.notify_report_stopped("test-uuid-fork", expected_pid=child_pid)

        self.assertFalse(result)
        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]
        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-fork", child_pid))


if __name__ == "__main__":
    unittest.main()
