"""Contract and behaviour tests for scripts/quill-store.

Every test uses a disposable data root (QUILL_DATA_DIR) and QUILL_E2E=1.
The live ~/.local/share/quill directory is never read or written.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "scripts" / "quill-store"


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="quill-test-")
        self.root = Path(self._temp.name) / "quill"
        self.env = dict(os.environ)
        self.env.pop("QUILL_E2E_ALLOW_REAL", None)
        self.env["QUILL_DATA_DIR"] = str(self.root)
        self.env["QUILL_E2E"] = "1"
        self.env["QUILL_VERSION_RETENTION"] = "50"
        self.env["QUILL_VERSION_THROTTLE"] = "0"

    def tearDown(self):
        self._temp.cleanup()

    # -- process helpers ---------------------------------------------------

    def run_store(self, *args, stdin=None):
        payload = b"" if stdin is None else stdin
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        return subprocess.run(
            [sys.executable, str(STORE), *args],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            cwd=str(ROOT),
        )

    def success(self, *args, stdin=None):
        process = self.run_store(*args, stdin=stdin)
        self.assertEqual(
            process.returncode, 0,
            f"{args} failed: {process.stderr.decode('utf-8', 'replace')}",
        )
        self.assertEqual(process.stderr, b"", f"{args} wrote to stderr")
        output = process.stdout.decode("utf-8")
        decoder = json.JSONDecoder()
        value, end = decoder.raw_decode(output)
        self.assertEqual(output[end:].strip(), "", "stdout contained more than one JSON value")
        self.assertIsInstance(value, dict)
        return value

    def failure(self, *args, stdin=None):
        process = self.run_store(*args, stdin=stdin)
        self.assertEqual(process.returncode, 1, f"{args} did not fail")
        self.assertEqual(process.stdout, b"", "failed command wrote to stdout")
        output = process.stderr.decode("utf-8")
        decoder = json.JSONDecoder()
        value, end = decoder.raw_decode(output)
        self.assertEqual(output[end:].strip(), "", "stderr contained more than one JSON value")
        self.assertIsInstance(value, dict)
        self.assertIn("error", value)
        self.assertIsInstance(value["error"], str)
        self.assertTrue(value["error"])
        return value

    # -- fixture helpers ---------------------------------------------------

    def create(self, title=None, content=None, folder=""):
        if content is not None:
            args = ["create", "--folder", folder, "--content-stdin"]
            result = self.success(*args, stdin=content)
        else:
            args = ["create", "--folder", folder, "--title", title or "Untitled"]
            result = self.success(*args)
        self.assertIn("id", result)
        self.assertIn("modified", result)
        self.assertIsInstance(result["modified"], int)
        return result["id"]

    def read(self, identifier, *extra):
        return self.success("read", identifier, *extra)

    def note_path(self, identifier):
        return self.root / "notes" / identifier

    def write_note_file(self, identifier, data):
        path = self.note_path(identifier)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.success("index", "--rebuild")

    def bulk_args(self, command, identifiers, *extra):
        """Build argv for a bulk call: positional primary id then --id."""
        args = [command, identifiers[0]]
        for identifier in identifiers[1:]:
            args.extend(["--id", identifier])
        args.extend(extra)
        return args

    def bulk(self, command, identifiers, *extra):
        return self.success(*self.bulk_args(command, identifiers, *extra))


class TestCliContract(StoreTestCase):
    def test_success_is_exactly_one_json_object(self):
        result = self.success("list")
        self.assertIn("notes", result)
        self.assertIsInstance(result["notes"], list)

    def test_errors_are_json_on_stderr_with_exit_one(self):
        error = self.failure("read", "does-not-exist.md")
        self.assertIn("note not found", error["error"])

    def test_mutating_commands_refuse_invalid_ids(self):
        self.failure("write", "../escape.md", stdin="x")
        self.failure("trash", "missing.md")


class TestNotes(StoreTestCase):
    def test_create_list_read_roundtrip_with_folder(self):
        identifier = self.create("Roundtrip", content="# Roundtrip\n\nbody text\n", folder="Work/Sub")
        self.assertTrue(identifier.startswith("Work/Sub/"))
        listing = self.success("list")
        self.assertIn("Work/Sub", listing["folders"])
        matching = [note for note in listing["notes"] if note["id"] == identifier]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["title"], "Roundtrip")
        self.assertEqual(matching[0]["folder"], "Work/Sub")
        self.assertEqual(listing["totalCount"], 1)
        self.assertEqual(listing["trashCount"], 0)
        read = self.read(identifier)
        self.assertEqual(read["content"], "# Roundtrip\n\nbody text\n")
        self.assertFalse(read["tooLarge"])

    def test_frontmatter_title_wins_in_listing(self):
        identifier = self.create(
            content="---\ntitle: Front Matter\n---\n\n# Heading\n\nbody\n"
        )
        note = [item for item in self.success("list")["notes"] if item["id"] == identifier][0]
        self.assertEqual(note["title"], "Front Matter")

    def test_rename_leaves_hash_lines_inside_fences_alone(self):
        identifier = self.create(
            content="```bash\n# not a heading\nls -la\n```\n\n# Old\n\nbody\n"
        )
        self.success("rename", identifier, "--title", "Renamed")
        content = self.read(identifier)["content"]
        self.assertIn("```bash\n# not a heading\nls -la\n```\n", content)
        self.assertIn("\n# Renamed\n", content)
        self.assertNotIn("# Old", content)

        # A note whose only `#` lines are comments gets a new heading, and the
        # fence still survives byte for byte.
        fenced = self.create(content="```\n# still a comment\n```\n")
        self.success("rename", fenced, "--title", "Fenced")
        self.assertEqual(
            self.read(fenced)["content"], "# Fenced\n\n```\n# still a comment\n```\n")

    def test_rename_roundtrips_a_quoted_frontmatter_title(self):
        identifier = self.create(content="---\ntitle: Old\n---\n\nbody\n")
        quoted = 'He said "hi"'
        self.success("rename", identifier, "--title", quoted)
        content = self.read(identifier)["content"]
        self.assertIn('title: "He said \\"hi\\""', content)
        note = [item for item in self.success("list")["notes"] if item["id"] == identifier][0]
        self.assertEqual(note["title"], quoted)

        # Single-quoted YAML survives too, including its doubled apostrophe.
        self.write_note_file(identifier, b"---\ntitle: 'It''s fine'\n---\n\nbody\n")
        note = [item for item in self.success("list")["notes"] if item["id"] == identifier][0]
        self.assertEqual(note["title"], "It's fine")

    def test_write_stdin_and_content_file(self):
        identifier = self.create("Write")
        written = self.success("write", identifier, "--stdin", stdin="body one\n")
        self.assertEqual(written["id"], identifier)
        self.assertEqual(written["size"], len("body one\n".encode("utf-8")))
        self.assertIsInstance(written["modified"], int)
        self.assertEqual(self.read(identifier)["content"], "body one\n")

        content_file = Path(self._temp.name) / "payload.md"
        content_file.write_text("body two\n", encoding="utf-8")
        written = self.success("write", identifier, "--content-file", str(content_file))
        self.assertEqual(written["size"], len("body two\n".encode("utf-8")))
        self.assertEqual(self.read(identifier)["content"], "body two\n")

    def test_lf_and_crlf_newlines_are_preserved(self):
        identifier = self.create("Newlines", content="# Newlines\n\nfirst\n")
        read = self.read(identifier)
        self.assertNotIn("\r\n", read["content"])
        self.success("write", identifier, "--stdin", stdin="# Newlines\n\nsecond\n")
        self.assertEqual(self.read(identifier)["content"], "# Newlines\n\nsecond\n")

        # A pre-existing CRLF note keeps CRLF when a LF body is written.
        self.write_note_file(identifier, b"# Newlines\r\n\r\nthird\r\n")
        self.success("write", identifier, "--stdin", stdin="# Newlines\n\nfourth\n")
        self.assertEqual(self.read(identifier)["content"], "# Newlines\r\n\r\nfourth\r\n")

    def test_rename_move_duplicate_and_pin(self):
        identifier = self.create("Original", content="# Original\n\nbody\n", folder="Inbox")
        renamed = self.success("rename", identifier, "--title", "Renamed")
        self.assertEqual(renamed["id"], identifier)
        self.assertTrue(self.read(identifier)["content"].startswith("# Renamed\n"))
        self.assertEqual(
            [note["title"] for note in self.success("list")["notes"]],
            ["Renamed"],
        )

        duplicated = self.success("duplicate", identifier)
        copy_id = duplicated["id"]
        self.assertNotEqual(copy_id, identifier)
        self.assertIn("# Renamed copy", self.read(copy_id)["content"])

        moved = self.success("move", identifier, "--folder", "Archive/2026")
        moved_id = moved["id"]
        self.assertTrue(moved_id.startswith("Archive/2026/"))
        listing = self.success("list")
        self.assertIn("Archive/2026", listing["folders"])
        self.assertEqual(
            {note["id"] for note in listing["notes"]},
            {moved_id, copy_id},
        )

        pinned = self.success("pin", moved_id)
        self.assertTrue(pinned["pinned"])
        note = [item for item in self.success("list")["notes"] if item["id"] == moved_id][0]
        self.assertTrue(note["pinned"])
        unpinned = self.success("pin", moved_id)
        self.assertFalse(unpinned["pinned"])

    def test_create_requires_content_stdin_or_title(self):
        identifier = self.create()
        self.assertEqual(self.read(identifier)["content"], "# Untitled\n\n")


class TestEncodingIntegrity(StoreTestCase):
    """Commands that rewrite a note must refuse to touch invalid UTF-8."""

    def test_rename_refuses_a_non_utf8_note(self):
        identifier = self.create("Legacy")
        raw = b"# Legacy\n\ncaf\xe9\n"
        self.write_note_file(identifier, raw)
        error = self.failure("rename", identifier, "--title", "Renamed")
        self.assertIn("UTF-8", error["error"])
        self.assertEqual(self.note_path(identifier).read_bytes(), raw)

    def test_duplicate_refuses_a_non_utf8_note(self):
        identifier = self.create("Legacy")
        raw = b"# Legacy\n\ncaf\xe9\n"
        self.write_note_file(identifier, raw)
        before = len(self.success("list")["notes"])
        error = self.failure("duplicate", identifier)
        self.assertIn("UTF-8", error["error"])
        self.assertEqual(len(self.success("list")["notes"]), before)

    def test_tag_commands_skip_a_non_utf8_note(self):
        identifier = self.create(
            "Legacy", content="---\ntags: [alpha]\n---\n\n# Legacy\n")
        raw = b"---\ntags: [alpha]\n---\n\ncaf\xe9\n"
        self.write_note_file(identifier, raw)
        renamed = self.success("tag-rename", "alpha", "beta")
        self.assertEqual(renamed["updated"], 0)
        self.assertEqual(self.note_path(identifier).read_bytes(), raw)
        deleted = self.success("tag-delete", "alpha")
        self.assertEqual(deleted["updated"], 0)
        self.assertEqual(self.note_path(identifier).read_bytes(), raw)



class TestCompareAndSwap(StoreTestCase):
    """write --if-mtime: a second window must not clobber a newer save."""

    def test_matching_mtime_writes_and_reports_the_new_one(self):
        identifier = self.create("Shared", content="# Shared\n\none\n")
        modified = self.read(identifier)["modified"]
        written = self.success(
            "write", identifier, "--stdin", "--if-mtime", str(modified),
            stdin="# Shared\n\ntwo\n")
        self.assertEqual(self.read(identifier)["content"], "# Shared\n\ntwo\n")
        self.assertGreaterEqual(written["modified"], modified)

    def test_a_stale_mtime_is_refused_and_the_file_is_untouched(self):
        identifier = self.create("Shared", content="# Shared\n\none\n")
        stale = self.read(identifier)["modified"]
        self.success("write", identifier, "--stdin", stdin="# Shared\n\nnewer\n")
        error = self.failure(
            "write", identifier, "--stdin", "--if-mtime", str(stale),
            stdin="# Shared\n\nolder window\n")
        self.assertEqual(error["code"], "stale")
        self.assertIn("changed on disk", error["error"])
        self.assertEqual(self.read(identifier)["content"], "# Shared\n\nnewer\n")

    def test_without_the_flag_a_write_still_overwrites(self):
        identifier = self.create("Plain", content="# Plain\n\none\n")
        self.success("write", identifier, "--stdin", stdin="# Plain\n\ntwo\n")
        self.assertEqual(self.read(identifier)["content"], "# Plain\n\ntwo\n")

    def test_a_deleted_note_is_reported_as_missing(self):
        identifier = self.create("Gone", content="# Gone\n\n")
        modified = self.read(identifier)["modified"]
        self.note_path(identifier).unlink()
        error = self.failure(
            "write", identifier, "--stdin", "--if-mtime", str(modified),
            stdin="# Gone\n\nback\n")
        self.assertIn("not found", error["error"])

class TestTrash(StoreTestCase):
    def test_trash_restore_delete_and_empty(self):
        first = self.create("First", content="# First\n\nzebra\n")
        second = self.create("Second", content="# Second\n\nquokka\n")
        trashed = self.success("trash", first)
        self.assertTrue(trashed["id"].endswith(".md"))
        self.assertNotIn(first, {note["id"] for note in self.success("list")["notes"]})
        listing = self.success("list", "--trashed")
        trashed_note = [note for note in listing["notes"] if note["id"] == trashed["id"]][0]
        self.assertTrue(trashed_note["trashed"])
        self.assertFalse(trashed_note["pinned"])
        self.assertEqual(listing["trashCount"], 1)
        self.assertEqual(self.read(trashed["id"], "--trashed")["content"], "# First\n\nzebra\n")

        restored = self.success("restore", trashed["id"])
        self.assertEqual(restored["id"], first)
        self.assertEqual(self.read(first)["content"], "# First\n\nzebra\n")

        self.success("trash", first)
        deleted = self.success("delete", first)
        self.assertTrue(deleted["deleted"])
        self.assertEqual(self.success("list", "--trashed")["trashCount"], 0)

        self.success("trash", second)
        emptied = self.success("empty-trash")
        self.assertEqual(emptied["deleted"], 1)
        self.assertEqual(self.success("list")["totalCount"], 0)


class TestVersions(StoreTestCase):
    def test_versions_restore_exact_bytes_and_recover_current_state(self):
        identifier = self.create("Versioned", content="# Versioned\n\nzero\n")
        self.success("write", identifier, "--stdin", stdin="# Versioned\n\none\n")
        self.success("write", identifier, "--stdin", stdin="# Versioned\n\ntwo\n")

        listing = self.success("versions", identifier)
        self.assertEqual(listing["retention"], 50)
        self.assertGreaterEqual(len(listing["versions"]), 2)
        for snapshot in listing["versions"]:
            self.assertRegex(snapshot["name"], r"^\d{8}T\d{6}Z-[0-9a-f]{16}(?:-\d+)?\.md$")
            self.assertIsInstance(snapshot["sha256"], str)
            self.assertEqual(len(snapshot["sha256"]), 64)

        # The newest snapshot is the bytes before the most recent write.
        newest = listing["versions"][0]
        restored = self.success("restore-version", identifier, newest["name"])
        self.assertEqual(restored["snapshot"], newest["name"])
        self.assertEqual(self.read(identifier)["content"], "# Versioned\n\none\n")

        # Restoring changed current state, and that state is itself recoverable.
        after = self.success("versions", identifier)
        self.assertGreaterEqual(len(after["versions"]), 2)
        second_sha = hashlib.sha256(b"# Versioned\n\ntwo\n").hexdigest()
        recoverable = [snapshot for snapshot in after["versions"] if snapshot["sha256"] == second_sha]
        self.assertEqual(len(recoverable), 1)
        restored_again = self.success("restore-version", identifier, recoverable[0]["name"])
        self.assertEqual(restored_again["snapshot"], recoverable[0]["name"])
        self.assertEqual(self.read(identifier)["content"], "# Versioned\n\ntwo\n")

    def test_restore_missing_snapshot_is_an_error(self):
        identifier = self.create("No versions", content="# No versions\n")
        self.failure("restore-version", identifier, "20000101T000000Z-0000000000000000.md")


class TestVersionRelocation(StoreTestCase):
    """Version history is keyed by note id, so it must follow the note."""

    def history(self, identifier):
        return [snapshot["name"] for snapshot in self.success("versions", identifier)["versions"]]

    def assertCarried(self, before, moved):
        # The relocation itself snapshots the note, so the new history may have
        # one extra entry; every older snapshot must still be there.
        self.assertTrue(before)
        self.assertEqual(set(before) - set(moved), set())

    def test_move_carries_version_history(self):
        identifier = self.create("Moved", content="# Moved\n\nzero\n")
        self.success("write", identifier, "--stdin", stdin="# Moved\n\none\n")
        before = self.history(identifier)
        self.assertTrue(before)
        moved = self.success("move", identifier, "--folder", "Archive")["id"]
        self.assertNotEqual(moved, identifier)
        self.assertCarried(before, self.history(moved))
        self.assertEqual(self.history(identifier), [])

    def test_folder_rename_carries_version_history(self):
        identifier = self.create(
            "Renamed", content="# Renamed\n\nzero\n", folder="Inbox")
        self.success("write", identifier, "--stdin", stdin="# Renamed\n\none\n")
        before = self.history(identifier)
        self.assertTrue(before)
        self.success("folder", "rename", "Inbox", "Archive")
        moved = "Archive/" + Path(identifier).name
        self.assertCarried(before, self.history(moved))
        self.assertEqual(self.history(identifier), [])

    def test_folder_delete_carries_version_history(self):
        identifier = self.create(
            "Flattened", content="# Flattened\n\nzero\n", folder="Deep/Nested")
        self.success("write", identifier, "--stdin", stdin="# Flattened\n\none\n")
        before = self.history(identifier)
        self.assertTrue(before)
        result = self.success("folder", "delete", "Deep", "--force")
        self.assertEqual(result["moved"], 1)
        flattened = Path(identifier).name
        self.assertCarried(before, self.history(flattened))
        self.assertEqual(self.history(identifier), [])

    def test_restore_carries_version_history_when_the_name_is_taken(self):
        identifier = self.create("Taken", content="# Taken\n\nzero\n")
        self.success("write", identifier, "--stdin", stdin="# Taken\n\none\n")
        before = self.history(identifier)
        self.assertTrue(before)
        self.success("trash", identifier)
        # Another note now owns the old path, so the restore has to rename.
        self.write_note_file(identifier, b"# Other\n\nfresh\n")
        restored = self.success("restore", identifier)["id"]
        self.assertNotEqual(restored, identifier)
        self.assertCarried(before, self.history(restored))


class TestSearch(StoreTestCase):
    def test_exact_prefix_and_typo_fallback(self):
        zebra = self.create("Zebra", content="# Zebra\n\nthe quick brown zebra jumps\n")
        self.create("Quokka", content="# Quokka\n\nthe quick brown quokka sleeps\n")

        exact = self.success("search", "zebra")
        self.assertTrue(exact["results"])
        self.assertEqual(exact["results"][0]["id"], zebra)
        self.assertFalse(exact["fuzzy"])

        prefix = self.success("search", "zeb")
        self.assertEqual(prefix["results"][0]["id"], zebra)
        self.assertFalse(prefix["fuzzy"])

        typo = self.success("search", "zebrra")
        self.assertTrue(typo["fuzzy"])
        self.assertEqual(typo["results"][0]["id"], zebra)
        self.assertTrue(typo["results"][0]["fuzzy"])

    def test_trashed_notes_are_excluded_from_search(self):
        identifier = self.create("Hidden", content="# Hidden\n\nunicornword\n")
        self.assertTrue(self.success("search", "unicornword")["results"])
        self.success("trash", identifier)
        self.assertEqual(self.success("search", "unicornword")["results"], [])


class TestTagsAndLinks(StoreTestCase):
    def test_tags_add_and_rename(self):
        identifier = self.create("Tagged", content="# Tagged\n\nbody #alpha\n")
        tags = self.success("tags")["tags"]
        self.assertEqual(tags, [{"tag": "alpha", "count": 1}])

        added = self.success("tag-add", identifier, "#beta", "gamma")
        self.assertEqual(sorted(added["tags"]), ["alpha", "beta", "gamma"])
        self.assertIn("#beta", added["content"])
        self.assertIn("#gamma", added["content"])
        self.assertEqual(sorted(tag["tag"] for tag in self.success("tags")["tags"]), [
            "alpha", "beta", "gamma"
        ])

        renamed = self.success("tag-rename", "alpha", "delta")
        self.assertEqual(renamed["from"], "alpha")
        self.assertEqual(renamed["tag"], "delta")
        self.assertEqual(renamed["updated"], 1)
        self.assertEqual(
            sorted(tag["tag"] for tag in self.success("tags")["tags"]),
            ["beta", "delta", "gamma"],
        )
        self.assertIn("#delta", self.read(identifier)["content"])

    def test_backlinks_and_preview_wiki_links(self):
        target = self.create("Target", content="# Target\n\nlanding page\n")
        source = self.create(
            "Source",
            content="# Source\n\nSee [[Target]] and [[Missing]].\n",
        )
        backlinks = self.success("backlinks", target)["backlinks"]
        self.assertEqual([entry["id"] for entry in backlinks], [source])
        self.assertEqual(backlinks[0]["title"], "Source")

        preview = self.success("preview", source)
        self.assertFalse(preview["tooLarge"])
        markdown = preview["markdown"]
        self.assertIn(f"[Target](quill://note/{target})", markdown)
        self.assertIn("[Missing](quill://missing/Missing)", markdown)


class TestLinkIntegrity(StoreTestCase):
    """Rename link rewriting, unresolved reporting, and scoped resolution."""

    def unresolved(self, *extra):
        return self.success("unresolved", *extra)

    def assert_unresolved(self, entries, expected):
        actual = {(entry["source"], entry["target"]): entry["count"] for entry in entries}
        self.assertEqual(actual, expected)

    def test_rename_rewrites_inbound_link_forms_and_skips_code(self):
        target = self.create("Old", content="# Old\n\nbody\n")
        source = self.create(
            "Source",
            content=(
                "# Source\n\n"
                "[[Old]] [[Old|Alias]] [[Old#Heading]] [[Old|]] "
                "`[[Old]]`\n\n```\n[[Old]]\n```\n"
            ),
        )
        before_versions = len(self.success("versions", source)["versions"])

        result = self.success("rename", target, "--title", "New")
        self.assertEqual(result["id"], target)
        self.assertEqual(result["title"], "New")
        self.assertEqual(result["linksUpdated"], 4)
        self.assertEqual(result["notesUpdated"], 1)
        self.assertEqual(
            result["sources"],
            [{"id": source, "title": "Source", "count": 4}],
        )

        self.assertEqual(
            self.read(source)["content"],
            (
                "# Source\n\n"
                "[[New]] [[New|Alias]] [[New#Heading]] [[New|]] "
                "`[[Old]]`\n\n```\n[[Old]]\n```\n"
            ),
        )
        self.assertGreater(
            len(self.success("versions", source)["versions"]), before_versions
        )
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", target)["backlinks"]],
            [source],
        )

    def test_rename_dry_run_reports_counts_without_writing(self):
        target = self.create("Old", content="# Old\n\n")
        source = self.create(
            "Source", content="# Source\n\n[[Old]] and [[Old|Alias]]\n"
        )
        before_target = self.read(target)
        before_source = self.read(source)
        target_versions = len(self.success("versions", target)["versions"])
        source_versions = len(self.success("versions", source)["versions"])

        result = self.success("rename", target, "--title", "New", "--dry-run")
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["id"], target)
        self.assertEqual(result["title"], "New")
        self.assertEqual(result["linksUpdated"], 2)
        self.assertEqual(result["notesUpdated"], 1)
        self.assertEqual(
            result["sources"],
            [{"id": source, "title": "Source", "count": 2}],
        )

        self.assertEqual(self.read(target), before_target)
        self.assertEqual(self.read(source), before_source)
        self.assertEqual(
            len(self.success("versions", target)["versions"]), target_versions
        )
        self.assertEqual(
            len(self.success("versions", source)["versions"]), source_versions
        )
        self.assertEqual(self.unresolved()["total"], 0)

    def test_rename_links_skip_leaves_links_and_reports_unresolved(self):
        target = self.create("Old", content="# Old\n\n")
        source = self.create(
            "Source", content="# Source\n\n[[Old]]\n\n[[Old]]\n"
        )

        result = self.success("rename", target, "--title", "New", "--links", "skip")
        self.assertEqual(result["linksUpdated"], 0)
        self.assertEqual(result["notesUpdated"], 0)
        self.assertEqual(result["sources"], [])
        self.assertEqual(
            self.read(source)["content"], "# Source\n\n[[Old]]\n\n[[Old]]\n"
        )

        broken = self.success("unresolved", "--id", source)
        self.assertEqual(
            broken["unresolved"],
            [
                {
                    "source": source,
                    "sourceTitle": "Source",
                    "target": "Old",
                    "count": 2,
                }
            ],
        )
        self.assertEqual(broken["total"], 2)
        self.assertEqual(broken["sources"], 1)

    def test_rename_only_rewrites_links_to_the_renamed_note(self):
        alpha = self.create("Alpha", content="# Alpha\n\n")
        self.create("Alpha Two", content="# Alpha Two\n\n")
        source = self.create(
            "Source", content="# Source\n\n[[Alpha Two]] and [[alpha]]\n"
        )

        result = self.success("rename", alpha, "--title", "Renamed")
        self.assertEqual(result["linksUpdated"], 1)
        self.assertEqual(
            self.read(source)["content"],
            "# Source\n\n[[Alpha Two]] and [[Renamed]]\n",
        )
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", alpha)["backlinks"]],
            [source],
        )

    def test_unresolved_groups_filters_and_ignores_code(self):
        source = self.create(
            "Source",
            content=(
                "# Source\n\n"
                "[[Missing]] [[Missing]] [[Other]] `[[Inline]]`\n\n"
                "```\n[[Fenced]]\n```\n"
            ),
        )
        second = self.create("Second", content="# Second\n\n[[Missing]]\n")

        report = self.unresolved()
        self.assert_unresolved(
            report["unresolved"],
            {
                (source, "Missing"): 2,
                (source, "Other"): 1,
                (second, "Missing"): 1,
            },
        )
        self.assertEqual(report["total"], 4)
        self.assertEqual(report["sources"], 2)
        self.assertEqual(
            report["unresolved"],
            sorted(
                report["unresolved"],
                key=lambda entry: (entry["source"].casefold(), entry["target"].casefold()),
            ),
        )

        filtered = self.success("unresolved", "--id", source)
        self.assert_unresolved(
            filtered["unresolved"],
            {(source, "Missing"): 2, (source, "Other"): 1},
        )
        self.assertEqual(filtered["total"], 3)
        self.assertEqual(filtered["sources"], 1)
        self.assertEqual(
            self.success("unresolved", "--id", "unknown-note.md")["unresolved"], []
        )

        self.success("trash", source)
        remaining = self.unresolved()
        self.assert_unresolved(remaining["unresolved"], {(second, "Missing"): 1})
        self.assertEqual(remaining["total"], 1)
        self.assertEqual(remaining["sources"], 1)

    def test_creating_missing_target_resolves_broken_links(self):
        source = self.create("Source", content="# Source\n\n[[Ghost]]\n")
        self.assertEqual(self.unresolved()["total"], 1)

        ghost = self.create("Ghost")
        self.assertEqual(self.unresolved()["total"], 0)
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", ghost)["backlinks"]],
            [source],
        )

    def test_scoped_resolution_follows_title_rewrites(self):
        alpha = self.create("Alpha", content="# Alpha\n\n")
        source = self.create("Source", content="# Source\n\n[[Alpha]]\n")
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", alpha)["backlinks"]],
            [source],
        )

        self.success("write", alpha, "--stdin", stdin="# Gamma\n\n")
        self.assertEqual(self.success("backlinks", alpha)["backlinks"], [])
        self.assert_unresolved(
            self.unresolved()["unresolved"], {(source, "Alpha"): 1}
        )

        self.success("write", alpha, "--stdin", stdin="# Alpha\n\n")
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", alpha)["backlinks"]],
            [source],
        )
        self.assertEqual(self.unresolved()["total"], 0)

    def test_scoped_resolution_follows_trash_and_restore(self):
        alpha = self.create("Alpha", content="# Alpha\n\n")
        source = self.create("Source", content="# Source\n\n[[Alpha]]\n")

        trashed = self.success("trash", alpha)
        self.assertEqual(self.success("backlinks", alpha)["backlinks"], [])
        self.assert_unresolved(
            self.unresolved()["unresolved"], {(source, "Alpha"): 1}
        )

        restored = self.success("restore", trashed["id"])
        self.assertEqual(restored["id"], alpha)
        self.assertEqual(
            [entry["id"] for entry in self.success("backlinks", alpha)["backlinks"]],
            [source],
        )
        self.assertEqual(self.unresolved()["total"], 0)

    def test_rename_without_inbound_links_is_a_noop_for_links(self):
        lonely = self.create("Lonely", content="# Lonely\n\nbody\n")
        result = self.success("rename", lonely, "--title", "Solo")
        self.assertEqual(result["title"], "Solo")
        self.assertEqual(result["linksUpdated"], 0)
        self.assertEqual(result["notesUpdated"], 0)
        self.assertEqual(result["sources"], [])


class TestFolders(StoreTestCase):
    def test_folder_create_rename_and_delete_force(self):
        created = self.success("folder", "create", "Projects")
        self.assertEqual(created["folder"], "Projects")
        self.assertIn("Projects", self.success("list")["folders"])
        self.failure("folder", "create", "Projects")

        identifier = self.create("Inside", content="# Inside\n", folder="Projects")
        self.success("folder", "rename", "Projects", "Archive")
        self.assertIn("Archive", self.success("list")["folders"])
        self.assertNotIn("Projects", self.success("list")["folders"])
        self.assertTrue(self.read(f"Archive/{Path(identifier).name}"))

        error = self.failure("folder", "delete", "Archive")
        self.assertIn("not empty", error["error"])
        deleted = self.success("folder", "delete", "Archive", "--force")
        self.assertTrue(deleted["deleted"])
        self.assertEqual(deleted["moved"], 1)
        self.assertNotIn("Archive", self.success("list")["folders"])
        self.assertTrue(self.success("list")["notes"])



class TestFolderContainment(StoreTestCase):
    """A symlinked folder must not move Quill's writes outside notes/."""

    def setUp(self):
        super().setUp()
        self.outside = Path(self._temp.name) / "outside"
        self.outside.mkdir()
        self.keep = self.outside / "keep.txt"
        self.keep.write_text("do not touch", encoding="utf-8")
        notes = self.root / "notes"
        notes.mkdir(parents=True, exist_ok=True)
        os.symlink(self.outside, notes / "Linked")
        self.identifier = self.success(
            "create", "--title", "Stay", "--content-stdin", stdin="# Stay\n"
        )["id"]

    def assertOutsideUntouched(self):
        self.assertEqual(
            sorted(path.name for path in self.outside.iterdir()), ["keep.txt"])
        self.assertEqual(self.keep.read_text(encoding="utf-8"), "do not touch")

    def test_create_and_move_into_a_linked_folder_are_refused(self):
        error = self.failure("create", "--folder", "Linked", "--title", "Lost")
        self.assertIn("escapes the notes directory", error["error"])
        error = self.failure("move", self.identifier, "--folder", "Linked")
        self.assertIn("escapes the notes directory", error["error"])
        self.assertOutsideUntouched()
        self.assertTrue(self.read(self.identifier))

    def test_folder_commands_refuse_a_linked_folder(self):
        error = self.failure("folder", "create", "Linked/Nested")
        self.assertIn("escapes the notes directory", error["error"])
        error = self.failure("folder", "delete", "Linked", "--force")
        self.assertIn("escapes the notes directory", error["error"])
        error = self.failure("folder", "rename", "Linked", "Elsewhere")
        self.assertIn("escapes the notes directory", error["error"])
        self.assertOutsideUntouched()
        self.assertTrue((self.root / "notes" / "Linked").is_symlink())


