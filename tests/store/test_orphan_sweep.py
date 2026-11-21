"""Crash-orphaned temp files are swept by the next locked command.

`atomic_write` leaves a `.quill-tmp-*` beside its target when the process is
killed before the rename, and the UI's `.quill-save-*` handoff buffer is left
behind when a save dies mid-flight. Both live in the store's reserved
`.quill-` namespace, so the store can remove them — but only once they are old
enough that no live writer can still own them.

Every test uses a disposable data root (QUILL_DATA_DIR) and QUILL_E2E=1.
The live ~/.local/share/quill directory is never read or written.
"""

from __future__ import annotations

import os
import time
import unittest
from pathlib import Path

from tests.store.test_store import StoreTestCase


ORPHAN_AGE_SECONDS = 3 * 60 * 60


class TestOrphanSweep(StoreTestCase):
    def orphan_files(self) -> list[Path]:
        return [
            path for path in self.root.rglob("*")
            if path.is_file()
            and (path.name.startswith(".quill-tmp-") or path.name.startswith(".quill-save-"))
        ]

    def plant_orphans(self, age_seconds: float | None) -> list[Path]:
        """Write one orphan at each spot the sweep must cover."""
        folder = self.root / "notes" / "Work"
        folder.mkdir(parents=True, exist_ok=True)
        paths = [
            self.root / ".quill-tmp-root",
            folder / ".quill-tmp-subfolder",
            self.root / ".quill-save-9-1730000000000.md",
        ]
        now = time.time()
        for path in paths:
            path.write_bytes(b"orphaned bytes\n")
            if age_seconds is not None:
                os.utime(path, (now - age_seconds, now - age_seconds))
        return paths

    def test_stale_orphans_are_swept(self):
        stale = self.plant_orphans(age_seconds=ORPHAN_AGE_SECONDS)
        self.success("list")
        for path in stale:
            self.assertFalse(path.exists(), f"stale orphan survived the sweep: {path}")
        self.assertEqual(self.orphan_files(), [], "the sweep left orphans behind")
        # A second pass must be clean too: sweeping is idempotent.
        self.success("list")
        self.assertEqual(self.orphan_files(), [])

    def test_fresh_orphans_are_kept(self):
        fresh = self.plant_orphans(age_seconds=None)
        self.success("list")
        for path in fresh:
            self.assertTrue(path.exists(), f"a live orphan was swept: {path}")
        self.assertEqual(set(self.orphan_files()), set(fresh))

    def test_old_notes_are_never_swept(self):
        identifier = self.create("Old But Real", content="# Old But Real\n\nbody\n")
        path = self.note_path(identifier)
        old = path.stat().st_mtime - ORPHAN_AGE_SECONDS
        os.utime(path, (old, old))
        listing = self.success("list")
        self.assertTrue(path.exists(), "the sweep deleted a real note")
        self.assertIn(identifier, {note["id"] for note in listing["notes"]})


if __name__ == "__main__":
    unittest.main()
