#!/usr/bin/env python3
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from exportlib.config import DatabasePathError, default_db, readonly_db_uri


class ExportPathTests(unittest.TestCase):
    def test_database_environment_override_wins(self):
        with patch.dict(os.environ, {"OPENCODE_DB": r"C:\OpenCode\data.db"}, clear=True):
            self.assertEqual(default_db(), r"C:\OpenCode\data.db")

    def test_windows_database_path_comes_from_opencode_cli(self):
        result = subprocess_result(
            returncode=0,
            stdout=r"C:\Users\test\AppData\Local\opencode\opencode.db" + "\r\n",
        )
        with (
            patch("exportlib.config.sys.platform", "win32"),
            patch.dict(os.environ, {}, clear=True),
            patch("exportlib.config.subprocess.run", return_value=result) as run,
        ):
            self.assertEqual(default_db(), r"C:\Users\test\AppData\Local\opencode\opencode.db")
        run.assert_called_once_with(
            "opencode debug paths db",
            shell=True,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_windows_path_resolution_failure_is_explicit(self):
        result = subprocess_result(returncode=1, stderr="unknown command")
        with (
            patch("exportlib.config.sys.platform", "win32"),
            patch.dict(os.environ, {}, clear=True),
            patch("exportlib.config.subprocess.run", return_value=result),
        ):
            with self.assertRaisesRegex(DatabasePathError, "set OPENCODE_DB"):
                default_db()

    def test_readonly_uri_opens_database_without_write_access(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "database with spaces.db"
            with sqlite3.connect(path) as con:
                con.execute("CREATE TABLE sample (value TEXT)")
            with sqlite3.connect(readonly_db_uri(path), uri=True) as con:
                self.assertEqual(con.execute("SELECT count(*) FROM sample").fetchone()[0], 0)
                with self.assertRaises(sqlite3.OperationalError):
                    con.execute("INSERT INTO sample VALUES ('not allowed')")


def subprocess_result(returncode=0, stdout="", stderr=""):
    class Result:
        pass

    result = Result()
    result.returncode = returncode
    result.stdout = stdout
    result.stderr = stderr
    return result


if __name__ == "__main__":
    unittest.main()
