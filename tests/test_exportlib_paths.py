#!/usr/bin/env python3
import io
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from exportlib.chunking import chunk_markdown_file
from exportlib.config import (
    DatabasePathError,
    _REPO_ROOT,
    default_db,
    default_out,
    default_presets,
    readonly_db_uri,
)
from exportlib.progress import Progress
from exportlib.util import yaml_frontmatter
from exportlib.writers import session_folder_name
from shrinklib.config import default_shrink_presets


class ExportPathTests(unittest.TestCase):
    def test_session_folder_uses_last_updated_utc_date_not_sequence_number(self):
        session = {
            "title": "Task name",
            "slug": "fallback",
            "id": "ses_123456789",
            "time_updated": int(
                datetime(2026, 6, 21, 0, 30, tzinfo=timezone.utc).timestamp() * 1000
            ),
        }
        with patch.dict(os.environ, {"TZ": "America/Los_Angeles"}):
            self.assertEqual(
                session_folder_name(session), "2026-06-21__Task-name_ses_1234"
            )

        session["time_updated"] = None
        self.assertEqual(
            session_folder_name(session), "unknown-date__Task-name_ses_1234"
        )
        session["time_updated"] = "not-a-timestamp"
        self.assertEqual(
            session_folder_name(session), "unknown-date__Task-name_ses_1234"
        )

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

    def test_checkout_defaults_use_repo_files_and_export_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            with (
                patch("exportlib.config.Path.home", return_value=home),
                patch("shrinklib.config.Path.home", return_value=home),
                patch.dict(os.environ, {}, clear=True),
            ):
                self.assertEqual(default_presets(), str(_REPO_ROOT / "presets.json"))
                self.assertEqual(
                    default_shrink_presets(), str(_REPO_ROOT / "shrink-presets.json")
                )
                self.assertEqual(default_out(), str(_REPO_ROOT / "exports"))

    def test_checkout_output_is_portable_even_if_user_conf_remains(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            user_conf = home / ".config" / "opencode-db" / "opencode-db.conf"
            user_conf.parent.mkdir(parents=True)
            user_conf.write_text("OCED_OUT=/some/old/install/path\n", encoding="utf-8")
            with (
                patch("exportlib.config.Path.home", return_value=home),
                patch.dict(os.environ, {}, clear=True),
            ):
                self.assertEqual(default_out(), str(_REPO_ROOT / "exports"))

    def test_output_environment_override_wins_over_checkout_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with (
                patch("exportlib.config.Path.home", return_value=Path(temp_dir)),
                patch.dict(os.environ, {"OCED_OUT": "/custom/exports"}, clear=True),
            ):
                self.assertEqual(default_out(), "/custom/exports")


class MarkdownFrontmatterTests(unittest.TestCase):
    def test_frontmatter_quotes_values_and_keeps_numeric_scalars(self):
        rendered = yaml_frontmatter({
            "title": 'Task: "finish"\nnext',
            "session_id": "ses_test",
            "messages": 3,
        })
        self.assertTrue(rendered.startswith("---\ntitle: "))
        self.assertIn('title: "Task: \\"finish\\"\\nnext"\n', rendered)
        self.assertIn('session_id: "ses_test"\n', rendered)
        self.assertIn("messages: 3\n", rendered)
        self.assertTrue(rendered.endswith("---\n\n"))

    def test_chunk_files_keep_frontmatter(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "session.md"
            metadata = {
                "title": "Session",
                "profile": "transcript",
                "session_id": "ses_test",
                "agent": "build",
            }
            messages = [
                (f"## User  ·  2026-01-01T00:00:0{i}Z\n\n" + ("x" * 600_000) + "\n\n")
                for i in (1, 2)
            ]
            preamble = yaml_frontmatter(metadata) + "# Session\n\n"
            path.write_text(preamble + "".join(messages), encoding="utf-8")
            message_sizes = [len(item.encode("utf-8")) for item in messages]

            parts = chunk_markdown_file(
                path, 1, "Session", "ses_test", message_sizes, metadata
            )

            self.assertEqual(len(parts), 2)
            part_dir = path.with_name("session.parts")
            chunk_files = sorted(part_dir.glob("session-part-*.md"))
            self.assertEqual(len(chunk_files), 2)
            for chunk in chunk_files:
                text = chunk.read_text(encoding="utf-8")
                self.assertTrue(text.startswith("---\n"))
                self.assertIn('session_id: "ses_test"\n', text)
            continuation = (part_dir / "session-part-002.md").read_text(
                encoding="utf-8"
            )
            self.assertIn("part: 2\n", continuation)
            first_part = (part_dir / "session-part-001.md").read_text(
                encoding="utf-8"
            )
            self.assertIn("part: 1\n", first_part)
            landing = path.read_text(encoding="utf-8")
            self.assertTrue(landing.startswith("---\n"))
            self.assertIn('type: "transcript_landing"\n', landing)
            index = (part_dir / "index.md").read_text(encoding="utf-8")
            self.assertTrue(index.startswith("---\n"))
            self.assertIn('type: "transcript_parts_index"\n', index)

    def test_session_frontmatter_uses_message_metadata_when_session_fields_are_empty(self):
        from exportlib.transcript import session_frontmatter

        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.execute(
            "CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT)"
        )
        con.executemany(
            "INSERT INTO message VALUES (?, ?, ?)",
            [
                ("ses_test", 1, '{"modelID":"model-from-message"}'),
                ("ses_test", 2, '{"agent":"build"}'),
            ],
        )
        fields = session_frontmatter({
            "id": "ses_test",
            "agent": None,
            "model": None,
            "directory": "/work",
            "time_created": 1_789_000_000_000,
            "parent_id": None,
        }, "transcript", 1, 0, 0, "Session", con)
        self.assertEqual(fields["agent"], "build")
        self.assertEqual(fields["model"], "model-from-message")
        con.close()


class ExportProgressTests(unittest.TestCase):
    class TTYBuffer(io.StringIO):
        def isatty(self):
            return True

    def test_progress_updates_interactive_stderr_and_finishes_line(self):
        stream = self.TTYBuffer()
        progress = Progress("Exporting", 2, stream=stream)
        progress.start()
        progress.advance()
        progress.advance()
        progress.finish()

        output = stream.getvalue()
        self.assertIn("Exporting:", output)
        self.assertIn("1/2 sessions", output)
        self.assertIn("2/2 sessions\n", output)

    def test_progress_is_silent_when_disabled_or_not_a_tty(self):
        disabled_stream = self.TTYBuffer()
        Progress("Exporting", 2, disabled=True, stream=disabled_stream).start()
        non_tty_stream = io.StringIO()
        Progress("Exporting", 2, stream=non_tty_stream).start()

        self.assertEqual(disabled_stream.getvalue(), "")
        self.assertEqual(non_tty_stream.getvalue(), "")


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
