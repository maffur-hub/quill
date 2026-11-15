"""Daemon protocol tests for scripts/quill-store __serve.

Every server runs against a disposable data root (QUILL_DATA_DIR) with
QUILL_E2E=1. The live ~/.local/share/quill directory is never read or written.
"""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "scripts" / "quill-store"
BRIDGE = ROOT / "scripts" / "quill-daemon"


class DaemonTestCase(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="quill-daemon-test-")
        self.root = Path(self._temp.name) / "quill"
        self.socket_path = Path(self._temp.name) / "quill.sock"
        self.env = dict(os.environ)
        self.env.pop("QUILL_E2E_ALLOW_REAL", None)
        self.env["QUILL_DATA_DIR"] = str(self.root)
        self.env["QUILL_E2E"] = "1"
        self.env["QUILL_VERSION_RETENTION"] = "50"
        self.env["QUILL_VERSION_THROTTLE"] = "0"
        self.env.pop("QUILL_SOCKET", None)
        self.process: subprocess.Popen | None = None
        self.stream = None
        self.client: socket.socket | None = None

    def tearDown(self):
        if self.client is not None:
            try:
                self.request({"op": "shutdown"})
            except (OSError, ValueError):
                pass
            try:
                self.client.close()
            except OSError:
                pass
            self.client = None
            self.stream = None
        if self.process is not None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            for handle in (self.process.stdout, self.process.stderr):
                if handle is not None:
                    handle.close()
            self.process = None
        self._temp.cleanup()

    # -- helpers -----------------------------------------------------------

    def start_server(self):
        self.process = subprocess.Popen(
            [
                sys.executable,
                str(STORE),
                "__serve",
                "--socket",
                str(self.socket_path),
                "--idle",
                "0",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            cwd=str(ROOT),
        )
        deadline = time.monotonic() + 10.0
        last_error = None
        while time.monotonic() < deadline:
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(1.0)
                client.connect(str(self.socket_path))
            except OSError as error:
                last_error = error
                if client is not None:
                    client.close()
                time.sleep(0.05)
                continue
            client.settimeout(10.0)
            self.client = client
            self.stream = client.makefile("rwb", buffering=0)
            return
        self.fail(f"daemon did not start on {self.socket_path}: {last_error}")

    def request(self, payload) -> dict:
        if isinstance(payload, bytes):
            line = payload
        else:
            line = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        self.stream.write(line)
        reply = self.stream.readline()
        if not reply:
            raise RuntimeError("daemon closed the connection without replying")
        value = json.loads(reply.decode("utf-8"))
        self.assertIsInstance(value, dict)
        return value

    def command(self, *args, stdin=None, request_id=None) -> dict:
        payload: dict = {"args": list(args)}
        if request_id is not None:
            payload["id"] = request_id
        if stdin is not None:
            payload["stdin"] = stdin
        return self.request(payload)

    def success(self, *args, stdin=None, request_id=None) -> dict:
        reply = self.command(*args, stdin=stdin, request_id=request_id)
        self.assertTrue(reply.get("ok"), reply)
        self.assertNotIn("error", reply)
        return reply["result"]

    # -- tests -------------------------------------------------------------

    def test_create_write_read_and_error_recovery(self):
        self.start_server()

        created = self.success("create", "--title", "From the daemon", request_id=1)
        self.assertIn("id", created)
        note_id = created["id"]
        reply = self.command("list", request_id=2)
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["id"], 2)
        ids = [note["id"] for note in reply["result"]["notes"]]
        self.assertIn(note_id, ids)

        payload = "# Written through the socket\n\nbody bytes\n"
        written = self.success("write", note_id, "--stdin", stdin=payload)
        self.assertEqual(written["id"], note_id)
        self.assertEqual(written["size"], len(payload.encode("utf-8")))
        on_disk = (self.root / "notes" / note_id).read_bytes()
        self.assertEqual(on_disk, payload.encode("utf-8"))

        read = self.success("read", note_id)
        self.assertEqual(read["content"], payload)

        failed = self.command("read", "missing-note", request_id=3)
        self.assertFalse(failed["ok"])
        self.assertIsInstance(failed["error"], str)
        self.assertTrue(failed["error"])
        self.assertEqual(failed["id"], 3)

        malformed = self.request(b"this is not json\n")
        self.assertFalse(malformed["ok"])
        self.assertIsInstance(malformed["error"], str)

        still_alive = self.request({"op": "ping", "id": 4})
        self.assertTrue(still_alive["ok"], still_alive)
        self.assertEqual(still_alive["id"], 4)

    def test_an_error_reply_carries_the_cli_error_code(self):
        """A machine-readable reason must survive the daemon, not just the CLI.

        The UI decides whether to offer the "changed on disk" banner from
        `code`, so unwrapping the JSON error down to its message is not enough.
        """
        self.start_server()
        note_id = self.success("create", "--title", "Guarded")["id"]
        self.success("write", note_id, "--stdin", stdin="# Guarded\n\nfirst\n")
        reply = self.command(
            "write", note_id, "--stdin", "--if-mtime", "1",
            stdin="# Guarded\n\nsecond\n")
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply.get("code"), "stale", reply)
        self.assertIn("changed on disk", reply["error"])

    def test_ping_reports_temp_root_and_shutdown_stops_the_process(self):
        self.start_server()
        self.assertIsNotNone(self.process)
        ping = self.request({"op": "ping"})
        self.assertTrue(ping["ok"], ping)
        ping = ping["result"]
        self.assertEqual(ping["dataRoot"], str(self.root.resolve()))
        self.assertEqual(ping["pid"], self.process.pid)
        self.assertIsInstance(ping["notes"], int)
        self.assertIsInstance(ping["watcher"], bool)
        self.assertEqual(ping["version"], 3)

        reply = self.request({"op": "shutdown", "id": 9})
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"], {"stopped": True})
        self.assertEqual(reply["id"], 9)
        self.process.wait(timeout=5)
        self.assertEqual(self.process.returncode, 0)

    def test_schema_v3_drops_notes_body(self):
        self.start_server()
        rebuilt = self.success("index", "--rebuild")
        self.assertIn("notes", rebuilt)
        database = self.root / "index.db"
        self.assertTrue(database.exists())
        conn = sqlite3.connect(str(database))
        try:
            columns = [row[1] for row in conn.execute("PRAGMA table_info(notes)")]
            version = int(conn.execute("PRAGMA user_version").fetchone()[0])
        finally:
            conn.close()
        self.assertNotIn("body", columns)
        self.assertEqual(version, 3)


