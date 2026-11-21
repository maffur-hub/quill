"""Self-healing of a corrupt, truncated, or empty index.db.

The index is a derived cache, so a damaged file must never wedge every
index-backed command until someone runs `index --rebuild`. Each test builds
real notes through the store, damages the index, and checks that `list`
rebuilds it from the Markdown and still sees every note.

Every test uses a disposable data root (QUILL_DATA_DIR) and QUILL_E2E=1.
The live ~/.local/share/quill directory is never read or written.
"""

from __future__ import annotations

import sqlite3
import unittest
from pathlib import Path

from tests.store.test_store import StoreTestCase

# Mirrors SCHEMA_VERSION in scripts/quill-store. The store is a script, not an
# importable module, so the value is repeated here deliberately: a schema bump
# that forgets this test should fail loudly rather than silently follow along.
SCHEMA_VERSION = 3


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

    def assert_index_healed(self, expected_ids: set[str], written: str,
                            title: str) -> None:
        """Check index.db directly, before any command could heal it in passing.

        Every store invocation is a separate process, so a later `list` would
        sync from the Markdown and recreate a missing index on its own. That
        would hide a write path that never rebuilt the index, so these
        assertions run first and look at the rows the write actually left.
        """
        conn = sqlite3.connect(str(self.index_path()))
        try:
            version = int(conn.execute("PRAGMA user_version").fetchone()[0])
            count = int(conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0])
            row = conn.execute(
                "SELECT title FROM notes WHERE id=?", (written,)
            ).fetchone()
        finally:
            conn.close()
        self.assertEqual(
            version, SCHEMA_VERSION,
            "the healed index does not carry the current schema version",
        )
        self.assertEqual(
            count, len(expected_ids),
            "the healed index does not carry exactly the seeded notes",
        )
        self.assertIsNotNone(row, "the written note has no row in the healed index")
        self.assertEqual(
            row[0], title,
            "the written note's index row does not carry the new title",
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

    def test_garbage_index_heals_on_write(self):
        # A save writes the body before it touches the index. When the index
        # is garbage the write has already succeeded on disk, so reporting an
        # index error would be a lie; the write path must heal like the reads.
        identifiers = self.seed_notes()
        identifier = sorted(identifiers)[0]
        index = self.index_path()
        index.write_bytes(b"NOT A DATABASE AT ALL")
        (self.root / "index.db-wal").write_bytes(b"stale wal")
        (self.root / "index.db-shm").write_bytes(b"stale shm")
        body = "# Heal Write\n\ntungsten\n"
        result = self.success("write", identifier, "--stdin", stdin=body)
        self.assertIn("modified", result)
        self.assertIsInstance(result["modified"], int)
        self.assertEqual(
            self.note_path(identifier).read_text(encoding="utf-8"), body,
            "the write reported success but the body is not on disk",
        )
        self.assert_index_healed(identifiers, identifier, "Heal Write")
        listing = self.success("list")
        self.assertTrue(
            identifiers <= {note["id"] for note in listing["notes"]},
            "the rebuilt index is missing seeded notes",
        )
        found = self.success("search", "tungsten")
        self.assertIn(
            identifier, {note["id"] for note in found["results"]},
            "the rebuilt index does not carry the new body",
        )

    def test_user_version_mismatch_heals_on_write(self):
        # Same contract as the garbage case, reached through index_connect's
        # version check instead of a DatabaseError: the index is wiped and
        # recreated empty, so the write path must repopulate all of it.
        identifiers = self.seed_notes()
        identifier = sorted(identifiers)[0]
        conn = sqlite3.connect(str(self.index_path()))
        try:
            conn.execute("PRAGMA user_version=999")
            conn.commit()
        finally:
            conn.close()
        body = "# Heal Write\n\ntungsten\n"
        result = self.success("write", identifier, "--stdin", stdin=body)
        self.assertIn("modified", result)
        self.assertIsInstance(result["modified"], int)
        self.assertEqual(
            self.note_path(identifier).read_text(encoding="utf-8"), body,
            "the write reported success but the body is not on disk",
        )
        # create_schema() re-applies PRAGMA user_version, and the forced full
        # sync re-indexes both seeded notes, not just the written one.
        self.assert_index_healed(identifiers, identifier, "Heal Write")


if __name__ == "__main__":
    unittest.main()
