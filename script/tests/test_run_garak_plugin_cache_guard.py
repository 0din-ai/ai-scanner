#!/usr/bin/env python3
"""Regression tests for run_garak plugin-cache guard installation."""

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
_mock_db.CONFIG_PATH = Path("/tmp/fake_config")

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


class TestRunGarakPluginCacheGuard(unittest.TestCase):
    def setUp(self):
        self.original_garak = sys.modules.get("garak")
        self.original_garak_main = sys.modules.get("garak.__main__")

        garak = ModuleType("garak")
        garak.__path__ = []
        garak_main = ModuleType("garak.__main__")
        garak_main.main = MagicMock(return_value=0)
        sys.modules["garak"] = garak
        sys.modules["garak.__main__"] = garak_main

    def tearDown(self):
        if self.original_garak is None:
            sys.modules.pop("garak", None)
        else:
            sys.modules["garak"] = self.original_garak

        if self.original_garak_main is None:
            sys.modules.pop("garak.__main__", None)
        else:
            sys.modules["garak.__main__"] = self.original_garak_main

    def test_run_garak_scan_installs_plugin_cache_guard_before_main(self):
        calls = []

        def guard():
            calls.append("guard")

        def garak_main():
            calls.append("main")
            return 0

        sys.modules["garak.__main__"].main = garak_main

        with patch.object(run_garak, "install_plugin_cache_guard", side_effect=guard) as guard_mock:
            exit_code = run_garak.run_garak_scan(["--list_probes"])

        self.assertEqual(0, exit_code)
        guard_mock.assert_called_once_with()
        self.assertEqual(["guard", "main"], calls)


if __name__ == "__main__":
    unittest.main()
