"""Retry semantics of the Joplin client in tools/omanano-joplin-sync.

Only Joplin.request is covered: the sync itself needs a live clipper service.
Every case fakes urllib so nothing touches the network or a real Joplin.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYNC = ROOT / "tools" / "omanano-joplin-sync"


def load_sync():
    loader = importlib.machinery.SourceFileLoader("omanano_sync", str(SYNC))
    spec = importlib.util.spec_from_loader("omanano_sync", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return json.dumps(self.payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class JoplinRequestTest(unittest.TestCase):
    def setUp(self):
        self.sync = load_sync()
        self.api = self.sync.Joplin("http://example.test", "token")
        # Retries sleep 0.5 s; keep the suite quick without touching the clock
        # outside these tests.
        patcher = mock.patch.object(self.sync.time, "sleep", lambda _seconds: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_with(self, outcomes, verify=None, **kwargs):
        calls = []

        def fake_urlopen(request, timeout=None):
            calls.append(request.full_url)
            outcome = outcomes[min(len(calls), len(outcomes)) - 1]
            if isinstance(outcome, Exception):
                raise outcome
            return FakeResponse(outcome)

        with mock.patch.object(self.sync.urllib.request, "urlopen", fake_urlopen):
            try:
                result = self.api.request(
                    "POST", "/notes", body={"title": "x"}, verify=verify, **kwargs)
            finally:
                self.call_count = len(calls)
        return result

    def test_a_lost_response_is_recovered_without_a_second_post(self):
        recovered = {"id": "abc", "source_url": "omanano://a.md"}
        result = self.run_with(
            [urllib.error.URLError("connection reset")], verify=lambda: recovered)
        self.assertEqual(result, recovered)
        self.assertEqual(self.call_count, 1, "the POST was sent twice")

    def test_a_500_is_recovered_the_same_way(self):
        error = urllib.error.HTTPError(
            "http://example.test", 500, "boom", {}, io.BytesIO(b""))
        result = self.run_with([error], verify=lambda: {"id": "abc"})
        self.assertEqual(result["id"], "abc")
        self.assertEqual(self.call_count, 1)

    def test_without_a_match_the_post_is_retried(self):
        result = self.run_with(
            [urllib.error.URLError("down"), {"id": "fresh"}],
            verify=lambda: None)
        self.assertEqual(result["id"], "fresh")
        self.assertEqual(self.call_count, 2)

    def test_a_second_lost_response_still_consults_verify(self):
        error = urllib.error.URLError("down")
        # First attempt: no note yet. Second: the note exists after all.
        answers = iter([None, {"id": "late"}])
        result = self.run_with([error, error], verify=lambda: next(answers))
        self.assertEqual(result["id"], "late")

    def test_a_client_error_is_not_retried_and_skips_verify(self):
        error = urllib.error.HTTPError(
            "http://example.test", 400, "bad", {}, io.BytesIO(b""))
        asked = []
        with self.assertRaises(self.sync.JoplinError):
            self.run_with([error], verify=lambda: asked.append(1))
        self.assertEqual(asked, [])
        self.assertEqual(self.call_count, 1)

    def test_giving_up_reports_the_failure(self):
        error = urllib.error.URLError("down")
        with self.assertRaises(self.sync.JoplinError):
            self.run_with([error, error], verify=lambda: None)
        self.assertEqual(self.call_count, 2)


if __name__ == "__main__":
    unittest.main()
