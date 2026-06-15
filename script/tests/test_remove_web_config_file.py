"""run_garak.remove_web_config_file deletes the credential web-config file."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Stub heavy/optional imports that run_garak pulls in at module load, if needed.
mock_psycopg2 = MagicMock()
mock_psycopg2.OperationalError = Exception
mock_psycopg2.pool = MagicMock()
sys.modules.setdefault("psycopg2", mock_psycopg2)
sys.modules.setdefault("psycopg2.pool", mock_psycopg2.pool)

# db_notifier touches PostgreSQL at import; stub the whole module so run_garak
# can be imported without a live database.  We must set REPORTS_PATH and
# CONFIG_PATH so the names bound by `from db_notifier import (...)` resolve.
import os
os.environ.setdefault("ELASTIC_APM_ENABLED", "false")

mock_db_notifier = MagicMock()
mock_db_notifier.REPORTS_PATH = Path("/tmp/fake_reports")
mock_db_notifier.CONFIG_PATH = Path("/tmp/fake_config")
sys.modules.setdefault("db_notifier", mock_db_notifier)

# garak_plugin_cache_guard is only present inside the dev container; stub it too.
mock_garak_plugin_cache_guard = MagicMock()
sys.modules.setdefault("garak_plugin_cache_guard", mock_garak_plugin_cache_guard)

_script_dir = str(Path(__file__).resolve().parent.parent)
if _script_dir not in sys.path:
    sys.path.insert(0, _script_dir)

import run_garak  # noqa: E402


class TestRemoveWebConfigFile(unittest.TestCase):
    def test_deletes_web_config_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            uuid = "abc-123"
            web = cfg / f"{uuid}_web.json"
            web.write_text("{}")
            with patch.object(run_garak, "CONFIG_PATH", cfg):
                run_garak.remove_web_config_file(uuid)
            self.assertFalse(web.exists())

    def test_is_safe_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(run_garak, "CONFIG_PATH", Path(tmp)):
                run_garak.remove_web_config_file("nope")  # must not raise


class TestSignalHandlerCleanup(unittest.TestCase):
    def test_main_process_removes_web_config_on_signal(self):
        # An early SIGTERM (before the main try/finally) must still delete the
        # credential file from the parent signal handler.
        with patch.object(run_garak, "_main_pid", os.getpid()), \
             patch.object(run_garak, "current_report_uuid", "uuid-xyz"), \
             patch.object(run_garak, "current_journal_sync", None), \
             patch.object(run_garak, "current_heartbeat", None), \
             patch.object(run_garak, "notify_report_stopped") as m_stop, \
             patch.object(run_garak, "remove_web_config_file") as m_rm:
            with self.assertRaises(SystemExit):
                run_garak.signal_handler(15, None)
        m_stop.assert_called_once_with("uuid-xyz")
        m_rm.assert_called_once_with("uuid-xyz")


if __name__ == "__main__":
    unittest.main()
