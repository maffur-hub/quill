"""Contract tests for scripts/quill-spellcheck.

Only the failure contract is covered here: a run that cannot spellcheck must
say so on stdout and exit non-zero. The hunspell-backed success path needs a
dictionary and a live hunspell, so it is exercised through the editor.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPELLCHECK = ROOT / "scripts" / "quill-spellcheck"


class SpellcheckContractTest(unittest.TestCase):
    def run_spellcheck(self, payload: bytes):
        return subprocess.run(
            [sys.executable, str(SPELLCHECK)],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_invalid_utf8_is_reported_with_a_failure_status(self):
        process = self.run_spellcheck(b"\xff\xfe broken")
        self.assertEqual(process.returncode, 1)
        result = json.loads(process.stdout.decode("utf-8"))
        self.assertFalse(result["ok"])
        self.assertIn("UTF-8", result["error"])

    def test_oversized_input_is_reported_with_a_failure_status(self):
        process = self.run_spellcheck(b"a" * (2 * 1024 * 1024 + 1))
        self.assertEqual(process.returncode, 1)
        result = json.loads(process.stdout.decode("utf-8"))
        self.assertFalse(result["ok"])
        self.assertIn("too large", result["error"])

    @unittest.skipUnless(shutil.which("hunspell"), "hunspell is not installed")
    def test_clean_text_reports_ok(self):
        process = self.run_spellcheck(b"# Heading\n\nPlain prose.\n")
        self.assertEqual(process.returncode, 0)
        result = json.loads(process.stdout.decode("utf-8"))
        self.assertTrue(result["ok"])
        self.assertIsInstance(result["words"], list)


if __name__ == "__main__":
    unittest.main()
