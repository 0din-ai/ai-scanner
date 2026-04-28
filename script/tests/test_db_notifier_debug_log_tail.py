#!/usr/bin/env python3
"""
Tests for JournalSyncThread live execution log tail syncing.
"""

import importlib
import os
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

# Stub psycopg2 before importing db_notifier.
_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = type("OperationalError", (Exception,), {})
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
_mock_psycopg2.pool.ThreadedConnectionPool = MagicMock
sys.modules["psycopg2"] = _mock_psycopg2
sys.modules["psycopg2.pool"] = _mock_psycopg2.pool

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

cached_db_notifier = sys.modules.get("db_notifier")
if cached_db_notifier is not None and (
    isinstance(cached_db_notifier, MagicMock)
    or not hasattr(cached_db_notifier, "JournalSyncThread")
):
    del sys.modules["db_notifier"]

import db_notifier  # noqa: E402


class TestDebugLogTailBytesConfig(unittest.TestCase):
    def setUp(self):
        self.original_tail_bytes_env = os.environ.get("DEBUG_LOG_TAIL_BYTES")

    def tearDown(self):
        if self.original_tail_bytes_env is None:
            os.environ.pop("DEBUG_LOG_TAIL_BYTES", None)
        else:
            os.environ["DEBUG_LOG_TAIL_BYTES"] = self.original_tail_bytes_env
        self._reload_db_notifier()

    def _reload_with_tail_bytes(self, value):
        if value is None:
            os.environ.pop("DEBUG_LOG_TAIL_BYTES", None)
        else:
            os.environ["DEBUG_LOG_TAIL_BYTES"] = value
        return self._reload_db_notifier()

    def _reload_db_notifier(self):
        sys.modules["psycopg2"] = _mock_psycopg2
        sys.modules["psycopg2.pool"] = _mock_psycopg2.pool
        sys.modules["db_notifier"] = db_notifier
        return importlib.reload(db_notifier)

    def test_import_defaults_for_malformed_tail_byte_values(self):
        for value in ("", "128k", "-1"):
            with self.subTest(value=value):
                with self.assertLogs("db_notifier", level="WARNING"):
                    module = self._reload_with_tail_bytes(value)

                self.assertEqual(
                    module.DEBUG_LOG_TAIL_BYTES,
                    module.DEFAULT_DEBUG_LOG_TAIL_BYTES,
                )

    def test_import_defaults_when_tail_byte_value_is_missing(self):
        module = self._reload_with_tail_bytes(None)

        self.assertEqual(
            module.DEBUG_LOG_TAIL_BYTES,
            module.DEFAULT_DEBUG_LOG_TAIL_BYTES,
        )

    def test_import_preserves_zero_tail_byte_value(self):
        module = self._reload_with_tail_bytes("0")

        self.assertEqual(module.DEBUG_LOG_TAIL_BYTES, 0)


class RecordingCursor:
    def __init__(self, report_id=42):
        self.report_id = report_id
        self.execute_calls = []
        self._last_sql = ""

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def execute(self, sql, params=None):
        self.execute_calls.append((sql, params))
        self._last_sql = sql

    def fetchone(self):
        if "SELECT id FROM reports" in self._last_sql:
            return (self.report_id,)
        if "SELECT 1 FROM raw_report_data" in self._last_sql:
            return (1,)
        if "UPDATE reports" in self._last_sql and "RETURNING id, company_id" in self._last_sql:
            return (self.report_id, 7)
        return None

    def reset(self):
        self.execute_calls = []
        self._last_sql = ""


class FailingTailCursor(RecordingCursor):
    def execute(self, sql, params=None):
        if "INSERT INTO report_debug_logs" in sql:
            self.execute_calls.append((sql, params))
            self._last_sql = sql
            raise RuntimeError("tail table unavailable")

        super().execute(sql, params)


class RecordingConnection:
    def __init__(self, cursor):
        self.cursor_obj = cursor
        self.autocommit = True
        self.commit_count = 0
        self.rollback_count = 0

    def cursor(self):
        return self.cursor_obj

    def commit(self):
        self.commit_count += 1

    def rollback(self):
        self.rollback_count += 1

    def reset(self):
        self.cursor_obj.reset()
        self.commit_count = 0
        self.rollback_count = 0


