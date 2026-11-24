# Quill regression tests

This directory is the safety net for the Quill notes plugin. It contains
behavioural tests for the shared JavaScript modules and contract tests for the
`scripts/quill-store` backend, plus a benchmark for the store CLI.

Nothing here changes product behaviour. If a test exposes a real bug, the
product code stays untouched and the failure is reported.

## Safety rules

- Tests and benchmarks **never** read or write the live data root
  `~/.local/share/quill`.
- Every store test creates a `tempfile.TemporaryDirectory`, points
  `QUILL_DATA_DIR` at it, and sets `QUILL_E2E=1`.
- `QUILL_E2E_ALLOW_REAL` is removed from the child environment and must never
  be set. The guard exists so a mistaken command fails instead of touching real
  notes.
- The benchmark creates disposable roots with `tempfile.mkdtemp()` and removes
  them by default.

## Requirements

- Node.js 18 or newer (`node:test`, `node:assert`; the suite is developed on
  Node 26).
- Python 3.10 or newer. Tests use the standard library `unittest` only —
  pytest is not required or installed.
- The repository's `scripts/quill-store` must be executable.

## Run everything

```sh
scripts/test
```

This runs all four suites and exits non-zero if any fails.

## JavaScript suite

```sh
node --test tests/js
```

The plugin's shared modules are plain ES5 with no Qt imports. Most declare
top-level functions rather than `module.exports`, so each test loads the file
with `node:vm` into a fresh context and reads the functions from that context:

```js
const { load } = require('./helpers/load')
const { plan } = load('MarkdownFormat.js')
```

`WritableGuard.js` starts with QML's `.pragma library` line, which is not valid
JavaScript; `helpers/load.js` strips that first line before evaluation. Test
shims live in the test context, never in the product file.

Results crossing the vm realm boundary have different prototypes, so structured
comparisons use `deepEqual()` from `helpers/load.js`, which copies the value
through JSON before a strict assertion.

Covered modules:

| File | Coverage |
| --- | --- |
| `MarkdownFormat.js` | `plan()` for bold, italic, heading, bullet/numbered lists, links, inline code, code blocks, tables, rules, clear formatting, selection replacement/restoration, no-op and error edges. |
| `TableEngine.js` | GFM parse/render, row/column helpers, A1 references, SUM/AVERAGE/MIN/MAX/COUNT/ROUND/ABS/IF and the error codes. |
| `TagSuggest.js` | `suggest()` ranking/exclusion/known tags and `normalizeTag()` folding. |
| `MathSyntax.js` | Inline `$...$`, display `$$...$$`, and exclusion inside fenced/inline code, currency, and escapes. |
| `ImageSizing.js` | Brace/Obsidian image size forms, block splitting, display sizing, rewrite helpers. |
| `EmojiData.js` | `filter()` by name and keyword, case-insensitive, empty query. |
| `WritableGuard.js` | Path normalisation, live-root detection, write permission, mutating-command classification. |

## Store suite

```sh
python3 -m unittest discover -s tests/store -v
```

`tests/store/test_store.py` invokes `scripts/quill-store` as a subprocess with
a disposable `QUILL_DATA_DIR` and `QUILL_E2E=1`. Each test starts from a fresh
root. The helper asserts the process contract for every call:

- success: exit 0, empty stderr, exactly one JSON object on stdout;
- failure: exit 1, empty stdout, exactly one JSON object with a non-empty
  `error` string on stderr.

Covered behaviour: CLI contract, create/list/read roundtrip, folder creation,
stdin and `--content-file` writes, LF/CRLF preservation, size/modified fields,
rename/move/duplicate/pin, trash/restore/delete/empty-trash, version snapshots
and exact-byte restore (including recovery of the state replaced by a restore),
exact/prefix/fuzzy search with trashed notes excluded, tags and tag rename,
backlinks and wiki-link preview rewriting, folder create/rename/delete with and
without `--force`, attachment save/list/gc, draft read/write/discard semantics,
and idempotent `index --rebuild`.

The full command surface, JSON shapes, environment variables, storage and
locking guarantees are documented in [`docs/cli-contract.md`](../docs/cli-contract.md).

## Benchmark

```sh
scripts/bench
scripts/bench --notes 200
scripts/bench --notes 2000 --keep
scripts/bench --runs 5
```

The benchmark populates a small library (16 notes) and a large library (2000
notes by default), each note roughly 4 KiB. It reports the median of
`--runs` (default 3) wall-clock runs for:

- `index --rebuild`
- `list`
- `search "the" --limit 20`
- `tags`
- one 4 KiB `write`
- one `read`

It also reports total note bytes and the final `index.db` size. Temporary roots
are deleted unless `--keep` is passed. The live root is checked and refused.

Reference numbers on the development machine (sanity only; timings vary):

```text
2k notes: rebuild ~3.1 s, list ~200 ms, search ~174 ms, tags ~167 ms,
          write ~112 ms, read ~94 ms, index ~18.2 MB
```

## Adding tests

- JavaScript: add a `*.test.js` file under `tests/js/`. Import `load` from
  `helpers/load.js`; do not add `module.exports` or Qt shims to product files.
- Store: add a `Test*` class or method under `tests/store/test_store.py` using
  the `StoreTestCase` helpers (`success`, `failure`, `create`, `read`). Keep
  assertions independent of exact mtimes and result ordering where it is not
  part of the contract.
- Never point `QUILL_DATA_DIR` at the live root, not even for a read, and never
  set `QUILL_E2E_ALLOW_REAL=1`.
