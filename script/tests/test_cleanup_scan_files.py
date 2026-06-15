"""cleanup_scan_files must always delete the credential-bearing _web.json,
even in debug mode (it contains cookies/headers/storageState)."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

mock_psycopg2 = MagicMock()
mock_psycopg2.OperationalError = Exception
mock_psycopg2.pool = MagicMock()
sys.modules["psycopg2"] = mock_psycopg2
sys.modules["psycopg2.pool"] = mock_psycopg2.pool

_script_dir = str(Path(__file__).resolve().parent.parent)
if _script_dir not in sys.path:
    sys.path.insert(0, _script_dir)

import db_notifier  # noqa: E402


class TestCleanupScanFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        (self.base / "config").mkdir()
        (self.base / "reports").mkdir()
        self.uuid = "abc-123"
        self.web = self.base / "config" / f"{self.uuid}_web.json"
        self.yml = self.base / "config" / f"{self.uuid}.yml"
        self.web.write_text("{}")
        self.yml.write_text("{}")

    def tearDown(self):
        self.tmp.cleanup()

    def test_web_config_deleted_even_in_debug(self):
        with patch.object(db_notifier, "CONFIG_PATH", self.base / "config"), \
             patch.object(db_notifier, "REPORTS_PATH", self.base / "reports"), \
             patch.object(db_notifier, "is_debug_mode", return_value=True), \
             patch.object(db_notifier, "get_log_file_path", return_value=self.base / "x.log"):
            db_notifier.cleanup_scan_files(self.uuid)

        self.assertFalse(self.web.exists(), "_web.json must be deleted even in debug mode")
        self.assertTrue(self.yml.exists(), ".yml should be preserved in debug mode")


if __name__ == "__main__":
    unittest.main()