class TestJournalSyncDebugLogTail(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)
        self.jsonl_path = self.root / "report.report.jsonl"
        self.log_path = self.root / "report.log"
        self.old_tail_bytes = db_notifier.DEBUG_LOG_TAIL_BYTES
        db_notifier.DEBUG_LOG_TAIL_BYTES = 1024

    def tearDown(self):
        db_notifier.DEBUG_LOG_TAIL_BYTES = self.old_tail_bytes

    def _thread(self):
        return db_notifier.JournalSyncThread(
            "report-uuid",
            self.jsonl_path,
            log_path=self.log_path,
        )

    def _patch_pooled_connection(self, conn):
        @contextmanager
        def fake_pooled_connection(database="primary"):
            yield conn

        return patch.object(db_notifier, "pooled_connection", fake_pooled_connection)

    def _sql_calls_containing(self, cursor, fragment):
        return [
            (sql, params)
            for sql, params in cursor.execute_calls
            if fragment in sql
        ]

    def test_missing_log_file_keeps_jsonl_sync_without_debug_log_upsert(self):
        self.jsonl_path.write_text('{"entry_type":"init"}\n', encoding="utf-8")
        sync = self._thread()
        cursor = RecordingCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO raw_report_data")), 1)
        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")), 0)

    def test_first_tail_sync_upserts_report_debug_logs_without_jsonl(self):
        self.log_path.write_text("line one\n", encoding="utf-8")
        sync = self._thread()
        cursor = RecordingCursor(report_id=123)
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        debug_calls = self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")
        self.assertEqual(len(debug_calls), 1)
        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO raw_report_data")), 0)

        normalized_sql = " ".join(debug_calls[0][0].split())
        self.assertIn("(report_id, tail, tail_offset, tail_digest,", normalized_sql)
        self.assertNotIn("logs = EXCLUDED.logs", normalized_sql)
        self.assertNotIn(" logs,", normalized_sql)

        params = debug_calls[0][1]
        self.assertEqual(params[0], 123)
        self.assertEqual(params[1], "line one\n")
        self.assertEqual(params[2], 0)
        self.assertIsInstance(params[3], str)
        self.assertFalse(params[5])

    def test_unchanged_tail_digest_skips_database_write(self):
        self.log_path.write_text("same tail\n", encoding="utf-8")
        sync = self._thread()
        cursor = RecordingCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        conn.reset()

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        self.assertEqual(cursor.execute_calls, [])
        self.assertEqual(conn.commit_count, 0)

    def test_changed_tail_updates_when_jsonl_is_unchanged(self):
        self.jsonl_path.write_text('{"entry_type":"init"}\n', encoding="utf-8")
        self.log_path.write_text("first\n", encoding="utf-8")
        sync = self._thread()
        cursor = RecordingCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        conn.reset()
        self.log_path.write_text("first\nsecond\n", encoding="utf-8")

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        debug_calls = self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")
        raw_calls = self._sql_calls_containing(cursor, "INSERT INTO raw_report_data")
        self.assertEqual(len(debug_calls), 1)
        self.assertEqual(len(raw_calls), 0)
        self.assertEqual(debug_calls[0][1][1], "first\nsecond\n")

    def test_tail_sync_failure_does_not_rollback_jsonl_sync(self):
        self.jsonl_path.write_text('{"entry_type":"init"}\n', encoding="utf-8")
        self.log_path.write_text("live tail\n", encoding="utf-8")
        sync = self._thread()
        cursor = FailingTailCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn), \
             self.assertLogs("db_notifier", level="WARNING") as logs:
            self.assertTrue(sync._sync())

        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO raw_report_data")), 1)
        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")), 1)
        self.assertEqual(conn.commit_count, 1)
        self.assertEqual(conn.rollback_count, 1)
        self.assertEqual(sync._last_synced_content, '{"entry_type":"init"}\n')
        self.assertIsNone(sync._last_synced_tail_digest)
        self.assertIn("failed to sync log tail", "\n".join(logs.output))

    def test_tail_only_sync_failure_counts_as_failed_sync(self):
        self.log_path.write_text("tail without jsonl\n", encoding="utf-8")
        sync = self._thread()
        cursor = FailingTailCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn), \
             self.assertLogs("db_notifier", level="WARNING") as logs:
            self.assertFalse(sync._sync())

        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO raw_report_data")), 0)
        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")), 1)
        self.assertEqual(conn.commit_count, 0)
        self.assertEqual(conn.rollback_count, 1)
        self.assertIsNone(sync._last_synced_tail_digest)
        self.assertIn("failed to sync log tail", "\n".join(logs.output))

    def test_tail_reader_truncates_to_last_configured_bytes_and_reports_offset(self):
        db_notifier.DEBUG_LOG_TAIL_BYTES = 10
        self.log_path.write_bytes(b"0123456789abcdef")
        sync = self._thread()

        payload = sync._read_debug_log_tail()

        self.assertEqual(payload["tail"], "6789abcdef")
        self.assertEqual(payload["offset"], 6)
        self.assertTrue(payload["truncated"])
        self.assertIsInstance(payload["digest"], str)

    def test_tail_reader_strips_nul_bytes_and_decodes_with_replacement(self):
        self.log_path.write_bytes(b"a\x00b\xffc")
        sync = self._thread()

        payload = sync._read_debug_log_tail()

        self.assertEqual(payload["tail"], "ab\ufffdc")
        self.assertFalse(payload["truncated"])

    def test_tail_reader_zero_limit_does_not_read_tail_bytes(self):
        db_notifier.DEBUG_LOG_TAIL_BYTES = 0
        self.log_path.write_text("hidden live output", encoding="utf-8")
        sync = self._thread()

        payload = sync._read_debug_log_tail()

        self.assertIsNone(payload)

    def test_zero_tail_limit_disables_debug_log_upsert(self):
        db_notifier.DEBUG_LOG_TAIL_BYTES = 0
        self.log_path.write_text("hidden live output", encoding="utf-8")
        sync = self._thread()
        cursor = RecordingCursor()
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn):
            self.assertTrue(sync._sync())

        self.assertEqual(len(self._sql_calls_containing(cursor, "INSERT INTO report_debug_logs")), 0)
        self.assertEqual(cursor.execute_calls, [])
        self.assertEqual(conn.commit_count, 0)

    def test_notify_report_running_clears_live_tail_without_erasing_final_logs(self):
        cursor = RecordingCursor(report_id=123)
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn), \
             patch.object(db_notifier, "_enqueue_broadcast_stats_job", return_value="job-id"):
            self.assertTrue(db_notifier.notify_report_running("report-uuid", 456))

        tail_reset_calls = self._sql_calls_containing(cursor, "UPDATE report_debug_logs")
        self.assertEqual(len(tail_reset_calls), 1)
        normalized_sql = " ".join(tail_reset_calls[0][0].split())
        self.assertNotIn("logs = NULL", normalized_sql)
        self.assertIn("tail = NULL", normalized_sql)
        self.assertIn("tail_offset = 0", normalized_sql)
        self.assertIn("tail_digest = NULL", normalized_sql)
        self.assertIn("tail_synced_at = NULL", normalized_sql)
        self.assertIn("tail_truncated = FALSE", normalized_sql)
        self.assertEqual(tail_reset_calls[0][1], (123,))

    def test_notify_report_ready_from_synced_clears_raw_logs_when_log_file_missing(self):
        cursor = RecordingCursor(report_id=123)
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn), \
             patch.object(db_notifier, "get_log_file_path", return_value=self.log_path), \
             patch.object(db_notifier, "_enqueue_process_report_job", return_value="job-id"), \
             patch.object(db_notifier, "cleanup_scan_files"):
            self.assertTrue(db_notifier.notify_report_ready_from_synced("report-uuid"))

        raw_log_updates = self._sql_calls_containing(cursor, "UPDATE raw_report_data")
        self.assertEqual(len(raw_log_updates), 1)
        self.assertIsNone(raw_log_updates[0][1][0])
        self.assertEqual(raw_log_updates[0][1][2], 123)

    def test_notify_report_ready_from_synced_reads_and_sanitizes_log_file(self):
        self.log_path.write_bytes(b"first line\nnul\x00 stripped\n")
        cursor = RecordingCursor(report_id=123)
        conn = RecordingConnection(cursor)

        with self._patch_pooled_connection(conn), \
             patch.object(db_notifier, "get_log_file_path", return_value=self.log_path), \
             patch.object(db_notifier, "_enqueue_process_report_job", return_value="job-id"), \
             patch.object(db_notifier, "cleanup_scan_files"):
            self.assertTrue(db_notifier.notify_report_ready_from_synced("report-uuid"))

        raw_log_updates = self._sql_calls_containing(cursor, "UPDATE raw_report_data")
        self.assertEqual(len(raw_log_updates), 1)
        params = raw_log_updates[0][1]
        self.assertEqual(params[0], "first line\nnul stripped\n")
        self.assertIsNotNone(params[1])
        self.assertEqual(params[2], 123)


if __name__ == "__main__":
    unittest.main()
