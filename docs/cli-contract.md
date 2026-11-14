# Quill store CLI contract

`scripts/quill-store` is the backend seam between the QML front end and the
Markdown files on disk. This document describes the observable contract: the
commands, their arguments, stdin conventions, JSON shapes, error behaviour,
environment variables, and the storage guarantees a replacement daemon (for
example a Rust rewrite) must preserve.

The implementation is the authority. Everything here was read from
`scripts/quill-store` itself (`build_parser()` and `command_*()`), not from the
UI.

## Invocation

```text
quill-store <command> [options]
quill-store -h
quill-store <command> -h
```

Top-level commands:

```text
list read write draft create duplicate rename move trash restore delete pin
empty-trash versions restore-version folder search titles searches settings tags
templates tag-rename tag-delete tag-add tag-remove backlinks unresolved preview
import-omanano index attachment stats
```

Nested commands:

```text
draft       discard <id>
folder      create <path>
            rename <path> <new>
            delete <path> [--force]
searches    list
            add <query> [--label LABEL]
            remove <query>
settings    get
            set (--json JSON | --stdin)
templates   list
            show <id>
            save <id> [--name N] [--description D] [--icon I]
                      (--content-file FILE | --stdin)
            delete <id>
attachment  save (--file FILE | --stdin) [--name NAME]
            list
            gc [--dry-run]
```

## Process contract

### One JSON object

A successful command writes **exactly one** JSON object to stdout followed by a
newline, and exits **0**. It writes nothing to stderr.

A failure writes **exactly one** JSON object to stderr followed by a newline,
writes nothing to stdout, and exits **1**:

```json
{"error": "note not found: 20260101T000000Z-deadbeef.md"}
```

`error` is always a non-empty string. `StoreError`, `FileNotFoundError`,
`PermissionError`, `sqlite3.Error`, `ValueError`, `OSError`, and unexpected
exceptions all use this shape. An unexpected exception is reported as
`"TypeName: message"`.

Exit code **2** is reserved for argparse usage errors (an unknown command, a
missing required argument, an invalid choice). Those messages are argparse's
plain-text `usage:` output, not JSON. Clients should treat any non-zero exit as
failure and only parse stderr as JSON when the exit code is 1.

Argument validation happens after the E2E guard, so a refused live-root
mutation is a normal JSON error with exit 1.

### stdin

Only these commands read stdin:

| Command | When |
| --- | --- |
| `write <id>` | Reads the new body from stdin unless `--content-file` is given. `--stdin` is accepted but is not required. |
| `create --content-stdin` | Reads the initial note body from stdin. |
| `templates save <id> --stdin` | Reads the template body from stdin. Without it the stored body is kept. |
| `attachment save --stdin` | Reads the attachment bytes from stdin. |

Payloads are read as bytes with a hard cap (1 MiB for notes and template
bodies, 20 MiB for attachments). Note and template payloads must decode as
strict UTF-8.

## Export helpers

`scripts/quill-export-html` and `scripts/quill-export-pdf` are Node CLIs for
the **Export** dialog. They are outside the store contract: they do not talk to
the socket or the daemon, and they never touch the data root. Both take the
note body from a file, so the dialog can export the live editor buffer without
saving.

```
quill-export-html --input <md> --output <html> --title <title>
                  [--note-dir <dir>] [--color <css-color>] [--font-px <n>]

quill-export-pdf  --input <md> --output <pdf> --title <title>
                  [--note-dir <dir>] [--color <css-color>] [--font-px <n>]
                  [--page-size <css-page-size>] [--page-margin <css-length>]
                  [--chromium <path>] [--keep-html]
```

Both follow the same stdout and error conventions, not the JSON-in/JSON-out
shape of the daemon:

- Success writes **exactly one** JSON object to stdout followed by a newline
  and exits **0**. `quill-export-html` reports
  `{"ok":true,"bytes":n,"math":n,"images":n,"warnings":n}`;
  `quill-export-pdf` reports
  `{"ok":true,"bytes":n,"engine":"<browser basename>","pageSize":"...","htmlBytes":n}`,
  plus `htmlPath` when `--keep-html` was passed.
- Failure writes exactly one line, `quill-export-html: <message>` or
  `quill-export-pdf: <message>`, to stderr, writes nothing to stdout, exits
  **1**, and leaves any existing output file untouched.
- `--input` must be a readable file and the `--output` parent must exist; the
  helpers do not create directories.
- Both write atomically through a sibling temporary file and a rename.

`quill-export-pdf` shells out to `quill-export-html` for a standalone HTML
file, injects an `@page { size: ...; margin: ...; }` print stylesheet, and
prints it with a headless Chromium-based browser. The browser is discovered
from `--chromium`, then `$QUILL_CHROMIUM`, then the first executable on `PATH`
among `chromium`, `chromium-browser`, `google-chrome-stable`, `google-chrome`,
`brave`, `brave-browser`, `microsoft-edge-stable` and `microsoft-edge`. The
HTML file and the browser profile live in a temporary directory; it is removed
on every run except a successful `--keep-html`, where the JSON reports the kept
file. `--page-size` defaults to `A4` and `--page-margin` to `18mm`; both are
validated so a value cannot escape the `@page` rule.

## Daemon

The CLI stays the contract. The optional daemon serves the **same commands**
over a Unix socket so the UI pays one process start instead of one per command,
and keeps the SQLite index warm and current between requests.

### Socket path

Resolution order:

1. `$QUILL_SOCKET`, expanded and resolved.
2. `$XDG_RUNTIME_DIR/quill-<sha1(ROOT + "|" + store stamp)[:12]>.sock`.
3. `/tmp/quill-<...>.sock` when `XDG_RUNTIME_DIR` is unset.

The store stamp is the size and `mtime_ns` of the `quill-store` file itself, so
upgrading the store yields a new socket: the previous daemon keeps serving its
old command table until its idle timeout, and a new one starts with the new one.

The socket is never placed inside the data root, and every socket path that
would resolve under `ROOT` is redirected to `/tmp`. The server chmods it to
`0600` after binding, listens with a backlog of 64, and unlinks it on exit.

### `quill-store __serve`

```text
quill-store __serve [--socket PATH] [--no-watch] [--idle SECONDS]
```

Starts a foreground server (there is no `--foreground`; it already is one).
`--idle` exits after that many seconds with zero connections (default `0` =
never). On exit the command prints `{"stopped": true, "socket": "<path>"}`.
If another daemon already answers on the socket, it fails with
`StoreError("quill daemon already running on <path>")`.

Every served command goes through the same parser, E2E guard, command
functions and one-JSON-object output path as the CLI. Commands are serialised
with an in-process lock plus the usual `flock`; the socket path itself is not
watched or indexed.

### Request and response shapes