class TestAttachments(StoreTestCase):
    def test_save_list_and_gc(self):
        image = b"\x89PNG\r\n\x1a\n" + b"fake-png-body"
        image_path = Path(self._temp.name) / "picture.png"
        image_path.write_bytes(image)

        saved = self.success("attachment", "save", "--file", str(image_path), "--name", "Picture")
        self.assertEqual(saved["kind"], "image")
        self.assertEqual(saved["size"], len(image))
        self.assertTrue(saved["name"].endswith(".png"))
        self.assertTrue(saved["path"].startswith(str(self.root / "attachments")))
        self.assertIn("![Picture](", saved["markdown"])
        self.assertFalse(saved["deduped"])

        duplicate = self.success("attachment", "save", "--file", str(image_path))
        self.assertTrue(duplicate["deduped"])
        self.assertEqual(duplicate["name"], saved["name"])

        identifier = self.create("With image", content=f"# With image\n\n{saved['markdown']}\n")
        attachments = self.success("attachment", "list")["attachments"]
        self.assertEqual(len(attachments), 1)
        self.assertTrue(attachments[0]["referenced"])

        note_file = Path(self._temp.name) / "unused.txt"
        note_file.write_text("unused", encoding="utf-8")
        unused = self.success("attachment", "save", "--file", str(note_file))
        self.assertEqual(unused["kind"], "file")
        self.assertEqual(len(self.success("attachment", "list")["attachments"]), 2)

        dry_run = self.success("attachment", "gc", "--dry-run")
        self.assertEqual(dry_run["removed"], 1)
        self.assertEqual(dry_run["kept"], 1)
        self.assertTrue(dry_run["dryRun"])
        self.assertEqual(len(self.success("attachment", "list")["attachments"]), 2)

        collected = self.success("attachment", "gc")
        self.assertEqual(collected["removed"], 1)
        self.assertEqual(collected["kept"], 1)
        self.assertEqual(collected["freed"], len("unused"))
        remaining = self.success("attachment", "list")["attachments"]
        self.assertEqual(len(remaining), 1)
        self.assertTrue(remaining[0]["referenced"])
        self.assertEqual(self.read(identifier)["content"], f"# With image\n\n{saved['markdown']}\n")

    def test_gc_keeps_an_attachment_only_a_draft_references(self):
        image_path = Path(self._temp.name) / "only-draft.png"
        image_path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"draft-only")
        saved = self.success("attachment", "save", "--file", str(image_path))
        identifier = self.create("Drafting", content="# Drafting\n\nno image yet\n")
        note = self.note_path(identifier)
        note.with_name(note.name + ".draft").write_text(
            f"# Drafting\n\n{saved['markdown']}\n", encoding="utf-8")

        collected = self.success("attachment", "gc")
        self.assertEqual(collected["removed"], 0)
        self.assertEqual(collected["kept"], 1)

    def test_gc_refuses_when_a_note_cannot_be_read(self):
        image_path = Path(self._temp.name) / "unreadable-note.png"
        image_path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"guarded")
        self.success("attachment", "save", "--file", str(image_path))
        identifier = self.create("Guarded", content="# Guarded\n\nbody\n")
        note = self.note_path(identifier)
        note.chmod(0o000)
        try:
            error = self.failure("attachment", "gc")
            self.assertIn("refusing to delete attachments", error["error"])
        finally:
            note.chmod(0o644)
        self.assertEqual(len(self.success("attachment", "list")["attachments"]), 1)
        self.assertEqual(len(list((self.root / "attachments").iterdir())), 1)


