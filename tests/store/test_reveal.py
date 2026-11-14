"""Contract tests for scripts/quill-reveal.

Every case runs with ``--dry-run`` (or fails during argument/path validation
before a strategy can spawn anything), so the suite never opens a file-manager
window. Each test owns a disposable TemporaryDirectory; the live data
directory is never touched.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REVEAL = ROOT / "scripts" / "quill-reveal"
HAS_GDBUS = shutil.which("gdbus") is not None


class RevealTestCase(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="quill-reveal-test-")
        self.folder = Path(self._temp.name)

    def tearDown(self):
        self._temp.cleanup()

    # -- process helpers ---------------------------------------------------

    def run_reveal(self, *args):
        return subprocess.run(
            [sys.executable, str(REVEAL), *[str(arg) for arg in args]],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(ROOT),
        )

    def success(self, *args):
        process = self.run_reveal(*args)
        self.assertEqual(
            process.returncode, 0,
            f"{args} failed: {process.stderr.strip()}",
        )
        self.assertEqual(process.stderr, "", f"{args} wrote to stderr")
        lines = process.stdout.splitlines()
        self.assertEqual(len(lines), 1, f"{args} did not print exactly one line")
        value = json.loads(lines[0])
        self.assertIsInstance(value, dict)
        self.assertTrue(value.get("ok"))
        return value

    def failure(self, *args, code=1, prefix="quill-reveal:"):
        process = self.run_reveal(*args)
        self.assertEqual(process.returncode, code, f"{args} exited wrongly")
        self.assertEqual(process.stdout, "", f"{args} wrote to stdout")
        self.assertTrue(
            process.stderr.startswith(prefix),
            f"{args} stderr: {process.stderr!r}",
        )
        return process.stderr

    # -- fixture helpers ---------------------------------------------------

    def note(self, name="note.md"):
        path = self.folder / name
        path.write_text("# Note\n\nbody\n", encoding="utf-8")
        return path


class TestResolution(RevealTestCase):
    def test_existing_file_auto_is_one_json_line(self):
        note = self.note()
        result = self.success(note, "--dry-run")
        self.assertIn(result["mode"], {"dbus", "select", "open"})
        self.assertEqual(result["folder"], str(self.folder))
        self.assertEqual(result["path"], str(note))
        self.assertIsInstance(result["command"], list)
        self.assertTrue(result["command"])
        self.assertNotIn("missing", result)

    def test_select_uses_the_requested_file_manager(self):
        note = self.note()
        result = self.success(
            note, "--mode", "select", "--file-manager", "/bin/true", "--dry-run"
        )
        self.assertEqual(result["mode"], "select")
        self.assertEqual(result["command"][0], "/bin/true")
        self.assertIn("--select", result["command"])
        self.assertIn(str(note), result["command"])
        self.assertNotIn("missing", result)

    def test_open_targets_the_folder(self):
        note = self.note()
        result = self.success(note, "--mode", "open", "--dry-run")
        self.assertEqual(result["mode"], "open")
        self.assertEqual(result["command"][-1], str(self.folder))


class TestDbusStrategy(RevealTestCase):
    @unittest.skipUnless(HAS_GDBUS, "gdbus is not installed")
    def test_show_items_percent_encodes_space_and_quote(self):
        note = self.note("a b'c.md")
        result = self.success(note, "--mode", "dbus", "--dry-run")
        self.assertEqual(result["mode"], "dbus")
        uri = result["command"][-2]
        self.assertIn("%20", uri)
        self.assertIn("%27", uri)
        self.assertTrue(
            any("FileManager1.ShowItems" in part for part in result["command"])
        )

    @unittest.skipUnless(HAS_GDBUS, "gdbus is not installed")
    def test_directory_uses_show_folders(self):
        result = self.success(self.folder, "--mode", "dbus", "--dry-run")
        self.assertEqual(result["mode"], "dbus")
        self.assertEqual(result["folder"], str(self.folder))
        self.assertEqual(result["path"], str(self.folder))
        self.assertTrue(
            any("FileManager1.ShowFolders" in part for part in result["command"])
        )

    @unittest.skipUnless(HAS_GDBUS, "gdbus is not installed")
    def test_missing_file_falls_back_to_its_folder(self):
        gone = self.folder / "gone.md"
        result = self.success(gone, "--mode", "dbus", "--dry-run")
        self.assertEqual(result["folder"], str(self.folder))
        self.assertEqual(result["path"], str(gone))
        self.assertTrue(result["missing"])
        self.assertTrue(
            any("FileManager1.ShowFolders" in part for part in result["command"])
        )


class TestFailures(RevealTestCase):
    def test_missing_file_and_folder_is_an_error(self):
        error = self.failure(self.folder / "absent" / "gone.md", "--dry-run")
        self.assertIn("no such file", error)

    def test_unknown_mode_is_a_usage_error(self):
        note = self.note()
        error = self.failure(note, "--mode", "bogus", "--dry-run", code=2, prefix="usage:")
        self.assertIn("invalid choice", error)

    def test_nonexistent_file_manager_fails_before_spawning(self):
        note = self.note()
        error = self.failure(
            note,
            "--mode",
            "select",
            "--file-manager",
            "/nonexistent/binary",
            "--dry-run",
        )
        self.assertIn("/nonexistent/binary", error)


class TestAutoOrder(RevealTestCase):
    def test_auto_on_a_directory_never_uses_select(self):
        result = self.success(self.folder, "--dry-run")
        self.assertNotEqual(result["mode"], "select")
        self.assertEqual(result["folder"], str(self.folder))


if __name__ == "__main__":
    unittest.main()