One JSON object per `\n`-terminated line, up to 32 MiB per line. Requests:

```json
{"id": 1, "args": ["list"]}
{"id": 2, "args": ["write", "note.md", "--stdin"], "stdin": "# Body\n"}
{"id": 3, "args": ["search", "-tag", "--limit", "20"]}
{"op": "ping"}
{"op": "shutdown"}
```

`args` is the argv the CLI would have received (without `quill-store`). `stdin`
is the UTF-8 text the command should read instead of a real pipe; when absent
the command sees empty input. `id` is opaque and only echoed back.

Success replies:

```json
{"id": 1, "ok": true, "result": {"notes": [], "folders": [], "tags": [], "trashCount": 0, "totalCount": 0, "maxNoteBytes": 1048576}}
```

The `id` key is omitted when the request had none. Failures never repeat the
stderr JSON; the error string is unwrapped:

```json
{"id": 1, "ok": false, "error": "note not found: missing.md"}
```

Malformed lines get `{"ok": false, "error": "..."}` and the connection stays
open. A traceback never reaches the wire. A request larger than the line cap
is refused with `{"ok": false, "error": "request too large"}`; a stream with no
newline in 32 MiB is closed because it cannot be resynchronised.

`{"op": "ping"}` returns:

```json
{"ok": true, "result": {"pid": 1234, "dataRoot": "/home/me/.local/share/quill", "notes": 42, "watcher": true, "version": 3}}
```

`notes` is the live count from the index, or `-1` when the index is absent or
unreadable. `{"op": "shutdown"}` replies
`{"ok": true, "result": {"stopped": true}}` and stops that same process.

### Events

Connections also receive unsolicited lines. They carry no `id`:

```json
{"event": "notes", "ids": ["Inbox/new.md"], "removed": []}
{"event": "notes", "ids": [], "removed": ["Old.md"]}
{"event": "notes", "ids": [], "removed": [], "full": true}
```

Events are `notes` only. `ids` are note ids (relative to `notes/` or `trash/`)
that were indexed; `removed` are ids whose rows were deleted. `full: true`
means the watcher could not map a change confidently and ran `sync_index`; the
client should refetch rather than patch. Events are queued per connection and
written by one writer thread, so ordering within a connection is stable.

### `scripts/quill-daemon`

Python 3 bridge that loads `scripts/quill-store` with
`spec_from_file_location` + a `SourceFileLoader` (the store is import-safe;
only `main()` is guarded). It inherits the caller's environment, including
`QUILL_DATA_DIR` and `QUILL_E2E`, so it serves the same data root.

Serving is refused under `QUILL_E2E=1` when the resolved root is the real
library: the watcher indexes files, so unlike a read-only command a server
would write the real index. A QML harness that forgets to pass a data root
falls back to one process per command instead of starting a live daemon.

```text
scripts/quill-daemon                  ensure a server, then bridge stdio
scripts/quill-daemon --status         ping; exit 0 when running, 1 when not
scripts/quill-daemon --stop           shutdown; exit 0 even if none was running
scripts/quill-daemon --socket PATH    override the socket path
scripts/quill-daemon --no-watch       spawn the server without the watcher
```

In bridge mode it connects to `daemon_socket_path()`. On refusal it spawns
`python3 scripts/quill-store __serve --socket <path> --idle 120` detached
(`start_new_session=True`), appending stdout/stderr to `<data>/.daemon.log`
(truncated when it exceeds 1 MiB), then polls every 50 ms for up to 8 s.
stdout carries only newline-delimited JSON: each daemon line is copied
verbatim and flushed, one line per response/event. EOF from the daemon exits
the bridge so the caller's `onExited` fires. The main thread validates each
stdin line is an object with an `args` list, forwards it verbatim, and on
stdin EOF closes the socket and exits 0 after a 1 s grace. Diagnostics go to
stderr only.

`--status` prints `{"running": true, ...ping result}` or
`{"running": false, "socket": "..."}`. `--stop` prints `{"stopped": true}` or
`{"stopped": false, ...}`.

### Watcher and `INDEX_TRUSTED`

When the server starts with watching enabled it attaches an inotify watcher
(ctypes `libc.so.6`) to `notes/`, `trash/` and every subdirectory, with mask
`IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE |
IN_DELETE_SELF | IN_MOVE_SELF`. Only `.md` files matter. New or moved-in
directories get watches recursively.

Events are debounced for ~0.4 s, then under the in-process lock + `flock`:

- An existing touched note is reindexed with `index_and_resolve`.
- A gone note has its `notes`, `tags`, `links` and `notes_fts` rows deleted and
  the affected target norms re-resolved (mirroring `sync_index`).
- A directory create/move/delete, a moved watch, an unmappable watch
  descriptor, or an inotify queue overflow falls back to `sync_index(full=False)`
  and broadcasts an empty `ids` list with `"full": true`.

One commit is made, locks are released, then the event is broadcast. Any
ctypes or OS error disables the watcher and resets `INDEX_TRUSTED` to false;
the server itself keeps running. After a successful attach the server runs one
initial `sync_index` and only then sets `INDEX_TRUSTED = True`.
`with_index()` skips `sync_index` while the flag is true; mutating commands
still index their own changes explicitly. With `--no-watch` the flag is never
set, so every command syncs exactly like the non-daemon CLI. The non-daemon
path always leaves it false.

## Benchmarking

`scripts/bench` builds disposable small (16 note) and large (2000 by default)
libraries, then reports medians for `index --rebuild`, `list`, `search`,
`tags`, one `write --stdin` and one `read`. Every run uses a fresh temporary
`QUILL_DATA_DIR` and `QUILL_E2E=1`; the live root is never touched.

```text
scripts/bench [--notes N] [--runs N] [--keep] [--daemon]
```

By default each measurement starts one CLI process (the linear
"process-per-command" behaviour). `--daemon` starts one `__serve` per library
on a socket inside that library's temporary root, waits for it, and times the
same commands through **one persistent connection**, sending a JSON line and
reading the reply's `result`. The title line is marked `(daemon)` and the
table format, medians and validation checks are identical. The server is shut
down and the socket removed in a `finally` block.

## Commands and output shapes

All paths called `id` are **note ids relative to the relevant root**, using
forward slashes, for example `Work/20260101T000000Z-deadbeef.md`. Live ids are
relative to `<root>/notes`; trash ids are relative to `<root>/trash`.
`modified` and `mtime` are integer Unix milliseconds. `size` is bytes.

### Bulk operations

`trash`, `restore`, `delete`, `move`, `pin`, `tag-add`, and `tag-remove` accept a
repeatable `--id ID`. The required positional `id` is still the **primary**
note. Arguments are processed as `[id, --id ...]`, deduplicated while preserving
that order.

