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
import tempfile
import unittest
from pathlib import Path
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

# Rails mints this when it claims the attempt; every scanner write is fenced on it.
TOKEN = "11111111-2222-3333-4444-555555555555"


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
        result = db_notifier.notify_report_stopped("test-uuid-owner", execution_token=TOKEN)

        self.assertTrue(result)

        # Verify the SQL includes the PID match clause
        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]

        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-owner", my_pid, TOKEN))

    @patch("db_notifier.pooled_connection")
    def test_mismatched_pid_does_not_clear(self, mock_pooled):
        """When stored PID doesn't match, UPDATE is a no-op (rowcount=0)."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0)
        mock_pooled.return_value = mock_conn

        # Pass a PID that would be different from stored PID
        result = db_notifier.notify_report_stopped("test-uuid-child", expected_pid=99999, execution_token=TOKEN)

        self.assertFalse(result)

        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]
        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-child", 99999, TOKEN))

    @patch("db_notifier.pooled_connection")
    def test_explicit_expected_pid_overrides_getpid(self, mock_pooled):
        """The expected_pid parameter overrides os.getpid() in the query."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        explicit_pid = 12345
        result = db_notifier.notify_report_stopped("test-uuid-explicit", expected_pid=explicit_pid, execution_token=TOKEN)

        self.assertTrue(result)

        executed_params = mock_cur.execute.call_args[0][1]
        self.assertEqual(executed_params, ("test-uuid-explicit", explicit_pid, TOKEN))

    @patch("db_notifier.pooled_connection")
    def test_defaults_to_current_pid(self, mock_pooled):
        """When expected_pid is omitted, os.getpid() is used."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        result = db_notifier.notify_report_stopped("test-uuid-default", execution_token=TOKEN)

        executed_params = mock_cur.execute.call_args[0][1]
        self.assertEqual(executed_params[1], os.getpid())

    @patch("db_notifier.pooled_connection")
    def test_exception_returns_false(self, mock_pooled):
        """Database errors are caught and return False."""
        mock_pooled.side_effect = Exception("connection failed")

        result = db_notifier.notify_report_stopped("test-uuid-err", execution_token=TOKEN)
        self.assertFalse(result)

    @patch("db_notifier.pooled_connection")
    def test_forked_child_pid_mismatch(self, mock_pooled):
        """Simulates a forked child: different PID means rowcount=0."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0)
        mock_pooled.return_value = mock_conn

        # Simulate child with PID different from the parent's stored PID
        parent_pid = os.getpid()
        child_pid = parent_pid + 1  # Would be different after fork

        result = db_notifier.notify_report_stopped("test-uuid-fork", expected_pid=child_pid, execution_token=TOKEN)

        self.assertFalse(result)
        executed_sql = mock_cur.execute.call_args[0][0]
        executed_params = mock_cur.execute.call_args[0][1]
        self.assertIn("AND pid = %s", executed_sql)
        self.assertEqual(executed_params, ("test-uuid-fork", child_pid, TOKEN))


