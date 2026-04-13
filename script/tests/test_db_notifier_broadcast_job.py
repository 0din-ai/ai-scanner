#!/usr/bin/env python3
"""
Regression tests for BroadcastRunningStatsJob enqueueing from db_notifier.
"""

import json
import os
import sys
import unittest
from types import ModuleType
from unittest.mock import MagicMock, patch

# Stub psycopg2 before importing db_notifier
_mock_psycopg2 = ModuleType("psycopg2")
_mock_psycopg2.OperationalError = type("OperationalError", (Exception,), {})
_mock_psycopg2.pool = ModuleType("psycopg2.pool")
_mock_psycopg2.pool.ThreadedConnectionPool = MagicMock
sys.modules.setdefault("psycopg2", _mock_psycopg2)
sys.modules.setdefault("psycopg2.pool", _mock_psycopg2.pool)

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

if "db_notifier" in sys.modules:
    cached = sys.modules["db_notifier"]
    if not hasattr(cached, "pooled_connection"):
        del sys.modules["db_notifier"]

import db_notifier  # noqa: E402


class TestNotifyReportRunningBroadcastJob(unittest.TestCase):
    def _make_mock_conn(self, rowcount=1, fetchone_result=None):
        mock_cur = MagicMock()
        mock_cur.rowcount = rowcount
        mock_cur.fetchone.return_value = fetchone_result
        mock_cur.__enter__ = MagicMock(return_value=mock_cur)
        mock_cur.__exit__ = MagicMock(return_value=False)

        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)

        return mock_conn, mock_cur

    @patch("db_notifier.pooled_connection")
    def test_notify_report_running_enqueues_company_scoped_broadcast_job(self, mock_pooled):
        primary_conn, primary_cur = self._make_mock_conn(
            rowcount=1,
            fetchone_result=(17,),
        )
        queue_conn, queue_cur = self._make_mock_conn(fetchone_result=(123,))
        mock_pooled.side_effect = [primary_conn, queue_conn]

        result = db_notifier.notify_report_running("report-uuid", pid=456)

        self.assertTrue(result)

        update_sql, update_params = primary_cur.execute.call_args[0]
        self.assertIn("RETURNING company_id", update_sql)
        self.assertEqual(update_params, (db_notifier.REPORT_STATUS_RUNNING, 456, "report-uuid"))

        insert_sql, insert_params = queue_cur.execute.call_args_list[0][0]
        arguments_payload = json.loads(insert_params[1])

        self.assertIn("concurrency_key", insert_sql)
        self.assertEqual(arguments_payload["job_class"], "BroadcastRunningStatsJob")
        self.assertEqual(arguments_payload["arguments"], [17])
        self.assertEqual(insert_params[5], "BroadcastRunningStatsJob/broadcast_running_stats:17")


if __name__ == "__main__":
    unittest.main()