class TestDrafts(StoreTestCase):
    def test_draft_read_write_and_discard_semantics(self):
        identifier = self.create("Drafty", content="# Drafty\n\nsaved\n")
        path = self.note_path(identifier)
        draft = path.with_name(path.name + ".draft")
        draft.write_text("# Drafty\n\nunsaved text\n", encoding="utf-8")

        read = self.read(identifier)
        self.assertEqual(read["draft"]["content"], "# Drafty\n\nunsaved text\n")
        self.assertIsInstance(read["draft"]["modified"], int)
        self.assertEqual(self.success("list")["notes"][0]["id"], identifier)

        # A write that matches the draft consumes it.
        written = self.success("write", identifier, "--stdin", stdin="# Drafty\n\nunsaved text\n")
        self.assertTrue(written["draftDeleted"])
        self.assertFalse(draft.exists())
        self.assertNotIn("draft", self.read(identifier))

        # A newer draft survives a write of different content.
        draft.write_text("# Drafty\n\nnewer draft\n", encoding="utf-8")
        written = self.success("write", identifier, "--stdin", stdin="# Drafty\n\nfrom disk\n")
        self.assertFalse(written["draftDeleted"])
        self.assertTrue(draft.exists())
        self.assertEqual(self.read(identifier)["draft"]["content"], "# Drafty\n\nnewer draft\n")

        discarded = self.success("draft", "discard", identifier)
        self.assertTrue(discarded["discarded"])
        self.assertFalse(draft.exists())
        self.assertFalse(self.success("draft", "discard", identifier)["discarded"])

    def draft_for(self, identifier, text="# Draft\n\nunsaved\n"):
        path = self.note_path(identifier)
        draft = path.with_name(path.name + ".draft")
        draft.write_text(text, encoding="utf-8")
        return draft

    def test_move_trash_and_restore_carry_the_draft(self):
        identifier = self.create("Portable", content="# Portable\n\nsaved\n")
        draft = self.draft_for(identifier)
        moved = self.success("move", identifier, "--folder", "Archive")["id"]
        self.assertFalse(draft.exists())
        self.assertTrue(self.read(moved)["draft"])

        trashed = self.success("trash", moved)["id"]
        restored = self.success("restore", trashed)["id"]
        self.assertEqual(restored, moved)
        self.assertTrue(self.read(restored)["draft"])

    def test_folder_delete_carries_the_draft_with_the_note(self):
        identifier = self.create(
            "Flattened", content="# Flattened\n\nsaved\n", folder="Deep/Nested")
        draft = self.draft_for(identifier)
        result = self.success("folder", "delete", "Deep", "--force")
        self.assertEqual(result["moved"], 1)
        self.assertFalse(draft.exists())
        flattened = Path(identifier).name
        self.assertTrue(self.read(flattened)["draft"])