Every id is resolved and checked for existence before any write, so a missing
note aborts the whole call: exit 1, an error naming the missing id, and no note
touched. All file work happens inside one exclusive lock, and the SQLite index
is refreshed **once at the end** of the batch, not once per note.

`id` always describes the primary note (or its post-write id); `ids` lists every
resulting id in order, and `count` is the number of notes affected where the
command reports it.

### Read-only commands

#### `list [--trashed]`

Lists notes from the index, sorted by pinned first, then `modified` descending,
then title case-insensitively. At most 2000 notes are returned. Ids beginning
`.quill-` are hidden. `--trashed` lists notes in the trash instead.

```json
{
  "notes": [
    {
      "id": "Work/20260101T000000Z-deadbeef.md",
      "title": "Title",
      "snippet": "first useful line of body text",
      "folder": "Work",
      "modified": 1767225600000,
      "tags": ["alpha", "beta"],
      "pinned": false,
      "size": 1234,
      "trashed": true
    }
  ],
  "folders": ["Work", "Work/Sub"],
  "tags": [{"tag": "alpha", "count": 2}],
  "trashCount": 0,
  "totalCount": 1,
  "maxNoteBytes": 1048576
}
```

`trashed` is present only in a `--trashed` listing. `pinned` is always false
for trashed notes. `totalCount` is always the live-note count and `trashCount`
is always the number of notes in the trash, regardless of `--trashed`.
`folders` is derived from directories under `<root>/notes` plus folders
reported by indexed notes, sorted case-insensitively. `tags` counts live notes
only.

#### `read <id> [--trashed]`

```json
{
  "id": "Work/note.md",
  "content": "# Title\n\nbody\n",
  "tooLarge": false,
  "size": 1234,
  "modified": 1767225600000,
  "maxBytes": 1048576
}
```

When the file is over 1 MiB, `content` is `""` and `tooLarge` is `true`. A live
note with an adjacent draft that differs from the note (after newline
normalisation) adds:

```json
"draft": {"content": "# Title\n\nunsaved\n", "modified": 1767225600000}
```

Trashed notes never advertise drafts.

#### `titles [--limit N]`

Returns live note titles for the quick switcher, without bodies, snippets, or
tags. `limit` is clamped to 1..20000; the default is 5000. Trashed notes and
ids beginning `.quill-` are excluded. Ordering is pinned first, then `modified`
descending, then id.

```json
{
  "notes": [
    {
      "id": "Work/20260101T000000Z-deadbeef.md",
      "title": "Title",
      "folder": "Work",
      "modified": 1767225600000,
      "pinned": false
    }
  ]
}
```

#### `search <query> [--limit N]`

`limit` is clamped to 1..500; the default is 50. The query is a small grammar,
and the same result shape is returned in every case:

```json
{
  "results": [
    {
      "id": "note.md",
      "title": "Title",
      "snippet": "…matched text…",
      "folder": "",
      "tags": ["alpha"],
      "modified": 1767225600000,
      "pinned": false,
      "size": 1234,
      "fuzzy": true
    }
  ],
  "fuzzy": false
}
```

Grammar:

- **Free text** is split on whitespace. Each word is a quoted FTS5 prefix
  (`"term"*`, up to 12 positive words) and words are AND-joined, so `zeb`
  matches `zebra`.
- **Quoted phrases** (`"exact phrase"`) are one FTS5 phrase with no prefix
  star. A doubled quote inside the phrase is a literal quote. An unterminated
  quote fails with `{"error": "unterminated quote in search query"}`.
- **`tag:NAME`** requires a tag, compared through the same normalised key as
  storage (accents folded, case-insensitive, spaces become `-`). Several
  `tag:` filters are AND. Quoted values are accepted: `tag:"my tag"`.
- **`folder:NAME`** matches a note whose folder is `NAME` case-insensitively
  or is a child path `NAME/...`. `folder:` with an empty value matches the
  Inbox (folder `""`). Quoted values are accepted; `LIKE` wildcards in the
  value are escaped. `folder:Projects` therefore matches both `Projects` and
  `Projects/Sub`, but not `Archive/Projects`.
- **`before:YYYY-MM-DD`** keeps notes with `mtime_ms` strictly before local
  midnight on that date. **`after:YYYY-MM-DD`** keeps notes at or after local
  midnight. Only the strict `YYYY-MM-DD` form is accepted; anything else fails
  with `{"error": "invalid date in after:VALUE; expected YYYY-MM-DD"}`.
- **Negation**: a leading `-` before any word, phrase, or filter excludes it:
  `-word`, `-tag:alpha`, `-folder:Archive`, `-before:2026-10-01`,
  `-after:2026-10-01`. Negative free text is applied as
  `n.key NOT IN (SELECT id FROM notes_fts WHERE notes_fts MATCH ?)`, not as
  FTS5 `NOT`.
- Filter keys are case-insensitive (`TAG:`, `Before:`). Only a leading,
  unquoted `key:` creates a filter. An unknown `foo:bar` stays free text, and
  quoted text such as `"tag:alpha"` is a phrase, not a filter.
- A whitespace-only query returns `{"results": [], "fuzzy": false}`.

Ordering and snippets:

- With positive free text or a phrase, rows come from FTS5 ordered by
  `bm25(notes_fts, 4.0, 1.0)` then `mtime_ms` descending, and the snippet is
  `snippet(notes_fts, 2, '⟪', '⟫', '…', 14)`.
- A filter-only query (no positive free text) uses `notes.snippet` and orders
  by pinned first, then `mtime_ms` descending, then id.

The fuzzy fallback runs only for **plain** queries: at least one positive free
word, with no filter, no negation, and no quoted phrase. Those queries use the
unchanged exact-prefix path; if fewer than `min(limit, 5)` hits are found,
close vocabulary terms are appended and the response sets `"fuzzy": true`
(and marks each appended result with `"fuzzy": true`). Any structured or
negated query never runs the fallback and never sets `"fuzzy": true`.

Trashed notes are always excluded.

#### `searches list|add|remove`

Saved searches live in `state.json` beside pins. Every form returns the full
saved-search list, newest entries last:

```json
{
  "searches": [
    {"query": "tag:project after:2026-10-01 quill", "label": "Recent project notes"}
  ]
}
```

- `searches list` is read-only.
- `searches add <query> [--label LABEL]` strips the query; an empty query fails
  with `{"error": "saved search cannot be empty"}`. The default label is the
  stripped query. Adding an existing query updates its label in place instead
  of duplicating it; new entries append. At most 50 entries are kept; adding a
  new query when full fails with
  `{"error": "too many saved searches (max 50)"}` (updating an existing query
  still works).
- `searches remove <query>` removes an exact match on the stored query string.
  It is idempotent: an unknown query returns the unchanged list without error.
