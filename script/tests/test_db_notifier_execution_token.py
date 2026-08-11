#!/usr/bin/env python3
"""
Tests for execution-token fencing in db_notifier.

A PID is local to a container. When a worker pod is drained and replaced, the
replacement can be handed the same PID, so a PID match cannot prove that the
process writing is the process that was started for this attempt. Rails mints an
execution token when it claims a scan and revokes it whenever the attempt ends;
every write the scanner makes is fenced on that token, so a superseded process
writes nothing.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub psycopg2 before importing db_notifier
# ---------------------------------------------------------------------------
_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = type("OperationalError", (Exception,), {})
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
_mock_psycopg2.pool.ThreadedConnectionPool = MagicMock
sys.modules.setdefault("psycopg2", _mock_psycopg2)
sys.modules.setdefault("psycopg2.pool", _mock_psycopg2.pool)

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

# Another test module may have cached a lightweight db_notifier mock; force the
# real module so these tests exercise the actual SQL.
if "db_notifier" in sys.modules:
    cached = sys.modules["db_notifier"]
    if not hasattr(cached, "pooled_connection"):
        del sys.modules["db_notifier"]
        _pool_mod = sys.modules.get("psycopg2.pool")
        if _pool_mod and not hasattr(_pool_mod, "ThreadedConnectionPool"):
            _pool_mod.ThreadedConnectionPool = MagicMock

import db_notifier  # noqa: E402

TOKEN = "11111111-2222-3333-4444-555555555555"
UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def make_conn(fetchone=None, rowcount=1):
    cur = MagicMock()
    cur.rowcount = rowcount
    cur.fetchone.return_value = fetchone
    cur.__enter__ = MagicMock(return_value=cur)
    cur.__exit__ = MagicMock(return_value=False)

    conn = MagicMock()
    conn.cursor.return_value = cur
    conn.__enter__ = MagicMock(return_value=conn)
    conn.__exit__ = MagicMock(return_value=False)
    return conn, cur


def executed(cur):
    """All (sql, params) pairs passed to cursor.execute."""
    return [(c.args[0], c.args[1] if len(c.args) > 1 else ()) for c in cur.execute.call_args_list]


def statement_matching(cur, needle):
    for sql, params in executed(cur):
        if needle in sql:
            return sql, params
    return None, None


class TestNotifyReportRunning(unittest.TestCase):
    def test_claims_only_the_attempt_it_was_started_for(self):
        conn, cur = make_conn(fetchone=(7, 3))

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            db_notifier.notify_report_running(UUID, 4321, TOKEN)

        sql, params = statement_matching(cur, "UPDATE reports")
        self.assertIn("execution_token = %s", sql)
        # Only a report Rails has claimed and not yet revoked may be taken over.
        self.assertIn("status = %s", sql)
        self.assertIn(TOKEN, params)
        self.assertIn(db_notifier.REPORT_STATUS_STARTING, params)

    def test_reports_failure_when_the_attempt_was_superseded(self):
        conn, _ = make_conn(fetchone=None, rowcount=0)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            result = db_notifier.notify_report_running(UUID, 4321, TOKEN)

        self.assertFalse(result)


class TestNotifyReportStopped(unittest.TestCase):
    def test_releases_only_a_matching_attempt(self):
        conn, cur = make_conn(rowcount=1)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            result = db_notifier.notify_report_stopped(UUID, execution_token=TOKEN)

        sql, params = statement_matching(cur, "UPDATE reports")
        self.assertIn("execution_token = %s", sql)
        self.assertIn("execution_token = NULL", sql)
        self.assertIn(TOKEN, params)
        self.assertTrue(result)

    def test_clears_nothing_when_the_token_no_longer_matches(self):
        conn, _ = make_conn(rowcount=0)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            result = db_notifier.notify_report_stopped(UUID, execution_token=TOKEN)

        self.assertFalse(result)

    def test_still_honours_the_explicit_pid_guard(self):
        conn, cur = make_conn(rowcount=1)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            db_notifier.notify_report_stopped(UUID, expected_pid=999, execution_token=TOKEN)

        _, params = statement_matching(cur, "UPDATE reports")
        self.assertIn(999, params)


class TestRevokedButStillAlive(unittest.TestCase):
    """Revoked is not the same as superseded.

    Rails revokes the token whenever an attempt ends -- including while the garak
    process is still running (a stop, or the stale reaper firing on a lapsed
    heartbeat). That process must still be able to release its own PID and flush
    what it has: nobody else owns the report. Only a *replacement* attempt, which
    is a different non-null token, may block those writes.
    """

    def test_stopped_releases_the_pid_after_its_token_was_revoked(self):
        conn, cur = make_conn(rowcount=1)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            db_notifier.notify_report_stopped(UUID, execution_token=TOKEN)

        sql, _ = statement_matching(cur, "UPDATE reports")
        # Otherwise a stopped report keeps a pid pointing at a dead process, and a
        # replacement pod can be handed that same pid.
        self.assertIn("execution_token IS NULL", sql)

    def test_journal_sync_flushes_after_its_token_was_revoked(self):
        conn, cur = make_conn(fetchone=(7,))
        thread = db_notifier.JournalSyncThread(
            UUID, Path("/tmp/does-not-matter.jsonl"), execution_token=TOKEN
        )

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            self.assertEqual(thread._load_report_id(), 7)

        sql, _ = statement_matching(cur, "SELECT id FROM reports")
        # The final flush on SIGTERM happens after Rails has already revoked; the
        # old unconditional lookup always persisted it.
        self.assertIn("execution_token IS NULL", sql)

    def test_completion_is_allowed_after_its_token_was_revoked(self):
        conn, cur = make_conn(fetchone=None)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            db_notifier.notify_report_ready_from_synced(
                UUID, exit_code=0, execution_token=TOKEN
            )

        sql, _ = statement_matching(cur, "SELECT id FROM reports")
        self.assertIn("execution_token IS NULL", sql)
        # ...and the row is held for the rest of the transaction, so a replacement
        # cannot claim it between this check and the writes that follow.
        self.assertIn("FOR UPDATE", sql)


class TestRevokedWritesAreScopedByStatus(unittest.TestCase):
    """A revoked token alone is not enough to justify writing.

    Reports::Stop sets the report to `stopped` with a NULL token and then
    Reports::Cleanup deletes its raw_report_data. The scanner notices a heartbeat
    later and flushes -- which would upsert the prompts and outputs the user just
    cancelled straight back, with nothing left to remove them again. The completion
    paths would additionally enqueue processing for a cancelled report.
    """

    def _assert_scoped(self, sql, params):
        self.assertIsNotNone(sql, "expected a report ownership lookup")
        self.assertIn("execution_token IS NULL", sql)
        self.assertIn("status = ANY", sql)
        lists = [p for p in params if isinstance(p, (list, tuple))]
        self.assertEqual(len(lists), 1, "expected a status allowlist parameter")
        allowed = list(lists[0])
        self.assertIn(db_notifier.REPORT_STATUS_RUNNING, allowed)
        self.assertIn(db_notifier.REPORT_STATUS_INTERRUPTED, allowed)
        self.assertNotIn(db_notifier.REPORT_STATUS_STOPPED, allowed)
        self.assertNotIn(db_notifier.REPORT_STATUS_FAILED, allowed)
        self.assertNotIn(db_notifier.REPORT_STATUS_PROCESSING, allowed)

    def test_journal_flush_is_scoped(self):
        conn, cur = make_conn(fetchone=(7,))
        thread = db_notifier.JournalSyncThread(
            UUID, Path("/tmp/does-not-matter.jsonl"), execution_token=TOKEN
        )

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            thread._load_report_id()

        self._assert_scoped(*statement_matching(cur, "SELECT id FROM reports"))

    def test_completion_from_synced_is_scoped(self):
        conn, cur = make_conn(fetchone=None)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            db_notifier.notify_report_ready_from_synced(
                UUID, exit_code=0, execution_token=TOKEN
            )

        self._assert_scoped(*statement_matching(cur, "SELECT id FROM reports"))


class TestHeartbeat(unittest.TestCase):
    def test_heartbeat_is_fenced_on_the_attempt(self):
        conn, cur = make_conn(rowcount=1)
        heartbeat = db_notifier.HeartbeatThread(UUID, execution_token=TOKEN)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            heartbeat._send_heartbeat()

        sql, params = statement_matching(cur, "UPDATE reports")
        self.assertIn("execution_token = %s", sql)
        self.assertIn(TOKEN, params)

    def test_a_revoked_attempt_stops_heartbeating(self):
        # Zero rows means this process no longer owns the report; the thread
        # treats that as "status changed" and terminates the scan.
        conn, _ = make_conn(rowcount=0)
        heartbeat = db_notifier.HeartbeatThread(UUID, execution_token=TOKEN)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            # "error" also differs from "ok" but takes 3 cycles (~90s) to terminate;
            # only "not_running" self-terminates on the first cycle.
            self.assertEqual(heartbeat._send_heartbeat(), "not_running")


class TestCompletionHandoff(unittest.TestCase):
    def test_ready_from_synced_will_not_complete_a_superseded_attempt(self):
        conn, cur = make_conn(fetchone=None)

        with patch.object(db_notifier, "pooled_connection", return_value=conn):
            result = db_notifier.notify_report_ready_from_synced(
                UUID, exit_code=0, execution_token=TOKEN
            )

        sql, params = statement_matching(cur, "SELECT id FROM reports")
        self.assertIn("execution_token = %s", sql)
        self.assertIn(TOKEN, params)
        self.assertFalse(result)

    def test_ready_will_not_complete_a_superseded_attempt(self):
        conn, cur = make_conn(fetchone=None)

        # notify_report_ready reads the scan's files before touching the database,
        # so give it real ones and let it reach the ownership check.
        with tempfile.TemporaryDirectory() as tmp:
            reports_dir = Path(tmp)
            (reports_dir / f"{UUID}.report.jsonl").write_text("{}\n", encoding="utf-8")
            log_path = reports_dir / "scan.log"
            log_path.write_text("", encoding="utf-8")

            with patch.object(db_notifier, "REPORTS_PATH", reports_dir), \
                    patch.object(db_notifier, "get_log_file_path", return_value=log_path), \
                    patch.object(db_notifier, "pooled_connection", return_value=conn):
                result = db_notifier.notify_report_ready(
                    UUID, prefix="", exit_code=0, execution_token=TOKEN
                )

        sql, params = statement_matching(cur, "SELECT id FROM reports")
        self.assertIn("execution_token = %s", sql)
        self.assertIn(TOKEN, params)
        self.assertFalse(result)


if __name__ == "__main__":
    unittest.main()