class TestPreviewFromBuffer(StoreTestCase):
    """Previewing editor buffer text without touching notes or the index."""

    def write_buffer(self, content):
        path = self.root / "buffer.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return path

    def test_content_file_matches_id_preview(self):
        identifier = self.create(
            "Same",
            content="# Same\n\nBody [[Missing]] and #tag.\n",
        )
        content = self.note_path(identifier).read_bytes()
        buffer = self.write_buffer(content)

        from_file = self.success("preview", "--content-file", str(buffer))
        from_id = self.success("preview", identifier)
        self.assertEqual(from_file["tooLarge"], False)
        self.assertEqual(from_file["markdown"], from_id["markdown"])
        self.assertEqual(from_file["lineOffset"], from_id["lineOffset"])

    def test_content_file_frontmatter_line_offset(self):
        buffer = self.write_buffer(
            "---\ntitle: Buffered\ntags: [one]\n---\n\n# Buffered\n\nbody\n"
        )
        result = self.success("preview", "--content-file", str(buffer))
        self.assertFalse(result["tooLarge"])
        self.assertEqual(result["lineOffset"], 4)
        self.assertTrue(result["markdown"].lstrip().startswith("# Buffered"))

    def test_content_file_resolves_links_from_existing_index(self):
        target = self.create("Other Title", content="# Other Title\n\nlanding\n")
        self.create("Source", content="# Source\n\n[[Other Title]]\n")
        self.assertTrue((self.root / "index.db").exists())

        buffer = self.write_buffer("# Buffer\n\nSee [[Other Title]].\n")
        result = self.success("preview", "--content-file", str(buffer))
        self.assertIn(f"[Other Title](quill://note/{target})", result["markdown"])
        self.assertNotIn("quill://missing", result["markdown"])

    def test_content_file_does_not_create_index(self):
        buffer = self.write_buffer("# Buffer\n\nSee [[Anything]].\n")
        self.assertFalse((self.root / "index.db").exists())

        result = self.success("preview", "--content-file", str(buffer))
        self.assertIn("[Anything](quill://missing/Anything)", result["markdown"])
        self.assertFalse((self.root / "index.db").exists())

    def test_content_file_does_not_mutate_notes_or_index(self):
        target = self.create("Target", content="# Target\n\nbody\n")
        source = self.create("Source", content="# Source\n\n[[Target]]\n")
        index = self.root / "index.db"
        note_paths = [self.note_path(target), self.note_path(source)]
        before = {
            path: (path.read_bytes(), path.stat().st_mtime_ns)
            for path in [*note_paths, index]
        }

        buffer = self.write_buffer("# Buffer\n\nSee [[Target]].\n")
        self.success("preview", "--content-file", str(buffer))

        for path, (data, mtime) in before.items():
            self.assertEqual(path.read_bytes(), data, f"{path} content changed")
            self.assertEqual(path.stat().st_mtime_ns, mtime, f"{path} mtime changed")

    def test_content_file_keeps_code_verbatim(self):
        self.create("Other", content="# Other\n\nbody\n")
        self.create("Source", content="# Source\n\n[[Other]]\n")
        buffer = self.write_buffer(
            "# Buffer\n\n`[[Other]]`\n\n```\n[[Other]]\n```\n\n[[Other]]\n"
        )
        result = self.success("preview", "--content-file", str(buffer))
        markdown = result["markdown"]
        self.assertEqual(markdown.count("[[Other]]"), 2)
        self.assertEqual(markdown.count("quill://note/"), 1)

    def test_content_file_over_limit(self):
        buffer = self.write_buffer(b"x" * (1024 * 1024 + 1))
        result = self.success("preview", "--content-file", str(buffer))
        self.assertEqual(result["tooLarge"], True)
        self.assertEqual(result["markdown"], "")
        self.assertEqual(result["lineOffset"], 0)

    def test_requires_exactly_one_source(self):
        self.failure("preview")
        buffer = self.write_buffer("# Buffer\n")
        self.failure("preview", "--content-file", str(buffer), "--stdin")
        self.failure("preview", "some-note.md", "--content-file", str(buffer))

    def test_missing_content_file_is_an_error(self):
        error = self.failure(
            "preview", "--content-file", str(self.root / "does-not-exist.md")
        )
        self.assertIn("cannot read content file", error["error"])

    def test_trashed_requires_a_note_id(self):
        buffer = self.write_buffer("# Buffer\n")
        error = self.failure("preview", "--content-file", str(buffer), "--trashed")
        self.assertIn("--trashed requires a note id", error["error"])

    def test_stdin_matches_content_file(self):
        content = "# Buffer\n\nSee [[Target]] and `[[Target]]`.\n"
        buffer = self.write_buffer(content)
        from_file = self.success("preview", "--content-file", str(buffer))
        from_stdin = self.success("preview", "--stdin", stdin=content)
        self.assertEqual(from_stdin, from_file)