- `add` and `remove` take the exclusive lock; `list` does not.

#### `settings get`, `settings set (--json JSON | --stdin)`

UI settings are an opaque JSON object stored as `state.json` key `ui`. The
store never validates or interprets the keys and values inside it; the front
end owns the schema and may change it without a store migration.

Both forms return the stored object:

```json
{"ui": {"mode": "split", "printCopies": 2}}
```

- `settings get` is read-only. It returns `{"ui": {}}` when `state.json` is
  missing, when `ui` is absent, or when `ui` is not a JSON object. It does
  **not** call `ensure_store()`, so it never creates the data root,
  `state.json`, templates, or the lock file.
- `settings set` requires exactly one of `--json JSON` or `--stdin`. Giving
  both or neither fails with
  `{"error": "choose exactly one of --json and --stdin"}`.
- The payload must be a JSON **object**. `null`, arrays, strings, numbers, and
  malformed JSON fail with an error beginning `Settings must be a JSON object`.
  `{}` is valid and clears the settings.
- Every top-level key must be a non-empty string without NUL and at most 64
  characters. Values may be any JSON.
- The serialized payload is capped at 64 KiB (`MAX_UI_SETTINGS_BYTES`); larger
  input fails with `{"error": "Settings are too large"}`.
- `set` **replaces the whole `ui` object** rather than merging per key. It
  takes the exclusive lock and preserves every other `state.json` key
  (`version`, `pinned`, `searches`, and any unknowns).

#### `tags`

```json
{"tags": [{"tag": "alpha", "count": 2}]}
```

Counts live notes only, grouped by the normalised tag key, ordered by count
descending then tag case-insensitively.

#### `backlinks <id>`

```json
{"backlinks": [{"id": "source.md", "title": "Source", "snippet": "…"}]}
```

Only live notes that link to the target are returned, excluding the note
itself. `[[Title]]`, `[[Title|alias]]`, and `[[Title#section]]` links resolve
by note title and by filename stem. Comparison is case-insensitive and uses
Unicode NFC normalisation.

#### `unresolved [--id ID] [--limit N]`

Lists wiki links that resolve to no live note. `source` is the linking note's
id, `sourceTitle` its title, and `target` the link text as written (without an
alias or `#heading`). Duplicate targets within one source note are grouped.
Links inside inline code and fenced code blocks are never indexed, so they
never appear. Source notes in the trash and ids beginning `.quill-` are
excluded. `--id` restricts the report to one source note (an unknown id yields
an empty list). `limit` defaults to 500 and is clamped to at least 1; it caps
the number of grouped rows returned. Rows are ordered by source id then target,
both case-insensitively.

```json
{
  "unresolved": [
    {"source": "source.md", "sourceTitle": "Source", "target": "Missing", "count": 2}
  ],
  "total": 2,
  "sources": 1
}
```

`total` is the sum of `count` over the returned rows and `sources` is the
number of distinct source notes in the returned rows.

#### `preview <id> [--trashed]`, `preview --content-file PATH`, `preview --stdin`

Renders Markdown for the preview pane. Exactly one source must be supplied: a
note id, `--content-file PATH`, or `--stdin`. Supplying none or more than one
is an error. `--trashed` applies only to the note-id form; combining it with a
buffer source is an error. Buffer input is capped at 1 MiB
(`MAX_NOTE_BYTES`) and decoded as UTF-8 with replacement.

Wiki links are rewritten to `[label](quill://note/<url-encoded id>)` when they
resolve, or `[label](quill://missing/<url-encoded target>)` when they do not.
Inline tags become `[#tag](quill://tag/<url-encoded tag>)` outside code spans.
Inline code and fenced code are passed through verbatim.

The note-id form ensures the store exists and runs `sync_index()` under the
write lock, so a just-written note's links resolve immediately. The
`--content-file` and `--stdin` forms are sync-free: they never create or
migrate the index, take the write lock, stat or read a note file, or call
`resolve_links()`. When an index already exists they open it read-only
(`file:<abs path>?mode=ro`) to look up link titles; if it is missing,
unreadable, or from an older schema, links degrade to `quill://missing`.

```json
{"markdown": "# Title\n\nSee [Target](quill://note/target.md)\n", "tooLarge": false, "lineOffset": 0}
```

Over the size cap, both forms return the same shape with empty Markdown:

```json
{"markdown": "", "tooLarge": true, "lineOffset": 0}
```

`lineOffset` is the number of file lines occupied by stripped frontmatter, so
image line numbers in the preview can be mapped back to the note. It is `0`
when the input is oversized.

#### `versions <id>`

Read-only; deliberately does not create the store or the index.

```json
{
  "id": "note.md",
  "versions": [
    {
      "path": "/abs/root/backups/versions/note-md-0123456789abcdef/20260101T000000Z-0123456789abcdef.md",
      "name": "20260101T000000Z-0123456789abcdef.md",
      "mtime": 1767225600000,
      "size": 1234,
      "sha256": "64-hex-characters"
    }
  ],
  "retention": 50
}
```

Newest first. Each file is the **old bytes** of the note at snapshot time, named
`<UTC YYYYMMDDTHHMMSSZ>-<sha256 first 16>[-counter].md`.

#### `attachment list`

```json
{
  "attachments": [
    {"path": "/abs/root/attachments/<sha256>.png", "size": 1234, "mtime": 1767225600000, "referenced": true}
  ]
}
```

Only regular files directly in `<root>/attachments` are listed; hidden files
and symlinks are ignored. `referenced` is true when any note, including a
trashed note, mentions the file name.

#### `templates list`, `templates show <id>`

