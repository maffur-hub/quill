"""Self-healing of a corrupt, truncated, or empty index.db.

The index is a derived cache, so a damaged file must never wedge every
index-backed command until someone runs `index --rebuild`. Each test builds
real notes through the store, damages the index, and checks that `list`
rebuilds it from the Markdown and still sees every note.

Every test uses a disposable data root (QUILL_DATA_DIR) and QUILL_E2E=1.
The live ~/.local/share/quill directory is never read or written.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from tests.store.test_store import StoreTestCase


class TestIndexHeal(StoreTestCase):
    def index_path(self) -> Path:
        return self.root / "index.db"

    def seed_notes(self) -> set[str]:
        """Create two notes with distinct bodies and return their ids."""
        first = self.create("Heal One", content="# Heal One\n\ncobalt\n")
        second = self.create("Heal Two", content="# Heal Two\n\nmarigold\n")
        return {first, second}

    def assert_list_sees(self, identifiers: set[str]) -> None:
        listing = self.success("list")
        listed = {note["id"] for note in listing["notes"]}
        self.assertTrue(
            identifiers <= listed,
            f"list is missing {sorted(identifiers - listed)}",
        )
        # A second pass proves the rebuilt file is durable, not just an
        # in-memory connection that happened to answer once.
        again = self.success("list")
        self.assertEqual(
            {note["id"] for note in again["notes"]}, listed,
            "the rebuilt index did not survive to the next command",
        )

    def test_garbage_index_self_heals(self):
        identifiers = self.seed_notes()
        index = self.index_path()
        index.write_bytes(b"NOT A DATABASE AT ALL")
        # A crash can leave a WAL/SHM behind next to the damaged main file.
        (self.root / "index.db-wal").write_bytes(b"stale wal")
        (self.root / "index.db-shm").write_bytes(b"stale shm")
        self.assert_list_sees(identifiers)

    def test_truncated_index_self_heals(self):
        identifiers = self.seed_notes()
        index = self.index_path()
        data = index.read_bytes()
        self.assertGreater(len(data), 3)
        index.write_bytes(data[: len(data) // 3])
        self.assert_list_sees(identifiers)

    def test_empty_index_self_heals(self):
        # Pins pre-existing behaviour: index_connect's schema-version path
        # already recreates a zero-byte index.
        identifiers = self.seed_notes()
        self.index_path().write_bytes(b"")
        self.assert_list_sees(identifiers)


if __name__ == "__main__":
    unittest.main()