class TestIndex(StoreTestCase):
    def test_index_rebuild_is_idempotent(self):
        self.create("One", content="# One\n\nalpha #tag\n")
        self.create("Two", content="# Two\n\nbeta [[One]]\n")
        first = self.success("index", "--rebuild")
        self.assertTrue(first["rebuilt"])
        self.assertEqual(first["notes"], 2)
        self.assertEqual(first["trashed"], 0)
        self.assertGreaterEqual(first["links"], 1)
        index_bytes = (self.root / "index.db").read_bytes()
        second = self.success("index", "--rebuild")
        self.assertEqual(
            {key: second[key] for key in ("notes", "trashed", "links", "rebuilt")},
            {key: first[key] for key in ("notes", "trashed", "links", "rebuilt")},
        )
        self.assertTrue(index_bytes)


class TestTitlesAndSearchFilters(StoreTestCase):
    # -- titles ------------------------------------------------------------

    def test_titles_returns_live_notes_only_and_orders_pinned_first(self):
        first = self.create("First", content="# First\n\nbody\n")
        second = self.create("Second", content="# Second\n\nbody\n", folder="Work")
        trashed = self.create("Trashed", content="# Trashed\n\nbody\n")
        self.success("trash", trashed)
        self.success(
            "write", ".quill-hidden.md", "--create", "--stdin", stdin="# Hidden\n\nbody\n"
        )

        result = self.success("titles")
        self.assertEqual({note["id"] for note in result["notes"]}, {first, second})
        for note in result["notes"]:
            self.assertEqual(
                set(note), {"id", "title", "folder", "modified", "pinned"}
            )
        by_id = {note["id"]: note for note in result["notes"]}
        self.assertEqual(by_id[second]["folder"], "Work")

        self.assertTrue(self.success("pin", second)["pinned"])
        ordered = self.success("titles")["notes"]
        self.assertEqual(ordered[0]["id"], second)
        self.assertTrue(ordered[0]["pinned"])
        self.assertFalse(ordered[1]["pinned"])

        limited = self.success("titles", "--limit", "1")["notes"]
        self.assertEqual([note["id"] for note in limited], [second])
        self.assertEqual(len(self.success("titles", "--limit", "0")["notes"]), 1)

    # -- tag / folder filters ---------------------------------------------

    def test_tag_filters_and_filter_only_result_shape(self):
        alpha = self.create("Alpha", content="# Alpha\n\nalpha body #alpha\n")
        both = self.create("Both", content="# Both\n\nboth body #alpha #beta\n")
        beta = self.create("Beta", content="# Beta\n\nbeta body #beta\n")
        spaces = self.create(
            "Spaces", content="# Spaces\n\nspaced body #two-words\n"
        )

        result = self.success("search", "tag:alpha")
        self.assertEqual({row["id"] for row in result["results"]}, {alpha, both})
        self.assertFalse(result["fuzzy"])
        entry = [row for row in result["results"] if row["id"] == alpha][0]
        self.assertEqual(
            set(entry),
            {"id", "title", "snippet", "folder", "tags", "modified", "pinned", "size"},
        )
        self.assertEqual(entry["tags"], ["alpha"])
        self.assertIsInstance(entry["modified"], int)
        self.assertIsInstance(entry["size"], int)
        self.assertIn("alpha body", entry["snippet"])

        self.assertEqual(
            {row["id"] for row in self.success("search", "tag:alpha tag:beta")["results"]},
            {both},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "-tag:alpha", "--limit", "5")["results"]},
            {beta, spaces},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", 'tag:"two words"')["results"]},
            {spaces},
        )

    def test_folder_filters_match_inbox_and_subtrees(self):
        inbox = self.create("Inbox", content="# Inbox\n\nbody\n", folder="")
        projects = self.create("Projects", content="# Projects\n\nbody\n", folder="Projects")
        sub = self.create(
            "Sub", content="# Sub\n\nbody\n", folder="Projects/Sub"
        )
        archive = self.create(
            "Archive", content="# Archive\n\nbody\n", folder="Archive/Projects"
        )

        self.assertEqual(
            {row["id"] for row in self.success("search", "folder:Projects")["results"]},
            {projects, sub},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "folder:")["results"]},
            {inbox},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "-folder:Projects")["results"]},
            {archive, inbox},
        )

    def test_before_after_filters_use_local_midnight(self):
        september = self.create("September", content="# September\n\nbody\n")
        october = self.create("October", content="# October\n\nbody\n")

        for identifier, day in (
            (september, datetime.date(2026, 9, 15)),
            (october, datetime.date(2026, 10, 15)),
        ):
            stamp = datetime.datetime.combine(day, datetime.time(12, 0)).timestamp()
            os.utime(self.note_path(identifier), (stamp, stamp))
        self.success("index")

        self.assertEqual(
            {row["id"] for row in self.success("search", "after:2026-10-01")["results"]},
            {october},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "before:2026-10-01")["results"]},
            {september},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "-after:2026-10-01")["results"]},
            {september},
        )
        error = self.failure("search", "after:2026-1-1")
        self.assertEqual(
            error["error"],
            "invalid date in after:2026-1-1; expected YYYY-MM-DD",
        )

    # -- phrases / negation / plain regressions ---------------------------

    def test_quoted_phrases_negation_and_filter_combination(self):
        phrase = self.create(
            "Phrase", content="# Phrase\n\nexact phrase here\n\n#alpha\n"
        )
        apart = self.create("Apart", content="# Apart\n\nexact other phrase here\n")
        plain = self.create("Plain", content="# Plain\n\nsomething else phrase here\n")

        self.assertEqual(
            {row["id"] for row in self.success("search", '"exact phrase"')["results"]},
            {phrase},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", "phrase -exact")["results"]},
            {plain},
        )
        self.assertEqual(
            {
                row["id"]
                for row in self.success("search", '"exact phrase" tag:alpha')["results"]
            },
            {phrase},
        )
        self.assertEqual(
            {row["id"] for row in self.success("search", 'tag:"exact phrase"')["results"]},
            set(),
        )
        self.assertEqual(
            self.failure("search", '"unterminated')["error"],
            "unterminated quote in search query",
        )

    def test_plain_queries_keep_fuzzy_fallback_but_filters_never_do(self):
        zebra = self.create("Zebra", content="# Zebra\n\nthe quick brown zebra jumps\n")
        self.create("Quokka", content="# Quokka\n\nthe quick brown quokka sleeps\n")

        prefix = self.success("search", "zeb")
        self.assertEqual({row["id"] for row in prefix["results"]}, {zebra})
        self.assertFalse(prefix["fuzzy"])

        typo = self.success("search", "zebrra")
        self.assertTrue(typo["fuzzy"])
        self.assertEqual(typo["results"][0]["id"], zebra)
        self.assertTrue(typo["results"][0]["fuzzy"])

        filtered = self.success("search", "tag:missing zebrra")
        self.assertFalse(filtered["fuzzy"])
        self.assertTrue(all("fuzzy" not in row for row in filtered["results"]))

    # -- saved searches ----------------------------------------------------

    def test_saved_searches_round_trip_and_dedupe(self):
        created = self.success("searches", "add", "tag:alpha")
        self.assertEqual(
            created["searches"], [{"query": "tag:alpha", "label": "tag:alpha"}]
        )
        self.success("searches", "add", "tag:beta", "--label", "Beta notes")
        updated = self.success("searches", "add", "tag:alpha", "--label", "Alpha notes")
        self.assertEqual(
            updated["searches"],
            [
                {"query": "tag:alpha", "label": "Alpha notes"},
                {"query": "tag:beta", "label": "Beta notes"},
            ],
        )
        self.assertEqual(self.success("searches", "list"), updated)

        unknown = self.success("searches", "remove", "tag:unknown")
        self.assertEqual(unknown, updated)

        removed = self.success("searches", "remove", "tag:alpha")
        self.assertEqual(
            removed["searches"], [{"query": "tag:beta", "label": "Beta notes"}]
        )
        self.assertEqual(self.failure("searches", "add", "   ")["error"],
                         "saved search cannot be empty")

    def test_saved_searches_and_pins_survive_each_other(self):
        identifier = self.create("Pinned", content="# Pinned\n\nbody\n")
        self.success("searches", "add", "tag:alpha", "--label", "Alpha")

        self.assertTrue(self.success("pin", identifier)["pinned"])
        listed = self.success("searches", "list")["searches"]
        self.assertEqual(listed, [{"query": "tag:alpha", "label": "Alpha"}])
        state = json.loads((self.root / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["pinned"], [identifier])

        self.success("searches", "add", "tag:beta")
        state = json.loads((self.root / "state.json").read_text(encoding="utf-8"))
        self.assertIn(identifier, state["pinned"])
        self.assertEqual(
            [entry["query"] for entry in state["searches"]],
            ["tag:alpha", "tag:beta"],
        )

    def test_saved_searches_cap_and_update_at_cap(self):
        state = {
            "version": 1,
            "pinned": [],
            "searches": [
                {"query": f"tag:tag{index}", "label": f"tag{index}"}
                for index in range(50)
            ],
        }
        self.success("list")
        (self.root / "state.json").write_text(
            json.dumps(state), encoding="utf-8"
        )
        error = self.failure("searches", "add", "tag:extra")
        self.assertEqual(error["error"], "too many saved searches (max 50)")
        updated = self.success("searches", "add", "tag:tag0", "--label", "First")
        self.assertEqual(updated["searches"][0], {"query": "tag:tag0", "label": "First"})
        self.assertEqual(len(updated["searches"]), 50)


class TestBulkOperations(StoreTestCase):
    """Repeatable --id batches across the note-level mutating commands."""

    def test_trash_restore_delete_batches_preserve_bytes(self):
        notes = [
            self.create(f"Note {index}", content=f"# Note {index}\n\nbody {index}\n")
            for index in range(3)
        ]

        trashed = self.bulk("trash", notes)
        self.assertEqual(trashed["count"], 3)
        self.assertEqual(trashed["id"], trashed["ids"][0])
        self.assertEqual(len(trashed["ids"]), 3)
        self.assertEqual(self.success("list")["totalCount"], 0)
        self.assertEqual(self.success("list", "--trashed")["trashCount"], 3)

        # A single-id restore still carries the old primary key.
        single = self.success("restore", trashed["ids"][0])
        self.assertEqual(single["id"], notes[0])
        self.assertEqual(single["count"], 1)

        restored = self.bulk("restore", trashed["ids"][1:])
        self.assertEqual(restored["count"], 2)
        self.assertEqual(restored["id"], trashed["ids"][1])
        for index, identifier in enumerate(notes):
            self.assertEqual(
                self.read(identifier)["content"],
                f"# Note {index}\n\nbody {index}\n",
            )

        trashed_again = self.bulk("trash", notes)
        deleted = self.bulk("delete", trashed_again["ids"])
        self.assertTrue(deleted["deleted"])
        self.assertEqual(deleted["count"], 3)
        self.assertEqual(deleted["id"], trashed_again["ids"][0])
        self.assertEqual(self.success("list", "--trashed")["trashCount"], 0)

    def test_move_batch_preserves_pins_and_updates_index(self):
        notes = [
            self.create(f"Moved {index}", content=f"# Moved {index}\n\nbody\n", folder="Inbox")
            for index in range(3)
        ]
        self.success("folder", "create", "Archive")
        self.success("pin", notes[0])
        self.success("pin", notes[2])

        moved = self.bulk("move", notes, "--folder", "Archive")
        expected = [f"Archive/{Path(identifier).name}" for identifier in notes]
        self.assertEqual(moved["ids"], expected)
        self.assertEqual(moved["id"], expected[0])
        self.assertEqual(moved["count"], 3)

        listing = self.success("list")
        self.assertIn("Archive", listing["folders"])
        self.assertEqual({note["id"] for note in listing["notes"]}, set(expected))
        by_id = {note["id"]: note for note in listing["notes"]}
        self.assertTrue(by_id[expected[0]]["pinned"])
        self.assertFalse(by_id[expected[1]]["pinned"])
        self.assertTrue(by_id[expected[2]]["pinned"])

        state = json.loads((self.root / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["pinned"], sorted([expected[0], expected[2]]))

        searched = self.success("search", "folder:Archive")
        self.assertEqual({row["id"] for row in searched["results"]}, set(expected))
        titled = self.success("titles")["notes"]
        self.assertEqual({note["folder"] for note in titled}, {"Archive"})

    def test_unknown_id_anywhere_rejects_the_whole_batch(self):
        notes = [
            self.create(f"Safe {index}", content=f"# Safe {index}\n\nbody\n")
            for index in range(3)
        ]
        self.success("folder", "create", "Archive")

        args = self.bulk_args(
            "move", [notes[0], "missing-note.md", notes[1]], "--folder", "Archive"
        )
        error = self.failure(*args)
        self.assertIn("missing-note.md", error["error"])
        for identifier in notes:
            self.assertTrue(self.note_path(identifier).is_file(), identifier)
        self.assertEqual(
            list((self.root / "notes" / "Archive").rglob("*.md")), []
        )

        args = self.bulk_args("trash", [notes[0], "also-missing.md", notes[2]])
        error = self.failure(*args)
        self.assertIn("also-missing.md", error["error"])
        self.assertEqual(self.success("list")["totalCount"], 3)
        self.assertEqual(self.success("list", "--trashed")["trashCount"], 0)

    def test_pin_state_forces_idempotently_and_default_toggles(self):
        first = self.create("Pinned first", content="# First\n\nbody\n")
        second = self.create("Pinned second", content="# Second\n\nbody\n")

        turned_on = self.bulk("pin", [first, second], "--state", "on")
        self.assertTrue(turned_on["pinned"])
        self.assertEqual(turned_on["updated"], 2)
        again = self.bulk("pin", [first, second], "--state", "on")
        self.assertTrue(again["pinned"])
        self.assertEqual(again["updated"], 0)

        turned_off = self.bulk("pin", [first, second], "--state", "off")
        self.assertFalse(turned_off["pinned"])
        self.assertEqual(turned_off["updated"], 2)

        toggled = self.success("pin", first)
        self.assertEqual(toggled["id"], first)
        self.assertTrue(toggled["pinned"])
        self.assertEqual(toggled["updated"], 1)

        flipped = self.bulk("pin", [first, second])
        self.assertFalse(flipped["pinned"])  # state of the primary note
        self.assertEqual(flipped["updated"], 2)  # each note flips individually
        states = {
            note["id"]: note["pinned"] for note in self.success("titles")["notes"]
        }
        self.assertFalse(states[first])
        self.assertTrue(states[second])

    def test_tag_add_bulk_reports_first_note_and_updated(self):
        notes = [
            self.create(f"Tagged {index}", content=f"# Tagged {index}\n\nbody {index}\n")
            for index in range(3)
        ]
        added = self.bulk("tag-add", notes, "#shared", "extra")
        self.assertEqual(added["id"], notes[0])
        self.assertEqual(added["ids"], notes)
        self.assertEqual(added["updated"], 3)
        self.assertEqual(sorted(added["tags"]), ["extra", "shared"])
        self.assertIn("#shared", added["content"])
        self.assertIn("#extra", added["content"])
        for identifier in notes:
            content = self.read(identifier)["content"]
            self.assertIn("#shared", content)
            self.assertIn("#extra", content)
        self.assertEqual(
            {tag["tag"] for tag in self.success("tags")["tags"]},
            {"extra", "shared"},
        )

        # A second identical request is a read-only no-op for every note.
        repeated = self.bulk("tag-add", notes, "shared")
        self.assertEqual(repeated["updated"], 0)


class TestTagRemove(StoreTestCase):
    """tag-remove frontmatter/inline rules, code protection and batching."""

    def test_removes_inline_list_frontmatter_and_inline_text(self):
        identifier = self.create(content=(
            "---\n"
            "title: Tagged\n"
            "tags: [alpha, beta, \"gamma\"]\n"
            "aliases: [keep]\n"
            "---\n"
            "\n# Tagged\n\n"
            "hello #alpha world\n"
            "tail #beta\n"
            "code `#alpha` and url https://example.test/#alpha\n\n"
            "```text\n#alpha\n```\n"
        ))
        removed = self.success("tag-remove", identifier, "alpha", "beta")
        self.assertEqual(removed["id"], identifier)
        self.assertEqual(removed["ids"], [identifier])
        self.assertEqual(removed["updated"], 1)
        self.assertEqual(removed["tags"], ["gamma"])

        updated = self.read(identifier)["content"]
        self.assertIn('tags: ["gamma"]', updated)
        self.assertIn("aliases: [keep]", updated)
        self.assertIn("hello world", updated)
        self.assertIn("tail\n", updated)  # the trailing space is collapsed
        self.assertIn("`#alpha`", updated)
        self.assertIn("https://example.test/#alpha", updated)
        self.assertIn("```text\n#alpha\n```", updated)

    def test_removes_block_list_entries_only(self):
        identifier = self.create(content=(
            "---\n"
            "tags:\n"
            "  - alpha\n"
            "  - beta\n"
            "  - gamma\n"
            "title: Block\n"
            "---\n\n# Block\n\nbody\n"
        ))
        removed = self.success("tag-remove", identifier, "beta")
        self.assertEqual(removed["updated"], 1)
        updated = self.read(identifier)["content"]
        self.assertIn("  - alpha\n", updated)
        self.assertNotIn("  - beta\n", updated)
        self.assertIn("  - gamma\n", updated)
        self.assertIn("title: Block\n", updated)

    def test_absent_tag_is_a_byte_for_byte_noop(self):
        identifier = self.create(content="# Noop\n\nnothing to remove\n")
        before = self.note_path(identifier).read_bytes()
        result = self.success("tag-remove", identifier, "missing")
        self.assertEqual(result["updated"], 0)
        self.assertEqual(result["tags"], [])
        self.assertEqual(self.note_path(identifier).read_bytes(), before)

    def test_bulk_removal_updates_only_changed_notes(self):
        first = self.create("First", content="# First\n\nalpha #gamma\n")
        second = self.create(content=(
            "---\ntags: [gamma]\n---\n\n# Second\n\ngamma #gamma\n"
        ))
        code_only = self.create(
            "Code only", content="# Code only\n\n`#gamma` and https://x.test/#gamma\n"
        )

        result = self.bulk("tag-remove", [first, second, code_only], "gamma")
        self.assertEqual(result["id"], first)
        self.assertEqual(result["ids"], [first, second, code_only])
        self.assertEqual(result["updated"], 2)
        self.assertEqual(result["content"], "# First\n\nalpha\n")
        self.assertNotIn("#gamma", result["tags"])
        self.assertEqual(self.read(second)["content"], "---\ntags: []\n---\n\n# Second\n\ngamma\n")
        self.assertEqual(
            self.read(code_only)["content"],
            "# Code only\n\n`#gamma` and https://x.test/#gamma\n",
        )

    def test_unclosed_fence_does_not_block_removal(self):
        identifier = self.create(content=(
            "# Boxed\n\n#gamma outside\n\n```\n#gamma inside\n"
        ))
        removed = self.success("tag-remove", identifier, "gamma")
        self.assertEqual(removed["updated"], 1)
        updated = self.read(identifier)["content"]
        self.assertIn("outside\n", updated)
        self.assertNotIn("#gamma outside", updated)
        self.assertIn("#gamma inside", updated)


class TestTemplates(StoreTestCase):
    """File-backed templates: seeding, CRUD, id safety, and create rendering."""

    def templates_dir(self):
        return self.root / "templates"

    def template_path(self, template_id):
        return self.templates_dir() / f"{template_id}.md"

    def test_seeding_creates_four_templates_with_frontmatter(self):
        listed = self.success("templates", "list")["templates"]
        self.assertEqual([entry["id"] for entry in listed], [
            "daily", "meeting", "project", "tasks"
        ])
        for template_id in ("meeting", "daily", "project", "tasks"):
            path = self.template_path(template_id)
            self.assertTrue(path.is_file(), template_id)
            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith("---\n"), template_id)
            frontmatter, body = text.split("\n---\n", 1)
            self.assertIn("name:", frontmatter)
            self.assertIn("description:", frontmatter)
            self.assertIn("icon:", frontmatter)
            self.assertIn("\n#", "\n" + body)
        meeting = self.template_path("meeting").read_text(encoding="utf-8")
        self.assertIn("name: Meeting notes\n", meeting)
        self.assertIn("description: Attendees, agenda and action items\n", meeting)
        self.assertIn("icon: ◷\n", meeting)
        self.assertIn("# Meeting notes — {{date}}\n", meeting)

    def test_list_shape_and_ordering(self):
        self.success("templates", "save", "zeta", "--name", "Alpha",
                     "--description", "First alphabetically", "--icon", "A",
                     "--content-file", self._body_file("# Alpha\n"))
        listed = self.success("templates", "list")["templates"]
        self.assertEqual(listed[0]["id"], "zeta")
        self.assertEqual(listed[0]["name"], "Alpha")
        self.assertEqual([entry["id"] for entry in listed], [
            "zeta", "daily", "meeting", "project", "tasks"
        ])
        for entry in listed:
            self.assertEqual(set(entry), {
                "id", "name", "description", "icon", "modified"
            })
            self.assertIsInstance(entry["modified"], int)

    def _body_file(self, body):
        path = Path(self._temp.name) / "template-body.md"
        path.write_text(body, encoding="utf-8")
        return str(path)

    def test_save_creates_updates_and_preserves_body_and_unknown_keys(self):
        created = self.success(
            "templates", "save", "weekly-review",
            "--name", "Weekly review",
            "--description", "Plan the week",
            "--icon", "★",
            "--stdin",
            stdin="# Weekly — {{date}}\n\nBody kept.\n",
        )
        self.assertEqual(created["id"], "weekly-review")
        self.assertEqual(created["name"], "Weekly review")
        self.assertEqual(created["description"], "Plan the week")
        self.assertEqual(created["icon"], "★")
        self.assertEqual(created["content"], "# Weekly — {{date}}\n\nBody kept.\n")
        self.assertIsInstance(created["modified"], int)

        # Hand-edit the file to add an unknown frontmatter key, then save only
        # the name: the body and the unknown key must survive verbatim.
        path = self.template_path("weekly-review")
        text = path.read_text(encoding="utf-8")
        frontmatter, body = text.split("\n---\n", 1)
        path.write_text(
            frontmatter + "\nowner: someone\ntags: [meta]\n---\n" + body,
            encoding="utf-8",
        )
        updated = self.success(
            "templates", "save", "weekly-review", "--name", "Week in review")
        self.assertEqual(updated["name"], "Week in review")
        self.assertEqual(updated["description"], "Plan the week")
        self.assertEqual(updated["icon"], "★")
        self.assertEqual(updated["content"], "# Weekly — {{date}}\n\nBody kept.\n")
        saved = path.read_text(encoding="utf-8")
        self.assertIn("owner: someone\n", saved)
        self.assertIn("tags: [meta]\n", saved)
        self.assertEqual(saved.count("owner:"), 1)
        # Owned keys are written first, in a stable order, then unknown keys.
        self.assertLess(saved.index("name:"), saved.index("description:"))
        self.assertLess(saved.index("description:"), saved.index("icon:"))
        self.assertLess(saved.index("icon:"), saved.index("owner:"))

    def test_save_with_content_file_and_stdin(self):
        from_file = self.success(
            "templates", "save", "from-file",
            "--content-file", self._body_file("# From file\n\n{{time}}\n"),
        )
        self.assertEqual(from_file["content"], "# From file\n\n{{time}}\n")
        self.assertEqual(from_file["name"], "From file")  # derived default
        from_stdin = self.success(
            "templates", "save", "from-stdin", "--stdin",
            stdin="# From stdin\n\n{{datetime}}\n",
        )
        self.assertEqual(from_stdin["content"], "# From stdin\n\n{{datetime}}\n")
        self.assertEqual(from_stdin["name"], "From stdin")

    def test_save_quotes_description_containing_colon(self):
        result = self.success(
            "templates", "save", "quoted", "--description", "Plan: the week",
            "--stdin", stdin="# Quoted\n",
        )
        self.assertEqual(result["description"], "Plan: the week")
        text = self.template_path("quoted").read_text(encoding="utf-8")
        self.assertIn('description: "Plan: the week"\n', text)

    def test_invalid_and_escaping_ids_are_rejected(self):
        for bad in ("../escape", "a/b", "a\\b", ".hidden", "..", "   "):
            with self.subTest(bad=bad):
                error = self.failure("templates", "save", bad, "--stdin", stdin="x")
                self.assertIn("template id", error["error"])
                self.assertFalse(
                    (self.root / "escape.md").exists(),
                    "escaped the templates directory",
                )
                self.assertFalse((self.root.parent / "escape.md").exists())
        # Only unusable characters, not a path escape, is also rejected.
        self.assertIn("template id", self.failure(
            "templates", "save", "日本語", "--stdin", stdin="x")["error"])

    def test_ids_are_slugs_and_case_insensitive_collisions_reuse_the_file(self):
        first = self.success(
            "templates", "save", "Weekly_Review!", "--stdin", stdin="# One\n")
        self.assertEqual(first["id"], "weekly-review")
        second = self.success(
            "templates", "save", "WEEKLY-review", "--stdin", stdin="# Two\n")
        self.assertEqual(second["id"], "weekly-review")
        self.assertEqual(second["content"], "# Two\n")
        self.assertEqual(
            sorted(path.name for path in self.templates_dir().glob("*.md")),
            ["daily.md", "meeting.md", "project.md", "tasks.md",
             "weekly-review.md"],
        )

    def test_content_over_the_note_limit_is_rejected(self):
        oversized = "x" * (1024 * 1024 + 1)
        error = self.failure("templates", "save", "huge", "--stdin", stdin=oversized)
        self.assertIn("exceeds", error["error"])
        self.assertFalse(self.template_path("huge").exists())

    def test_delete_removes_and_show_then_fails(self):
        self.success("templates", "save", "temporary", "--stdin", stdin="# Temp\n")
        self.assertTrue(self.template_path("temporary").is_file())
        deleted = self.success("templates", "delete", "temporary")
        self.assertEqual(deleted, {"deleted": True, "id": "temporary"})
        self.assertFalse(self.template_path("temporary").is_file())
        error = self.failure("templates", "show", "temporary")
        self.assertEqual(error["error"], "template not found: temporary")
        again = self.failure("templates", "delete", "temporary")
        self.assertEqual(again["error"], "template not found: temporary")

    def test_create_renders_a_saved_template(self):
        self.success(
            "templates", "save", "weekly-review",
            "--name", "Weekly review",
            "--stdin",
            stdin="# Weekly review — {{date}}\n\nReview at {{time}}. {{nope}}\n",
        )
        identifier = self.success("create", "--template", "weekly-review")["id"]
        content = self.read(identifier)["content"]
        today = datetime.date.today().isoformat()
        self.assertIn(f"# Weekly review — {today}\n", content)
        self.assertNotIn("{{date}}", content)
        self.assertNotIn("{{time}}", content)
        self.assertIn("{{nope}}", content)

    def test_create_unknown_template_names_id_and_lists_available(self):
        error = self.failure("create", "--template", "weekly-review")
        self.assertIn("weekly-review", error["error"])
        for template_id in ("daily", "meeting", "project", "tasks"):
            self.assertIn(template_id, error["error"])

    def test_deleting_every_file_does_not_reseed(self):
        self.success("templates", "list")
        for path in self.templates_dir().glob("*.md"):
            path.unlink()
        self.assertTrue(self.templates_dir().is_dir())
        self.assertEqual(self.success("templates", "list")["templates"], [])
        self.assertEqual(list(self.templates_dir().glob("*.md")), [])
        error = self.failure("create", "--template", "meeting")
        self.assertIn("template not found: meeting", error["error"])


class TestSettings(StoreTestCase):
    """The opaque UI settings channel stored under state.json "ui"."""

    def state_path(self):
        return self.root / "state.json"

    def read_state_file(self):
        return json.loads(self.state_path().read_text(encoding="utf-8"))

    def test_get_on_fresh_root_is_empty_and_creates_nothing(self):
        self.assertEqual(self.success("settings", "get"), {"ui": {}})
        self.assertFalse(self.state_path().exists())
        self.assertFalse(self.root.exists())

    def test_get_treats_a_non_object_ui_as_empty(self):
        self.success("list")
        state = self.read_state_file()
        state["ui"] = ["not", "an", "object"]
        self.state_path().write_text(json.dumps(state), encoding="utf-8")
        self.assertEqual(self.success("settings", "get"), {"ui": {}})

    def test_set_json_round_trips_and_writes_version_one(self):
        written = self.success(
            "settings", "set", "--json", '{"mode": "split", "printCopies": 2}'
        )
        self.assertEqual(written, {"ui": {"mode": "split", "printCopies": 2}})
        self.assertEqual(self.success("settings", "get"), written)
        state = self.read_state_file()
        self.assertEqual(state["version"], 1)
        self.assertEqual(state["ui"], {"mode": "split", "printCopies": 2})

    def test_set_stdin_round_trips(self):
        written = self.success("settings", "set", "--stdin", stdin='{"mode":"edit"}')
        self.assertEqual(written, {"ui": {"mode": "edit"}})
        self.assertEqual(self.success("settings", "get"), {"ui": {"mode": "edit"}})

    def test_set_preserves_pinned_searches_and_other_state(self):
        identifier = self.create("Pinned", content="# Pinned\n\nbody\n")
        self.success("pin", identifier)
        self.success("searches", "add", "tag:alpha", "--label", "Alpha")

        written = self.success("settings", "set", "--json", '{"theme":"dark"}')
        self.assertEqual(written, {"ui": {"theme": "dark"}})

        state = self.read_state_file()
        self.assertEqual(state["version"], 1)
        self.assertEqual(state["pinned"], [identifier])
        self.assertEqual(
            [entry["query"] for entry in state["searches"]], ["tag:alpha"]
        )
        self.assertEqual(state["ui"], {"theme": "dark"})
        self.assertEqual(self.success("settings", "get"), {"ui": {"theme": "dark"}})

    def test_set_replaces_the_whole_object(self):
        self.success("settings", "set", "--json", '{"a":1,"b":2}')
        replaced = self.success("settings", "set", "--json", '{"b":3}')
        self.assertEqual(replaced, {"ui": {"b": 3}})
        self.assertEqual(self.success("settings", "get"), {"ui": {"b": 3}})

    def test_empty_object_clears_settings(self):
        self.success("settings", "set", "--json", '{"a":1}')
        cleared = self.success("settings", "set", "--json", "{}")
        self.assertEqual(cleared, {"ui": {}})
        self.assertEqual(self.success("settings", "get"), {"ui": {}})
        self.assertEqual(self.read_state_file()["ui"], {})

    def test_set_rejects_bad_payloads_without_writing(self):
        cases = [
            (["--json", '{"mode":'], "Settings must be a JSON object"),
            (["--json", "[]"], "Settings must be a JSON object"),
            (["--json", '"text"'], "Settings must be a JSON object"),
            (["--json", "null"], "Settings must be a JSON object"),
            (
                ["--json", json.dumps({"a\x00b": 1})],
                "Settings keys must not contain NUL",
            ),
            (
                ["--json", json.dumps({"k" * 65: 1})],
                "Settings keys must be at most 64 characters",
            ),
            (
                ["--json", json.dumps({"": 1})],
                "Settings keys must be non-empty strings",
            ),
            (
                ["--stdin"],
                "Settings are too large",
            ),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                stdin = (
                    json.dumps({"blob": "x" * (64 * 1024 + 1)})
                    if args == ["--stdin"] else None
                )
                error = self.failure("settings", "set", *args, stdin=stdin)
                self.assertIn(message, error["error"])
        self.assertFalse(self.state_path().exists())

    def test_set_requires_exactly_one_source(self):
        error = self.failure("settings", "set", "--json", "{}", "--stdin")
        self.assertEqual(error["error"], "choose exactly one of --json and --stdin")
        error = self.failure("settings", "set")
        self.assertEqual(error["error"], "choose exactly one of --json and --stdin")
        self.assertFalse(self.state_path().exists())

    def test_sixty_four_character_key_is_accepted(self):
        key = "k" * 64
        written = self.success("settings", "set", "--json", json.dumps({key: True}))
        self.assertEqual(written, {"ui": {key: True}})



class TestStateIntegrity(StoreTestCase):
    """A damaged state.json must never be replaced by a partial rewrite."""

    def corrupt(self):
        path = self.root / "state.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'{"version": 1, "pinned": [\n')
        return path

    def test_mutations_refuse_a_damaged_state_file(self):
        identifier = self.create("Pinned")
        path = self.corrupt()
        damaged = path.read_bytes()
        for args in (
            ("pin", identifier),
            ("searches", "add", "tag:alpha"),
            ("settings", "set", "--json", '{"theme":"dark"}'),
        ):
            with self.subTest(args=args):
                error = self.failure(*args)
                self.assertIn("state.json", error["error"])
                self.assertEqual(path.read_bytes(), damaged)

    def test_reads_still_work_with_a_damaged_state_file(self):
        identifier = self.create("Still listed")
        self.corrupt()
        listing = self.success("list")
        self.assertEqual([note["id"] for note in listing["notes"]], [identifier])
        self.assertFalse(listing["notes"][0]["pinned"])
        self.assertEqual(self.success("settings", "get"), {"ui": {}})
        self.assertEqual(self.success("searches", "list"), {"searches": []})

class TestTagRenameMerge(StoreTestCase):
    """tag-rename onto an existing tag is a merge, with dedupe and `merged`."""

    def test_merge_dedupes_flow_and_block_frontmatter_and_inline_tags(self):
        identifier = self.create(content=(
            "---\n"
            "tags: [project, projects, project]\n"
            "---\n\n"
            "# Merge\n\n"
            "#project #projects #project tail #project\n\n"
            "```text\n#project #project\n```\n"
        ))
        result = self.success("tag-rename", "project", "projects")
        self.assertEqual(result["tag"], "projects")
        self.assertEqual(result["from"], "project")
        self.assertEqual(result["updated"], 1)
        self.assertTrue(result["merged"])

        content = self.read(identifier)["content"]
        self.assertIn("tags: [projects]\n", content)
        self.assertEqual(content.count("#projects"), 1)  # the fence is untouched
        self.assertIn("#projects tail\n", content)
        self.assertIn("```text\n#project #project\n```", content)

        referencing = self.create(content=(
            "---\ntags:\n  - project\n  - projects\n  - project\n---\n\n"
            "# Block\n\nbody\n"
        ))
        block = self.success("tag-rename", "project", "projects")
        self.assertTrue(block["merged"])
        self.assertEqual(block["updated"], 1)
        blocked = self.read(referencing)["content"]
        self.assertEqual(blocked.count("  - projects\n"), 1)
        self.assertNotIn("  - project\n", blocked)

    def test_merge_reports_false_when_destination_did_not_exist(self):
        self.create(content="# Plain\n\n#project\n")
        result = self.success("tag-rename", "project", "projects")
        self.assertEqual(result["updated"], 1)
        self.assertFalse(result["merged"])

    def test_rename_across_fifty_notes_updates_all_and_the_index(self):
        for index in range(50):
            path = self.note_path(f"batch-{index:02d}.md")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                f"# Note {index}\n\nbody #project and #other\n", encoding="utf-8")
        self.success("index", "--rebuild")
        before = self.success("tags")["tags"]
        self.assertEqual(
            {entry["tag"]: entry["count"] for entry in before},
            {"project": 50, "other": 50},
        )

        result = self.success("tag-rename", "project", "projects")
        self.assertEqual(result["updated"], 50)
        self.assertFalse(result["merged"])

        after = {entry["tag"]: entry["count"]
                 for entry in self.success("tags")["tags"]}
        self.assertEqual(after, {"projects": 50, "other": 50})
        for index in range(50):
            content = self.read(f"batch-{index:02d}.md")["content"]
            self.assertIn("#projects", content)
            self.assertNotIn("#project ", content)


class TestTagDelete(StoreTestCase):
    """tag-delete removes a tag everywhere with tag-remove's protections."""

    def test_removes_frontmatter_and_inline_tags_across_notes(self):
        flow = self.create(content=(
            "---\n"
            "title: Flow\n"
            "tags: [alpha, beta]\n"
            "---\n\n"
            "# Flow\n\n"
            "hello #alpha world\n"
            "`#alpha` and https://example.test/#alpha\n\n"
            "```text\n#alpha\n```\n"
        ))
        block = self.create(content=(
            "---\ntags:\n  - alpha\n  - gamma\n---\n\n# Block\n\ntail #alpha\n"
        ))
        untouched = self.create(content="# Untouched\n\nnothing here\n")

        result = self.success("tag-delete", "#ALPHA")
        self.assertEqual(result["tag"], "ALPHA")
        self.assertEqual(result["updated"], 2)

        flow_content = self.read(flow)["content"]
        self.assertIn("tags: [beta]\n", flow_content)
        self.assertIn("hello world\n", flow_content)
        self.assertIn("`#alpha`", flow_content)
        self.assertIn("https://example.test/#alpha", flow_content)
        self.assertIn("```text\n#alpha\n```", flow_content)

        block_content = self.read(block)["content"]
        self.assertNotIn("  - alpha\n", block_content)
        self.assertIn("  - gamma\n", block_content)
        self.assertIn("tail\n", block_content)

        self.assertEqual(
            [entry["tag"] for entry in self.success("tags")["tags"]],
            ["beta", "gamma"],
        )

    def test_absent_tag_is_a_zero_update_noop(self):
        identifier = self.create(content="# Noop\n\nnothing to delete\n")
        before = self.note_path(identifier).read_bytes()
        result = self.success("tag-delete", "missing")
        self.assertEqual(result, {"tag": "missing", "updated": 0, "ids": []})
        self.assertEqual(self.note_path(identifier).read_bytes(), before)

    def test_tag_with_no_comparable_characters_is_refused(self):
        error = self.failure("tag-delete", "日本語")
        self.assertIn("no comparable characters", error["error"])


if __name__ == "__main__":
    unittest.main()