Read-only views of the file-backed note templates. Both call `ensure_store()`
first, so the first use on a fresh data root seeds the four built-ins (see
[Note templates](#note-templates)). `id` is the file stem, lowercased by
`save`. `modified` is the file's mtime in integer milliseconds. `content` is
the template **body** (frontmatter excluded).

`list` is sorted by `name` case-insensitively, then `id`:

```json
{
  "templates": [
    {"id": "daily", "name": "Daily log", "description": "Focus, log and tomorrow", "icon": "☀", "modified": 1767225600000}
  ]
}
```

`show` returns one template or fails with `template not found: <id>`:

```json
{
  "id": "meeting",
  "name": "Meeting notes",
  "description": "Attendees, agenda and action items",
  "icon": "◷",
  "content": "# Meeting notes — {{date}}\n\n...",
  "modified": 1767225600000
}
```

#### `stats`

```json
{
  "notes": 10,
  "trashed": 0,
  "folders": 2,
  "tags": 4,
  "bytes": 12345,
  "dataRoot": "/abs/root",
  "attachments": 1,
  "indexBytes": 40960
}
```

`bytes` is the sum of indexed note sizes, including trashed notes.

### Mutating commands

#### `create [--folder FOLDER] [--title TITLE] [--content-stdin] [--template ID]`

Creates a new note with a generated id `<epoch-ms>-<uuid8>.md` under the
cleaned folder (folders are created recursively). With `--content-stdin` the
stdin payload is used verbatim after newline normalisation to LF; otherwise the
body is `# <title>\n\n`, with `Untitled` as the default title.

`--template` accepts any installed template id (see
[Note templates](#note-templates)). The template body is read from disk,
`{{date}}`, `{{time}}`, and `{{datetime}}` are substituted from local time, and
unknown `{{...}}` placeholders are left literal. A template owns its own H1, so
`--title` is ignored. `--template` cannot be combined with `--content-stdin`.
An unknown id fails with an error naming the id and listing the available ids:

```json
{"error": "template not found: weekly (available: daily, meeting, project, tasks)"}
```

```json
{"id": "Work/1767225600000-deadbeef.md", "modified": 1767225600000}
```

#### `templates save <id> [--name N] [--description D] [--icon I] [--content-file FILE | --stdin]`

Upserts the template file `<root>/templates/<id>.md` and returns the same shape
as `templates show`. Only the owned frontmatter keys `name`, `description`, and
`icon` are edited; every other frontmatter key is preserved verbatim and is
written after those three in its original order. The body is replaced from
`--content-file` or `--stdin` when given, otherwise the existing body is kept.

An omitted `name` keeps the current name, or defaults to the id with hyphens
replaced by spaces and the first letter capitalised (`weekly-review` →
`Weekly review`). `--content-file -` is an ordinary file name, not stdin; use
`--stdin` for stdin. A body over `MAX_NOTE_BYTES` (1 MiB) is rejected. `save`
serialises under the store lock.

```json
{
  "id": "weekly-review",
  "name": "Weekly review",
  "description": "Plan: the week",
  "icon": "★",
  "content": "# Weekly review — {{date}}\n\n...",
  "modified": 1767225600000
}
```

#### `templates delete <id>`

Deletes one template file. An unknown id fails with
`template not found: <id>`.

```json
{"deleted": true, "id": "weekly-review"}
```

#### `write <id> [--stdin] [--content-file FILE] [--create]`

Replaces the note body. With `--content-file` the body comes from that file and
stdin is not read. Without it the body comes from stdin. `--create` allows an
explicit id that does not yet exist (parent folders are created); without it a
missing note is an error.

If the note exists, the incoming text is normalised to the note's existing
dominant newline (`\r\n` if CRLF is more common than LF, otherwise `\n`), so a
CRLF note stays CRLF. New notes start from LF. The previous bytes are
snapshotted before an actual change. If the adjacent draft normalises to the
new content, the draft is deleted.

`--content-file` paths whose basename starts with `.quill-save-` are deleted
after the command, on success and failure alike. Other supplied files are
never deleted.

```json
{"id": "note.md", "modified": 1767225600000, "size": 1234, "draftDeleted": false}
```

#### `draft discard <id>`

Deletes the adjacent `<note>.md.draft` file if present. Does not require the
note itself to exist and does not touch the note.

```json
{"id": "note.md", "discarded": true}
```

#### `duplicate <id>`

Copies a live note in the same folder with a new id. The title is rewritten to
the next unused `<title> copy` / `<title> copy N`. Trashed notes must be
restored first.

```json
{"id": "Work/1767225600000-feedface.md", "modified": 1767225600000}
```

#### `rename <id> --title TITLE [--links update|skip] [--dry-run]`

Rewrites the note title. If frontmatter has a `title:` key, that value is
updated; otherwise the first ATX heading is replaced; otherwise a new
`# Title` is prepended. The body is otherwise preserved, including CRLF.

With `--links update` (the default) the rename also rewrites inbound wiki
links in live notes. Before mutating, the command collects every distinct
normalised link target that currently resolves to the renamed note (including
links written by the note itself). A link is rewritten only when its target
matches one of those keys, so renaming `Alpha` never touches `[[Alpha Two]]`;
matching is case-insensitive, so `[[alpha]]` is rewritten. `[[Old]]`,
`[[Old|alias]]`, and `[[Old#heading]]` become `[[New]]`, `[[New|alias]]`, and
`[[New#heading]]`, preserving the alias text and heading text exactly as
written (including an empty alias). Link-injected titles replace `|` and `#`
with `-`, and `[`/`]` with `(`/`)`.

Rewriting skips fenced code blocks, fence delimiter lines, inline code spans,
and all trashed notes. Live notes whose bytes actually change are snapshotted
under the `link-rename` reason before being written; a note larger than 1 MiB
is skipped. `--links skip` leaves every linking note untouched, although the
index still re-resolves the renamed note so stale resolutions become
`unresolved`.

`--dry-run` scans and reports exactly what would change without writing notes
or snapshots and without changing any note mtime. `title` is reported after
the same normalisation the real rename applies (trimmed, newlines collapsed,
capped at 120 characters, defaulting to `Untitled`).

```json
{
  "id": "note.md",
  "modified": 1767225600000,
  "title": "New Title",
  "linksUpdated": 2,
  "notesUpdated": 1,
  "sources": [
    {"id": "source.md", "title": "Source", "count": 2}
  ]
}
```

`linksUpdated` counts rewritten occurrences, including self-links in the
renamed note. `notesUpdated` and `sources` cover other notes only; `sources`
is empty when nothing else changed, when there are no inbound links, or when
`--links skip` is used. A dry run uses the same shape plus `"dryRun": true`
and omits `modified`.

```json
{
  "id": "note.md",
  "title": "New Title",
  "dryRun": true,
  "linksUpdated": 2,
  "notesUpdated": 1,
  "sources": [
    {"id": "source.md", "title": "Source", "count": 2}
  ]
}
```

#### `move <id> [--id ID ...] [--folder FOLDER]`

Moves live notes to another folder (default: notes root), creating it if needed
and pruning empty source folders. The positional `id` is the primary note;
repeat `--id` to move more notes to the same folder in one all-or-nothing call.
A name collision becomes `<stem>-moved<N><ext>`. Pins follow each note. Drafts
move with their notes. The index is refreshed once after the batch.

```json
{"id": "Archive/2026/a.md", "ids": ["Archive/2026/a.md", "Archive/2026/b.md"], "count": 2}
```

#### `trash <id> [--id ID ...]`

Moves live notes into the trash, preserving each folder path. The positional
`id` is the primary note; repeat `--id` for a bulk all-or-nothing call. A name
collision becomes `<stem>-trashed-<N><ext>`. The notes are unpinned. Returns
trash-relative ids in order.

```json
{"id": "Work/a.md", "ids": ["Work/a.md", "Work/b.md"], "count": 2}
```

#### `restore <id> [--id ID ...]`

Moves notes out of the trash back to the same relative folders. The positional
`id` is the primary note; repeat `--id` for a bulk call. A name collision
becomes `<stem>-restored-<N><ext>`. Returns live ids in order.

```json
{"id": "Work/a.md", "ids": ["Work/a.md", "Work/b.md"], "count": 2}
```

#### `delete <id> [--id ID ...]`

Permanently deletes notes **from the trash**. Live notes must be trashed first.
The positional `id` is the primary trash-relative id; repeat `--id` for a bulk
call. The bytes of every note are snapshotted before deletion.

```json
{"deleted": true, "id": "Work/a.md", "ids": ["Work/a.md", "Work/b.md"], "count": 2}
```

#### `empty-trash`

Snapshots every Markdown note in the trash, then deletes every file under the
trash (non-Markdown files are deleted without a snapshot) and removes empty
trash directories. `deleted` counts all files removed.

```json
{"deleted": 3}
```

#### `pin <id> [--id ID ...] [--state on|off|toggle]`

Changes the pinned state of live notes in `<root>/state.json`. The positional
`id` is the primary note; repeat `--id` to update a batch. `--state on` and
`--state off` force that state idempotently: notes already in the requested
state are untouched and are not counted in `updated`. The default `toggle`
flips each note individually. Pinning is a snapshotting mutation only for the
notes whose state actually changes; `pinned` reports the primary note's state
after the call.

```json
{"id": "a.md", "ids": ["a.md", "b.md"], "pinned": true, "updated": 2}
```

```json
{"id": "a.md", "ids": ["a.md", "b.md"], "pinned": false, "updated": 0}
```

#### `restore-version <id> <snapshot>`

`snapshot` is a basename inside that note's version directory or an absolute
path inside it. `..`, symlinks, and files outside the directory are refused.
The current bytes are snapshotted first if they differ from the snapshot, then
the snapshot bytes are written exactly as stored.

```json
{"id": "note.md", "size": 1234, "modified": 1767225600000, "snapshot": "20260101T000000Z-0123456789abcdef.md"}
```

#### `folder create <path>`

Creates a folder recursively. An existing folder is an error.

```json
{"folder": "Work/Projects"}
```

#### `folder rename <path> <new>`

Renames/moves a folder tree. Pinned ids under it are rewritten. Existing
targets are an error.

```json
{"folder": "Archive", "from": "Work"}
```

#### `folder delete <path> [--force]`

Deletes a folder. Without `--force`, a folder containing any file is an error.
With `--force`, Markdown notes are snapshotted and moved to the notes root
(name collisions get `-moved<N>`), non-Markdown files are discarded, and the
folder is removed. `moved` counts Markdown notes moved.

```json
{"deleted": true, "folder": "Archive", "moved": 2}
```

#### `tag-add <id> [--id ID ...] <tags...>`

Appends inline `#tag` entries that are not already present. The positional `id`
is the primary note and `--id` adds more notes to the batch. At most 20 missing
tags are added per note per call. If a note has an unclosed fenced code block,
adding missing tags to that note is refused before any note in the batch is
written (a request whose tags are already present is a no-op success).

`id`, `tags`, `content`, `modified`, and `draftDeleted` describe the **primary**
note. `ids` lists every id passed, and `updated` counts notes whose bytes
changed; notes already carrying every requested tag are untouched and not
counted.

```json
{
  "id": "note.md",
  "tags": ["alpha", "beta"],
  "content": "# Title\n\nbody\n\n#beta\n",
  "modified": 1767225600000,
  "draftDeleted": false,
  "ids": ["note.md", "other.md"],
  "updated": 2
}
```

#### `tag-remove <id> [--id ID ...] <tags...>`

Removes tags from the primary note and every `--id` note. Requested tags are
normalised the same way as storage (accents folded, case-insensitive), and only
exact normalised matches are removed.

- **Frontmatter inline lists** (`tags: [alpha, beta]`) lose only matching items;
  leftover separators are collapsed and an exhausted list becomes `tags: []`.
- **Frontmatter block lists** (`tags:` followed by `  - alpha` lines) lose only
  the matching item lines. Other keys, order, and formatting are untouched.
  A matching scalar `tags: alpha` line is removed entirely.
- **Inline text** loses `#tag` occurrences outside inline code, fenced code
  blocks, URLs, and Markdown link destinations. One adjacent whitespace run is
  collapsed, so `hello #tag world` becomes `hello world` and `hello #tag`
  becomes `hello`.
- A tag that appears only inside code or a URL is left untouched. Removing an
  absent tag is a byte-for-byte no-op (`updated` is not incremented).
- An unclosed fenced code block never blocks removal: anything inside a fence
  is protected and skipped.

The result has the same shape as `tag-add`: the primary note's fields plus
`ids` and `updated`.

```json
{
  "id": "note.md",
  "tags": ["gamma"],
  "content": "# Title\n\ngamma\n",
  "modified": 1767225600000,
  "draftDeleted": false,
  "ids": ["note.md", "other.md"],
  "updated": 2
}
```

#### `tag-rename <old> <new>`

Rewrites a tag in frontmatter tag lists and in inline tags across all live
notes, skipping code fences and inline code. Tags that normalise to an empty
key are refused. Returns the count of notes changed.

A rename onto a tag that already exists acts as a **merge**. After rewriting,
duplicate entries are removed:

- in the frontmatter `tags` key, both the flow form (`tags: [a, b, a]`) and
  the block form (`- a` lines): the first occurrence wins, survivors keep their
  order and existing formatting;
- within each inline line, a repeated `#tag` is dropped (first occurrence
  wins), without touching inline code, fenced code, URLs, or Markdown link
  destinations.

`merged` is `true` when `<new>` already existed anywhere before the rename
(any live note carried it), and `false` otherwise. Snapshot reason is
`tag-rename` and snapshots are destructive (they ignore throttling). `ids`
lists every changed note id so a client can refresh an open buffer without
waiting for the file watcher.

```json
{"tag": "delta", "from": "alpha", "updated": 2, "merged": true,
 "ids": ["Inbox/a.md", "Notes/b.md"]}
```

#### `tag-delete <tag>`

Removes one tag from **every live note** using the same rules as `tag-remove`:
frontmatter inline lists and block lists lose matching entries, and inline
`#tag` tokens are removed outside inline code, fenced code, URLs, and Markdown
link destinations. `tag` in the result is the normalised display form of the
requested tag. Only notes whose bytes changed are counted in `updated`.

Each changed note is snapshotted with reason `tag-delete` (destructive), then
written atomically. The index is refreshed with one full `sync_index`, and
version retention is pruned. A tag that no note carries is **not** an error:
`updated` is `0`. A tag with no comparable characters (it normalises to an
empty key) is refused, because such keys would match every uncomparable tag.

```json
{"tag": "alpha", "updated": 3, "ids": ["Inbox/a.md", "Notes/b.md", "Notes/c.md"]}
```

```json
{"tag": "missing", "updated": 0, "ids": []}
```

#### `index [--rebuild]`

Without `--rebuild`, synchronises the SQLite index incrementally (a note is
reindexed when its size or millisecond mtime changed, or when it appeared or
disappeared). `--rebuild` deletes `index.db` and its `-wal`/`-shm` sidecars,
then rebuilds from scratch. Repeating either form is idempotent in content.

```json
{"notes": 10, "trashed": 1, "links": 4, "rebuilt": true}
```

#### `import-omanano`

Copies Markdown notes from `$OMANANO_DATA_DIR/notes` (default
`~/.local/share/omanano/notes`) into the Quill notes root, preserving relative
paths. Existing targets are skipped. Pins from the source `state.json` are
imported for notes that now exist.

```json
{"imported": 2, "skipped": 1, "ids": ["a.md", "Work/b.md"]}
```

#### `attachment save (--file FILE | --stdin) [--name NAME]`

Reads the payload from the given file or stdin (20 MiB cap), sniffs image
formats from magic bytes (PNG, JPEG, GIF, WebP, BMP), and stores it
content-addressed as `<root>/attachments/<sha256>.<ext>`. Saving identical
bytes is deduplicated (`deduped: true`). `--name` becomes the Markdown alt
text; images get `![alt](path)`, other files get `[alt](path)`. Parents and
whitespace in the stored path are wrapped in angle brackets.

```json
{
  "id": "64-hex-characters",
  "path": "/abs/root/attachments/<sha256>.png",
  "markdown": "![Picture](/abs/root/attachments/<sha256>.png)",
  "kind": "image",
  "name": "<sha256>.png",
  "size": 1234,
  "mime": "image/png",
  "deduped": false
}
```

`kind` is `image` for sniffed images and `file` otherwise.

#### `attachment gc [--dry-run]`

Removes attachments not mentioned by any note, including trashed notes.
`--dry-run` reports what would happen without unlinking. `freed` is bytes
removed (or that would be removed).

```json
{"removed": 1, "freed": 1234, "kept": 2, "dryRun": true}
```

## Note templates

Templates are plain files under `<root>/templates/`, one per id:

```text
<root>/templates/
  meeting.md
  daily.md
  project.md
  tasks.md
```

Each file is YAML frontmatter followed by the Markdown body:

```text
---
name: Meeting notes
description: Attendees, agenda and action items
icon: ◷
---
# Meeting notes — {{date}}

...
```

`name`, `description`, and `icon` are optional single-line strings; the parser
accepts quoted or bare values and strips surrounding quotes. A value that needs
quoting (for example a `description` containing `:` or starting with `-`) is
written double-quoted. Unknown frontmatter keys, comments, and their order are
preserved verbatim by `templates save`. Nested/block values for the three owned
keys are not interpreted (only the single-line form is part of the contract).

### Seeding

`ensure_store()` creates `<root>/templates/` and writes the four built-ins
**only when the directory did not exist yet**:

| id | name | description | icon |
| --- | --- | --- | --- |
| `meeting` | Meeting notes | Attendees, agenda and action items | `◷` |
| `daily` | Daily log | Focus, log and tomorrow | `☀` |
| `project` | Project spec | Goal, scope and milestones | `◆` |
| `tasks` | Task list | A quick checklist | `☑` |

The files are the source of truth afterwards. If the user deletes every file,
the directory still exists and the store does **not** re-seed. Deleting the
directory itself is the only way to request seeding again.

### Template ids

`save` normalises ids to slugs: lowercased, spaces and underscores become `-`,
only `[a-z0-9-]` survives, repeated hyphens collapse, leading/trailing hyphens
are stripped, the result is capped at 64 characters, and it must be non-empty.
Ids containing `/`, `\`, or `..`, or starting with `.`, are rejected outright
rather than cleaned. Lookup (`show`, `save`, `delete`, `create --template`) is
case-insensitive; an existing file wins over a new spelling, so saving
`Weekly` when `weekly.md` exists updates `weekly.md` and reports id `weekly`.
The file stem is the canonical id.

### `create --template`

`create --template <id>` reads the stored body and substitutes `{{date}}`,
`{{time}}`, and `{{datetime}}` from local time. Any other `{{...}}` placeholder
is left literal. The template supplies the body (including its H1), so
`--title` is ignored. Unknown ids fail with an error that names the id and
lists the installed ids.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `QUILL_DATA_DIR` | Data root. Default `~/.local/share/quill`. Resolved to an absolute path. |
| `QUILL_SOCKET` | Overrides the daemon socket path. Default `$XDG_RUNTIME_DIR/quill-<hash>.sock` (hash of the data root and the store file stamp), else `/tmp/quill-<hash>.sock`. |
| `XDG_RUNTIME_DIR` | Preferred parent for the default daemon socket. Unset falls back to `/tmp`. |
| `QUILL_E2E` | Set to `1` to enable the live-root mutation guard. Any other value (or unset) disables the guard. |
| `QUILL_E2E_ALLOW_REAL` | Break-glass override: exactly `1` disables the E2E guard. Quill's own tooling must **never** set this. |
| `QUILL_VERSION_RETENTION` | Number of version snapshots kept per note. Default 50; clamped to 1..1000. Invalid values fall back to the default. |
| `QUILL_VERSION_THROTTLE` | Seconds between ordinary autosave snapshots. Default 60; negative values clamp to 0. Destructive operations and restores ignore the throttle. |
| `OMANANO_DATA_DIR` | Source root for `import-omanano`. Default `~/.local/share/omanano`. |
| `HOME` | Used by `~` expansion and by the live-root guard. |

### E2E live-root guard

With `QUILL_E2E=1`, a **mutating** command is refused when the resolved data
root equals the resolved live root `~/.local/share/quill` (unless
`QUILL_E2E_ALLOW_REAL=1`). Refusal is a normal JSON error with exit 1:

```json
{"error": "QUILL_E2E=1 refuses to modify the real Quill data root; point QUILL_DATA_DIR at a clone or set QUILL_E2E_ALLOW_REAL=1 deliberately"}
```

Read-only commands remain allowed. Mutating commands are:

```text
write create duplicate rename move trash restore delete empty-trash pin
tag-add tag-remove tag-rename tag-delete import-omanano index restore-version
folder (all actions)
draft discard
attachment save
attachment gc
searches add
searches remove
settings set
templates save
templates delete
```

`draft discard` is mutating; other draft actions (none currently) would not be.
`attachment list`, `versions`, `unresolved`, `titles`, `searches list`,
`settings get`, `templates list`, `templates show`, and all read-only commands
are not mutating.

## Storage layout and guarantees

```text
<root>/
  notes/                  Markdown files; the source of truth
  trash/                  same relative layout, trashed notes
  templates/              one <id>.md template per note template
  attachments/            content-addressed blobs
  backups/versions/       per-note snapshot directories
  state.json              {"version": 1, "pinned": [...], "searches": [...], "ui": {}}
  index.db                derived SQLite cache (FTS5), safe to delete
  index.db-wal, -shm      SQLite WAL sidecars
  .lock                   flock file
```

### Markdown is authoritative

`notes/` and `trash/` are the source of truth. `index.db` is a cache and may
be deleted at any time; `index --rebuild` recreates it. `state.json` holds pins,
saved searches, and the opaque UI settings; saving one never drops the others
or any unknown keys.
`templates/` is the source of truth for note templates; it is seeded once and
never re-seeded while the directory exists. Drafts live beside their note as
`<note>.md.draft` and are deliberately outside `*.md` scans.

### Serialisation and atomic writes

Every command that mutates notes, state, or the index takes an exclusive
`fcntl.flock` on `<root>/.lock` (mode 0600) for the duration. This serialises
concurrent CLI callers. Atomic renames protect readers, but the index and
`state.json` are read-modify-write, so the lock removes that race.

File writes (notes, `state.json`, version snapshots, attachments) use the same
atomic-write primitive: create a temporary `.quill-tmp-*` file in the target
directory, write, `flush`, `fsync`, then `os.replace()` over the target.
Readers therefore see either the old bytes or the complete new bytes, never a
partial file.

The index uses SQLite in WAL mode with `synchronous=NORMAL` and a 15-second
busy timeout. The current schema is **version 3**: it dropped the duplicated
`notes.body` column (the FTS table keeps its own body copy for search), so
`notes.body` is neither selected nor written. `create_schema` stamps
`PRAGMA user_version` from the `SCHEMA_VERSION` constant in both places. A
schema-version mismatch deletes and recreates `index.db`.
`index --rebuild` also deletes the WAL and SHM sidecars before rebuilding.

### Path safety

Note ids and folder names are validated before use: ids must be relative,
non-empty, contain no NUL, and contain no `..`, `.` or empty path components;
the resolved path must stay under the relevant root. Folder components are
sanitised (control characters and `/:` become `-`; components are capped at
120 characters). Version directories use a hash suffix so folder ids stay
distinct and cannot escape the root; symlinked version directories are
refused.

### Wiki-link resolution

A wiki link resolves in this order: exact title, then filename stem. Both are
compared with `link_key`, which casefolds the value and normalises the result to
Unicode NFC; the index, `backlinks`, `unresolved`, and the preview renderer all
use the same key. When several live notes share a title or stem, the first
in `pinned DESC, mtime_ms DESC, id` order wins. A link is `unresolved` exactly
when that lookup finds no live note; targets in the trash never resolve.

The index resolves links only for what changed. Indexing a single note (create,
write, duplicate, rename, tag-add, tag-remove, restore-version) recomputes rows
whose source is that note and rows whose target matches the note's old or new
title/stem.
`sync_index` does the same for every file it indexes and also collects the
targets that resolved to each note it removes (trash, delete, move), so those
links become unresolved and can resolve again after a restore. It resolves
globally only for a full rebuild or when pin state changed, because pinning can
change which duplicate title wins.

### Snapshots and retention

Every snapshot contains the **old** bytes being replaced, stored under
`backups/versions/<slug>-<sha256-of-id first 16>/`. Snapshot failures abort the
mutation before the note is touched. Ordinary autosave snapshots (`write`,
`tag-add`, `tag-remove`) are:

- deduplicated by SHA-256 against existing snapshots, and
- throttled: if a snapshot already exists and the newest is younger than
  `QUILL_VERSION_THROTTLE` seconds, the snapshot is skipped.

Destructive operations always snapshot regardless of the throttle or duplicate
state: `rename`, `move`, `trash`, `delete`, `empty-trash`, `pin`,
`folder delete`, `tag-rename`, `tag-delete`, `restore-version` (which also
snapshots the current bytes before restoring), and inbound-link rewrites
performed by `rename --links update` (reason `link-rename`). Retention pruning
keeps the newest `QUILL_VERSION_RETENTION` snapshots and never fails a save.

### Limits

| Limit | Value |
| --- | --- |
| Note body / `preview` input (`MAX_NOTE_BYTES`) | 1 MiB (`1048576` bytes) |
| Template body (`templates save`) | 1 MiB (`MAX_NOTE_BYTES`) |
| Attachment | 20 MiB |
| Attachment reference scan | 8 MiB per note |
| Indexed note body | 512 KiB |
| `state.json` | 1 MiB |
| `settings set` payload (`MAX_UI_SETTINGS_BYTES`) | 64 KiB (`65536` bytes) |
| `settings` top-level key | 64 characters |
| `list` notes | 2000 |
| `list` folders | 2000 |
| `search --limit` | clamped 1..500; default 50 |
| `titles --limit` | clamped 1..20000; default 5000 |
| Saved searches | 50 entries |
| `unresolved --limit` | default 500; clamped to at least 1 |
| `tag-add` missing tags | 20 per note per call |
| `tag-add` / tag normalisation | 40 characters |
| `rename` inbound-link sweep | notes over 1 MiB are skipped, as are trashed notes |

Oversized notes are not corrupted: `read` reports `tooLarge` and empty content;
writes over the limit fail with an error.

## Compatibility notes for a rewrite

A daemon or Rust implementation must preserve at minimum:

1. The one-JSON-object rule, including the stderr error shape and exit codes.
2. Relative note ids and the trash/folder mirroring rules.
3. Newline preservation on writes (the existing note's dominant newline).
4. Atomic replace and the single exclusive lock around read-modify-write
   operations.
5. Snapshot-before-mutation semantics and exact snapshot bytes.
6. The E2E live-root guard and its environment variables.
7. SQLite index as a disposable cache, never as the source of truth.
8. Content-addressed attachment names and reference-based GC.
9. The exact JSON field names and types documented above.
10. `link_key` (NFC + casefold) link resolution, the `link-rename` snapshot
    reason, and the rule that code spans/fences are never link-rewritten.
11. `__serve`: the line-framed request/response/event shapes, `stdin`
    indirection, `ping`/`shutdown`, the socket path rule, and the watcher's
    `INDEX_TRUSTED` shortcut (a rewrite may keep syncing eagerly instead, at a
    performance cost, but must never serve stale data as trusted).