class ServeGuardTest(unittest.TestCase):
    """`__serve` must refuse the live root under the E2E harness.

    The watcher indexes files, which is a write to the real index, so the
    read-only exemption for commands does not apply to serving. This test
    never passes QUILL_DATA_DIR, so the guard is what stops it.
    """

    def test_serve_refuses_the_real_root_under_e2e(self):
        with tempfile.TemporaryDirectory(prefix="quill-serve-guard-") as temp:
            socket_path = Path(temp) / "guard.sock"
            env = dict(os.environ)
            env.pop("QUILL_DATA_DIR", None)
            env.pop("QUILL_SOCKET", None)
            env.pop("QUILL_E2E_ALLOW_REAL", None)
            env["QUILL_E2E"] = "1"
            completed = subprocess.run(
                [sys.executable, str(STORE), "__serve", "--socket", str(socket_path)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                cwd=str(ROOT),
                timeout=30,
            )
            self.assertEqual(completed.returncode, 1, completed.stderr)
            payload = json.loads(completed.stderr.decode("utf-8").strip())
            self.assertIn("refuses to serve the real Quill data root", payload["error"])
            self.assertFalse(socket_path.exists())


class BridgeEofTest(unittest.TestCase):
    """The stdio bridge must not drop a reply that is still in flight."""

    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="quill-bridge-test-")
        self.folder = Path(self._temp.name)
        self.socket_path = self.folder / "stub.sock"
        self.env = dict(os.environ)
        self.env["QUILL_DATA_DIR"] = str(self.folder / "quill")
        self.env["QUILL_E2E"] = "1"
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.socket_path))
        self.server.listen(4)
        self.delay = 2.0

    def tearDown(self):
        self.server.close()
        self._temp.cleanup()

    def serve(self):
        try:
            probe, _ = self.server.accept()  # ensure_server's readiness probe
            probe.close()
            connection, _ = self.server.accept()
            with connection:
                for line in connection.makefile("rb"):
                    request = json.loads(line.decode("utf-8"))
                    time.sleep(self.delay)
                    connection.sendall(
                        json.dumps({"ok": True, "args": request["args"]}).encode("utf-8")
                        + b"\n")
        except OSError:
            pass

    def test_a_slow_reply_reaches_a_caller_that_closed_stdin(self):
        thread = threading.Thread(target=self.serve, daemon=True)
        thread.start()
        process = subprocess.run(
            [sys.executable, str(BRIDGE), "--socket", str(self.socket_path)],
            input=b'{"args": ["read", "a.md"]}\n',
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            timeout=30,
        )
        self.assertEqual(process.returncode, 0, process.stderr.decode("utf-8", "replace"))
        replies = [json.loads(line) for line in process.stdout.decode("utf-8").splitlines()]
        self.assertEqual([reply.get("args") for reply in replies], [["read", "a.md"]])


if __name__ == "__main__":
    unittest.main()