class TestNotifyReportStoppedCleanupWebConfig(unittest.TestCase):
    """cleanup_web_config=True classifies ownership and deletes the UUID-keyed
    credential file inside the same locked transaction, instead of as a second,
    separately-racing step. Between an unlocked check and an unlocked delete, a
    replacement attempt could claim the report and write a fresh credential file
    that this process then deletes out from under it.
    """

    def _make_mock_conn(self, rowcount=1, fetchone=None):
        mock_cur = MagicMock()
        mock_cur.rowcount = rowcount
        mock_cur.fetchone.return_value = fetchone
        mock_cur.__enter__ = MagicMock(return_value=mock_cur)
        mock_cur.__exit__ = MagicMock(return_value=False)

        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)

        return mock_conn, mock_cur

    @patch("db_notifier.pooled_connection")
    def test_deletes_the_credential_file_under_the_row_lock(self, mock_pooled):
        """No other execution token owns the report: delete under the lock."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1, fetchone=(TOKEN,))
        mock_pooled.return_value = mock_conn

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp)
            web_config = config_path / "cleanup-owner_web.json"
            web_config.write_text('{"cookies": [{"value": "secret"}]}')

            with patch.object(db_notifier, "CONFIG_PATH", config_path):
                result = db_notifier.notify_report_stopped(
                    "cleanup-owner", execution_token=TOKEN, cleanup_web_config=True
                )

            self.assertTrue(result)
            self.assertFalse(web_config.exists(), "credential web config left on disk")

        select_sql = mock_cur.execute.call_args_list[0].args[0]
        self.assertIn("FOR UPDATE", select_sql)

    @patch("db_notifier.pooled_connection")
    def test_preserves_the_file_when_a_different_token_owns_the_report(self, mock_pooled):
        """A different, non-null execution token means a replacement attempt owns
        the report -- and therefore the UUID-keyed file this process was about to
        delete. Leave it in place."""
        replacement_token = "99999999-9999-4999-8999-999999999999"
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0, fetchone=(replacement_token,))
        mock_pooled.return_value = mock_conn

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp)
            web_config = config_path / "cleanup-replaced_web.json"
            web_config.write_text('{"cookies": [{"value": "secret"}]}')

            with patch.object(db_notifier, "CONFIG_PATH", config_path):
                result = db_notifier.notify_report_stopped(
                    "cleanup-replaced", execution_token=TOKEN, cleanup_web_config=True
                )

            self.assertFalse(result)
            self.assertTrue(
                web_config.exists(),
                "a superseded process deleted the replacement's live credential file",
            )

    @patch("db_notifier.pooled_connection")
    def test_deletes_the_file_when_ownership_was_already_released(self, mock_pooled):
        """A NULL stored token (Rails revoked it, nobody has replaced it yet) is not
        a replacement -- this is the ordinary "PID no longer matches" case, and
        nothing else will ever remove the file."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=0, fetchone=(None,))
        mock_pooled.return_value = mock_conn

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp)
            web_config = config_path / "cleanup-released_web.json"
            web_config.write_text("{}")

            with patch.object(db_notifier, "CONFIG_PATH", config_path):
                result = db_notifier.notify_report_stopped(
                    "cleanup-released", execution_token=TOKEN, cleanup_web_config=True
                )

            self.assertFalse(result)
            self.assertFalse(web_config.exists(), "credential web config left on disk")

    @patch("db_notifier.pooled_connection")
    def test_locks_the_row_before_classifying_ownership(self, mock_pooled):
        """The SELECT that decides keep-vs-delete takes FOR UPDATE on the report's
        own row, closing the window a replacement could otherwise use to claim the
        report and write a fresh credential file between an unlocked check and the
        delete."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1, fetchone=(TOKEN,))
        mock_pooled.return_value = mock_conn

        with patch.object(db_notifier, "CONFIG_PATH", Path(tempfile.mkdtemp())):
            db_notifier.notify_report_stopped(
                "cleanup-lock", execution_token=TOKEN, cleanup_web_config=True
            )

        select_sql, select_params = mock_cur.execute.call_args_list[0].args
        self.assertIn("SELECT", select_sql)
        self.assertIn("FOR UPDATE", select_sql)
        self.assertEqual(select_params, ("cleanup-lock",))

    @patch("db_notifier.pooled_connection")
    def test_skips_the_lock_and_delete_when_cleanup_not_requested(self, mock_pooled):
        """Existing callers that don't ask for cleanup keep the original
        single-statement behaviour: no SELECT, no file classification."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1)
        mock_pooled.return_value = mock_conn

        db_notifier.notify_report_stopped("no-cleanup", execution_token=TOKEN)

        self.assertEqual(mock_cur.execute.call_count, 1)

    @patch("db_notifier.pooled_connection")
    def test_cleanup_failure_is_indeterminate(self, mock_pooled):
        """A failed credential deletion must not be reported as a clean release."""
        mock_conn, mock_cur = self._make_mock_conn(rowcount=1, fetchone=(TOKEN,))
        mock_pooled.return_value = mock_conn

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp)
            with patch.object(db_notifier, "CONFIG_PATH", config_path), \
                 patch.object(Path, "unlink", side_effect=PermissionError("denied")):
                result = db_notifier.notify_report_stopped(
                    "cleanup-error", execution_token=TOKEN, cleanup_web_config=True
                )

        self.assertIsNone(result)
        mock_conn.commit.assert_not_called()


if __name__ == "__main__":
    unittest.main()
