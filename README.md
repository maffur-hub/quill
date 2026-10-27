# Quill

A local-first Markdown notes library for Omarchy, built as a `bar-widget`
shell plugin. Click the feather in the bar (or run `omarchy-shell quill open`)
for the three-pane library: saved views and folders on the left, notes in the
middle, and a split Markdown editor/preview on the right.

Plain Markdown files are the source of truth. Quill keeps a disposable SQLite
FTS5 index next to them for instant search, tags, wiki-link resolution and
backlinks. Deleting `index.db` is safe; it is rebuilt automatically.

## Layout

```
~/.config/omarchy/plugins/matt.quill/
  manifest.json
  BarWidget.qml        bar button, capture click, IPC target "quill"
  Panel.qml            popup + desktop-window host, injects shell/bar/host
  Library.qml          state, backend queue, shortcuts, pane layout
  AgentService.qml     JSONL bridge client + chat transcript model
  ChatDock.qml         right-hand chat dock (sessions, tools, composer)
  ChatMessage.qml      one chat row: Markdown, maths, tool output
  FormatBar.qml        editor formatting toolbar + colour/link/table popovers
  MarkdownFormat.js    pure formatting edit planner (shared, node-testable)
  Detached.qml         one note in its own Quickshell window (Ctrl+Return)
  Sidebar.qml          saved views, tag counts, folder tree
  PaneRail.qml         slim expand rail for a collapsed left pane
  NoteList.qml         debounced backend search + note rows
  MarkdownEditor.qml   live syntax highlighting, tab/bold/italic helpers
  PreviewPane.qml      Qt GitHub-dialect Markdown renderer + quill:// links
  TableGrid.qml        spreadsheet panel for one GFM table
  MathService.qml      batches TeX to scripts/quill-math, caches SVG results
  ImageSizing.js       pure image-size parsing/rewriting (shared, node-testable)
  TableEngine.js       pure table parsing, formulas and row/column edits
  MathSyntax.js        pure maths delimiter detection (shared, node-testable)
  MathText.js          Markdown → RichText HTML for blocks containing maths
  WritableGuard.js     pure live-root write guard (shared with tests)
  scripts/quill-store  Python 3 stdlib backend (JSON in / JSON out)
  scripts/quill-agent  Node JSONL bridge to the OpenCode service (chat)
  scripts/quill-paste-image  clipboard image → attachment store helper
  scripts/quill-math   offline TeX → themed SVG renderer (JSON in / JSON out)
  scripts/quill-window launcher for Detached.qml (stages it for `qs -p`)
  vendor/              vendored MathJax 3.2.2 (Apache-2.0), see vendor/README.md
  tools/               Joplin mirror scripts + systemd units (reference copies)
  README.md
```

The Joplin mirror scripts (`omanano-joplin-sync`, `quill-joplin-sync`,
`quill-joplin-restore`, `quill-joplin-tags`) and their systemd units are tracked
under `tools/`. These are reference copies of the files installed to
`~/.local/bin` and `~/.config/systemd/user`; the installed copies are what runs.
See `tools/README.md` for install steps.

## Data

`QUILL_DATA_DIR` defaults to `~/.local/share/quill`:

```
notes/       Markdown files; subfolders are folders
trash/       same layout, for trashed notes
attachments/ pasted images, content-addressed (created on first paste)
backups/versions/  local note snapshots (newest 50 per note)
backups/joplin/    remote Joplin bodies saved before replacement/trash
                   (newest 50 per Joplin note; see Joplin sync)
state.json   pinned note ids
index.db     derived SQLite index (WAL, FTS5)
.quill-context.json  note the chat currently sees (id, title, path, selection)
AGENTS.md    instructions for the chat agent (it is embedded in Quill)
```

New files are `<epoch_ms>-<8 hex>.md`. Bodies are UTF-8 Markdown, written with
an atomic temp-file + rename. The original newline style (LF or CRLF) is kept
on every save. Notes over 1 MiB are shown read-only ("too large") rather than
risking a partial write.

Titles come from frontmatter `title:`, otherwise the first non-empty line with
heading/list markers and `` ` `` `*` `_` `~` stripped, capped at 120 chars.
Tags come from frontmatter `tags:` and inline `#tag` outside code fences and
inline code. `[[Target]]`, `[[Target|Alias]]` and `[[Target#Heading]]` resolve
case-insensitively by title, then filename stem.

## Shortcuts

| Key | Action |
| --- | --- |
| `Ctrl+N` | New note |
| `Ctrl+Shift+N` | New note in the current folder |
| `Ctrl+F`, `/` | Focus search |
| `Ctrl+P` | Pin / unpin |
| `Ctrl+E` | Cycle Edit → Split → Preview |
| `Ctrl+T` | Insert a 3×3 table at the caret and open the grid |
| `Ctrl+S` | Flush the 600 ms autosave now |
| `Ctrl+B` / `Ctrl+I` | Bold / italic |
| `Ctrl+U` / `Ctrl+Shift+X` | Underline / strikethrough |
| `Ctrl+Shift+H` | Highlight (==text==) |
| `Ctrl+K` | Link popover |
| `Ctrl+Shift+K` | Note-link popover |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| `Ctrl+Shift+Enter` | Open the library in its own window |
| `Ctrl+Return` | Open the selected note in a detached window |
| `Ctrl+Delete` | Trash (press twice; again to delete forever in Trash) |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Focus sidebar / list / editor |
| `Esc` | Clear search, then close |
| `Tab` | Insert two spaces |
| `Ctrl+V` / `Ctrl+Shift+V` | Paste text, or store a clipboard image and insert it |

Split is the default when the library is at least 1000 px wide; narrow layouts
open in Edit mode. The mode choice is remembered for the session once you click
a mode button or press `Ctrl+E`.

## Bar / IPC

The manifest declares `aliases: ["notes", "quill"]` and the widget's IpcHandler
target is `quill`:

```bash
omarchy-shell quill open
omarchy-shell quill capture        # new empty note, editor focused
omarchy-shell quill toggle
omarchy-shell quill openLibrary    # desktop window, title "Quill"
omarchy-shell quill close
```

Left click toggles the panel; right click opens capture mode. The panel is
centred under the bar at up to 1240×780; the desktop window defaults to the
same size (minimum 820×520) and your compositor may tile or resize it.

## Global hotkeys

Two Quill bindings live at the end of `~/.config/hypr/bindings.lua` (Omarchy's
defaults are untouched; `SUPER+SHIFT+N` is still Editor):

| Key | Action |
| --- | --- |
| `SUPER+N` | "Quill notes" — `omarchy-shell quill toggle` |
| `SUPER+ALT+N` | "Quill capture" — `omarchy-shell quill capture` |

They are ordinary `o.bind(...)` entries, so `omarchy menu keybindings` lists them
next to the defaults. After editing the Lua file, `hyprctl reload` applies it.

## Panes and View menu

The header has Edit / Split / Preview / **Agent** and a **View** menu in both
hosts. View lists Library, Notes, Editor, Preview and Agent with live
checkmarks; rows toggle without closing the menu, and **Reset layout** restores
both left panes, split mode and closes Agent. Editor and Preview can never both
be off: turning one off leaves the other visible, and both on means Split.

The Library and Notes headers each have a small **‹** button and collapse to a
slim rail with a **›** button and a vertical label. The state is per shell
session only. **Ctrl+1** / **Ctrl+2** reopen the target pane if it is collapsed
and then focus it; **Ctrl+F** also reopens Notes when needed. The detached note
window keeps its own fixed two-pane layout and is unaffected.

## Formatting toolbar

A slim toolbar sits above the editor in Edit and Split; it is hidden in
Preview-only and disabled for trashed or read-only notes. It scrolls
horizontally when the editor is narrow. Groups are undo/redo, inline emphasis,
highlight/colour/size/super/subscript, a heading menu, lists and blocks,
links/code, rule/table, an insert menu (date, time, note link) and clear
formatting. Buttons never take keyboard focus; after an action the editor
regains focus and the selection is restored.

The toolbar writes ordinary Markdown plus a tiny HTML whitelist that Joplin
also accepts:

| Action | Stored text |
| --- | --- |
| Bold / italic / strike | `**text**` / `*text*` / `~~text~~` |
| Underline | `<u>text</u>` |
| Highlight | `==text==` |
| Superscript / subscript | `<sup>text</sup>` / `<sub>text</sub>` |
| Heading | `#` … `######`; Normal removes the prefix |
| Date / time | `YYYY-MM-DD` / `HH:mm` at the caret |
| Note link | `[[Title]]`; the title stays selected |
| Colour | `<span style="color: rgb(224, 62, 45);">text</span>` |
| Size | `<span style="font-size: 10px;">…</span>` (S), no span (M), `18px` (L), `22px` (XL) |
| Lists | `- ` / `1. ` / `- [ ] ` / `> ` |
| Link | `[label](url)` |
| Table | GFM pipe table; the picker chooses body rows plus a header row |

Colours accept `#RGB`, `#RRGGBB` (with or without `#`) and `rgb(r, g, b)`
integers, and are stored in the same canonical `rgb(r, g, b)` form Joplin
writes. Old hex spans still parse and are replaced in place. Re-applying colour
to a coloured selection replaces the property instead of nesting spans;
**No colour** removes it. Small/Normal/Large/Extra
large use CSS pixels after probing Qt RichText: percentages and `em` were
ignored by Qt, while `px` and `<font size>` rendered. Pixels are therefore the
documented fallback; Joplin renders the same inline style in its HTML preview.

Qt's `Text.MarkdownText` paints `_text_` as **underline** even though Markdown
defines it as italic. Quill's editor underlay has always rendered italic; the
preview and agent chat now route underscore emphasis through `MathText.js`, so
all three agree. Use `<u>…</u>` for underline.

## Chat

The **Agent** button sits beside Edit / Split / Preview in both the panel and
the library window. It opens a 340 px dock on the right; the detached note
window never loads the chat. Agent remembers whether it was open for the
current shell session only. Below 980 px the dock refuses to open and shows
“Widen the window to use chat” instead of squeezing the editor.

The dock talks to the local OpenCode service through `scripts/quill-agent`, a
dependency-free Node process that owns HTTP + SSE. QML never sees an auth
header or an SSE frame:

- `AgentService.qml` writes one JSON command per stdin line and folds the
  bridge's stdout events into a `ListModel` (text/reasoning deltas update the
  existing row, so a streaming answer does not rebuild the transcript).
- Sessions are created at the Quill data root, which is also where
  `AGENTS.md` lives. The default OpenCode primary agent (`build`) is used and
  no model is pinned, so the user's normal default applies.
- The agent is told it is embedded in Quill and that the notes are its primary
  resource. It searches with `scripts/quill-store search`, reads with
  `quill-store read`, and can fall back to grep/glob. It remains a general
  assistant for anything else.
- `.quill-context.json` is rewritten atomically (400 ms debounce) with the open
  note and up to 2000 characters of selected text, so “this note”, “here” and
  “what I'm looking at” work without pasting content into the prompt.
- Assistant text renders through the same stack as the preview: Markdown via
  `Text.MarkdownText`, and blocks containing `$…$` / `$$…$$` via
  `MathText.toHtml` plus a dock-wide `MathService`. Tool calls show as compact
  rows (shell commands in monospace) that expand to a scrollable 220 px output
  box; reasoning is collapsed behind a dim **Thinking** row; permission
  requests offer Allow once / Always / Deny.
- The composer sends on Enter, inserts a newline on Shift+Enter and turns into
  Stop while the session is running. Deletion in the session picker needs a
  second click. Opening the dock never steals focus from the editor.

Service discovery and overrides:

```bash
opencode service status                       # http://127.0.0.1:<port>
QUILL_OPENCODE_URL=http://127.0.0.1:49374     # skip the status probe
QUILL_OPENCODE_PASSWORD=…                     # skip ~/.config/opencode/service.json
QUILL_AGENT=build                             # default primary agent
```

Authentication is HTTP Basic (`opencode:<password from service.json>`). The
bridge reconnects SSE with backoff and keeps running when the service goes
down; the dock shows the error with **Retry**. Its own log is
`~/.local/state/quill/agent.log`, capped at 256 KiB. Closing the dock (or the
library window) stops the bridge child, and the next open starts one fresh
process, so no `node … quill-agent` is left behind.

```bash
printf '%s\n' '{"type":"start","dataRoot":"'"$HOME"'/.local/share/quill"}' \
  '{"type":"sessions"}' | scripts/quill-agent
```

Commands: `start`, `sessions`, `new`, `open`, `prompt`, `interrupt`, `rename`,
`delete`, `context`, `reply`, `stop`. Events: `ready`, `error`, `sessions`,
`opened`, `history`, `delta`, `text`, `tool`, `status`, `permission`,
`permission-cleared`, `usage`. This is also the seam the tests drive.

## Detached note window

`Ctrl+Return` in the library flushes the current note and launches
`scripts/quill-window` with that note's id, title and data directory. The note
opens in a separate Quickshell process using the same `MarkdownEditor` and
`PreviewPane` components, in split view. It is editable: edits autosave after
450 ms through `quill-store write`, `Ctrl+S` saves immediately, and `Esc` or the
window close button flushes any pending edit and quits.

```bash
Q=~/.config/omarchy/plugins/matt.quill
$Q/scripts/quill-window <note-id> "Note title" "$HOME/.local/share/quill"
```

The launcher accepts `QUILL_DATA_DIR`, `QUILL_STORE_PATH` and `QUILL_NOTE_TITLE`
from the environment as defaults. A standalone `quickshell -p` process resolves
`qs.Commons`/`qs.Ui` relative to the QML file, and Omarchy's plugin validator
forbids symlinks inside a plugin, so `quill-window` stages a copy in
`~/.cache/quill/detached/` with links to `/usr/share/omarchy/shell/{Commons,Ui}`
and runs that. Re-running the launcher refreshes stale copies.

## Tables

Quill treats GitHub-flavoured Markdown tables as first-class blocks. A table
is a header row, a delimiter row and zero or more body rows:

```markdown
| Item | Qty | Price | Total |
| :--- | ---: | ---: | ---: |
| Alpha | 2 | 3.5 | =B1*C1 |
| Beta | 3 | 4 | =B2*C2 |
| Gamma | 1 | 10 | =SUM(D1:D2) |
```

Outer pipes are optional (`Item | Qty` works), escaped pipes (`a \| b`) and
pipes inside inline code (`` `a|b` ``) stay in one cell, and tables inside
fenced code blocks are left alone. Line numbers are tracked exactly, so a note
with two identical tables edits only the one you clicked.

### Preview

Tables render as real tables: bold header on a subtle surface, 1px separators,
zebra body rows, per-column alignment and right-aligned numbers. Formula cells
show their computed value with a faint accent tint and a small `ƒ` marker;
errors use the urgent colour. Wide tables scroll horizontally (Shift+wheel or
drag); long cells end in an ellipsis. Hover a table to see **Grid**, then click
anywhere on it to open the editor. Read-only notes show a **Read-only** hint
instead, and the detached window shows **Open in the library to edit** (tables
there are rendered, not editable).

### Grid

`Ctrl+T` in the editor inserts a 3×3 table and opens the grid; clicking a table
in the preview does the same. The grid replaces the preview area, not the
window. It has column letters, row numbers, a formula bar and a toolbar for
rows, columns, sorting and alignment.

| Key | Action |
| --- | --- |
| Arrows | Commit the cell and move the selection |
| `Tab` / `Shift+Tab` | Next / previous cell, wrapping at the ends |
| `Enter` | Commit and move down |
| `Esc` | Clear the selection, then close the grid |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Grid-local undo / redo (last 50 edits) |
| Typing | Replaces the selected cell's content |
| `Shift`+wheel | Scroll a wide sheet horizontally |

A formula bar above the grid shows the selected cell reference (`B3`), the raw
content, and the computed value or error. Edits commit on cell blur, `Enter`,
`Tab`, structural changes, closing the panel and after a 400 ms typing pause;
they go through the normal note autosave. Column widths follow their content
(90–320 px). Inserting or deleting rows/columns and sorting rearrange cells but
do not rewrite formula references; check formulas after a structural edit.

**Safety:** opening the grid snapshots the table's source lines. Writes
re-check those lines first. If lines were inserted above the table, the grid
follows it and writes at the new position. If the table's text changed while
the grid had no unsaved edits, the grid adopts the note's version. If both
sides changed, the grid shows a banner with **Use note** (take the note,
discard grid edits) and **Overwrite** (write the grid over the note); editing
stays possible and no write happens until you choose. If the table is deleted
from the note, the grid refuses to write and asks you to close it or undo the
note change.

### Formulas

A cell whose raw text starts with `=` is a formula. References use spreadsheet
coordinates where **A1 is the first body row, column A** (the header row is not
addressable). Supported syntax:

- Numbers, text in double quotes (`"yes"`), cell refs (`A1`, `$B$3`, `AA12`)
  and ranges (`A1:B10`).
- Operators `+ - * / % ^`, parentheses and unary `+`/`-`.
- Comparisons `= <> < > <= >=`.
- Functions, case-insensitive: `SUM`, `AVERAGE`/`AVG`, `MIN`, `MAX`, `COUNT`,
  `ROUND(x, n)`, `ABS(x)`, `IF(condition, a, b)`.
- Empty cells count as 0 in arithmetic but are skipped by `SUM`, `AVERAGE`,
  `MIN` and `MAX`; `COUNT` counts numeric cells. Numeric-looking text such as
  `-12` or `3.5` behaves as a number. Text in arithmetic is an error.
- Integers display plainly; floats use at most six decimals, without thousands
  separators.

| Error | Meaning |
| --- | --- |
| `#REF!` | Reference or range outside the table |
| `#DIV/0!` | Division or modulo by zero |
| `#NAME?` | Unknown function or name |
| `#VALUE!` | Text where a number was needed, or a bare range in arithmetic |
| `#CYCLE!` | Self or mutual cell reference |
| `#PARSE!` | Malformed formula |

Formulas are stored exactly as typed (`=SUM(...)`); Quill only computes them
for display. The raw Markdown remains the source of truth.

### Joplin caveat

Joplin receives the table as ordinary GFM and renders its rows and columns, but
it does **not** evaluate Quill's formulas: a synced cell shows the literal
`=SUM(B1:B3)` text. Values computed in Quill's preview never leave the local
note. Sorting in the grid rearranges rows only; it does not rewrite cell
references, so formulas that point at fixed rows can change meaning after a
sort. Alignment delimiters keep their existing spelling (`---` or `:---`) until
that column's alignment is changed; new columns use `:---`.

## Maths

Quill renders TeX maths in the preview — in the panel, the library window and
the detached note window — using a vendored copy of MathJax 3.2.2. It works
offline, follows the theme foreground colour, and does not alter the Markdown
on disk. Notes stay plain Markdown and Joplin sees the original TeX.

| Source | Meaning |
| --- | --- |
| `$x^2$` | inline maths |
| `\(x^2\)` | inline maths |
| `$$ … $$` | display maths, one line or several |
| `\[ … \]` | display maths, one line or several |

Fenced code blocks, inline code spans, escaped `\$` and prices such as `$5` or
`$1,200.50` are left as text. A display formula is shown centred at its natural
size and scaled down to the pane width if it is wider. If the TeX is invalid,
MathJax's red error message is shown with a subtle warning border; while a
formula is still rendering, the raw TeX stays visible in a dim box.

Maths is rendered by `scripts/quill-math` in one batched node process per note,
then cached as SVG files:

```bash
Q=~/.config/omarchy/plugins/matt.quill
$Q/scripts/quill-math --stats           # {"files":n,"bytes":n}
$Q/scripts/quill-math --purge           # drop every cached formula
```

`$XDG_CACHE_HOME/quill/math` (normally `~/.cache/quill/math`) holds the SVGs.
Keys include the TeX source, display/inline mode, colour and font size, so a
theme change renders a fresh set and never shows stale colours. The cache is
pruned to 2000 files / 64 MiB, oldest first. Per-formula failures are appended
to `~/.local/state/quill/math.log` (capped at 256 KB).

MathJax is vendored under `vendor/` (Apache-2.0) — nothing is installed
globally. See `vendor/README.md` for the reinstall and pruning notes.

**Joplin caveat:** the mirror receives the original `$…$` / `$$…$$` text
unchanged. To see maths in Joplin, enable
`Options → Markdown → Enable math expressions` (KaTeX). Quill does not rewrite
the note for Joplin and does not upload its rendered SVGs.

### Limits

- Maths inside table cells is not rendered; the grid shows the cell text as
  typed (and formulas that start with `=` are spreadsheet formulas, not TeX).
- Inline maths inside code spans and fenced code is intentionally ignored.
- A text block that contains inline maths is rendered by Quill's HTML
  converter as Qt RichText instead of `Text.MarkdownText`. Paragraph spacing is
  matched to MarkdownText, but exotic Markdown in the same block (footnotes,
  definition lists, raw HTML) may look slightly different, and MarkdownText-only
  niceties such as footnotes are not available in that block.
- Display maths is recognised when its markers start a top-level line (leading
  indentation is allowed). Markers nested inside blockquotes or list items are
  not split out reliably and may stay literal text.

## Images

Press `Ctrl+V` with an image on the Wayland clipboard to add it to the current
note. Quill writes the bytes to `<data>/attachments/<sha256>.<ext>` (mode 0644,
deduplicated by content), inserts `![Pasted image](<absolute path>)` on its own
line, and renders it in the preview. Pasting the same image twice reuses the
same file. Attachments live outside `notes/`, so they never show up as notes or
folders.

`scripts/quill-paste-image` decides between an image and a text paste: if the
clipboard has no PNG/JPEG/WebP/GIF/BMP it answers `no-image`, and if it also has
non-whitespace `text/plain` it answers `text-preferred`, so copying from a rich
source still pastes text. `Ctrl+Shift+V` behaves the same. If the helper is
missing or times out, the editor falls back to a normal text paste and shows the
error in the status bar.

```bash
S=~/.config/omarchy/plugins/matt.quill/scripts/quill-store
$S attachment save --file shot.png --name "Screenshot"
$S attachment save --stdin --name "Pasted image" < shot.png
$S attachment list                        # path, size, mtime, referenced
$S attachment gc [--dry-run]              # delete only unreferenced files
```

Only PNG, JPEG, GIF, WebP and BMP are accepted, up to 20 MiB. `gc` never deletes
a file mentioned by any note, including trashed notes, and skips symlinks.

### Image sizing

An image-only line can carry an explicit preview size after the closing `)`:

```markdown
![Screenshot](<path/to/shot.png>){width=320}
![Screenshot](<path/to/shot.png>){width=320px}
![Screenshot](<path/to/shot.png>){height=200}
![Screenshot](<path/to/shot.png>){width=320 height=200}
```

- `width` renders the image exactly that wide, preserving aspect ratio.
- `height` renders it exactly that tall, preserving aspect ratio (the width is
  reduced if that would not fit the preview pane).
- Both form a bounding box: the image is fitted inside `width × height` with
  its aspect ratio preserved.
- Sizes are clamped to 60 px minimum and the preview pane width maximum. A
  malformed or absurd value (for example `{width=abc}`) is ignored and the
  image keeps the default fit.
- Obsidian's `![alt|320](path)` width form is accepted when reading. The first
  edit in Quill rewrites it to the portable `{width=320}` form.
- With no size the previous behaviour is unchanged: full pane width, natural
  height capped at 420 px.

In the preview, hover an image to see a `NNN px` badge, a bottom-right drag
handle and a **Fit** button. Drag the handle horizontally for a live resize;
`Ctrl`+wheel over the image changes the width in 20 px steps (committed after a
short idle). Double-click the image (or click **Fit**) to remove the size and
return to the default fit. Each change is written back to that exact source
line — duplicate image paths are independent — and saved through the normal
autosave path. Trashed and read-only notes show no handles.

The Joplin mirror strips a trailing `{...width/height...}` suffix from image
tags before uploading, so Joplin users see the image without Quill's preview
hint.

**These images are not uploaded as Joplin resources yet.** `quill-joplin-sync`
mirrors the Markdown text only, so a synced note keeps the local absolute
attachment path instead of a Joplin resource. Uploading attachments is a
follow-up; export/sync currently assumes the Quill data directory is available
locally.

## Joplin sync

`~/.local/bin/quill-joplin-sync` mirrors `~/.local/share/quill/notes` into a
Joplin notebook called **Quill**. It is a thin wrapper around the proven
`omanano-joplin-sync` tool: local Markdown stays the source of truth, one Joplin
note is created per file, Quill's subfolders become nested notebooks, and the
relpath → note-id mapping lives in `~/.local/share/quill-joplin/state.json`.
Joplin's copy is only written to; an edit made in Joplin is skipped as a
conflict unless you pass `--force`.

Before the mirror replaces a Joplin note — and before `--prune` trashes one —
it fetches and saves the remote body under
`~/.local/share/quill/backups/joplin/<joplin-note-id>/`. Files are named
`<UTC YYYYmmddTHHMMSSZ>-<title-slug>-<sha256-prefix8>.md`, carry the title,
parent and `updated_time` in a small frontmatter header, and are deduplicated by
body SHA-256. The newest 50 per note are kept. A failed **fetch or write aborts
that update** (and a failed backup skips that prune) rather than overwriting
Joplin without a copy. Set `QUILL_JOPLIN_BACKUP_DIR` (or pass `--backup-dir`)
to use another location; `--dry-run` writes no backups.

`~/.local/bin/quill-joplin-tags` runs automatically after a successful sync and
mirrors tags onto the already-mapped notes: frontmatter `tags:` and inline
`#tag`, using Joplin's `POST /tags`, `POST /tags/<id>/notes` and
`DELETE /tags/<id>/notes/<noteId>`. The mapping is idempotent, and Joplin-side
tags on a Quill note are removed if Quill no longer has them. The tag pass is
best-effort and never changes the sync's exit status.

**Joplin must be running with `Options → Web Clipper → Enable web clipper
service` turned on.** When it is not, the sync exits with status 3 (the wrapper
and systemd unit treat that as "nothing to do", not a failure).

A systemd user timer runs the sync `2 min` after boot and every `5 min` after the
previous run. `--quiet` is used so journal output stays to one summary line.

```bash
quill-joplin-sync --dry-run            # show what would change, write nothing
quill-joplin-sync --verbose            # per-note detail
quill-joplin-sync --force              # overwrite edits made in Joplin
quill-joplin-sync --prune              # also trash notes deleted locally
systemctl --user start quill-joplin-sync.service
systemctl --user list-timers quill-joplin-sync.timer
journalctl --user -u quill-joplin-sync.service -n 20
quill-joplin-tags --dry-run            # tag pass on its own
```

### Reading a note back

Joplin edits are not mirrored automatically, but a read-back helper can copy
one remote body into Quill. It only issues `GET` requests: it never deletes,
trashes or updates Joplin data.

```bash
quill-joplin-restore --list                 # mapping status for the Quill notebook
quill-joplin-restore --list --json          # machine-readable
quill-joplin-restore --id <joplin-id> --dry-run
quill-joplin-restore --title "Feature list" --yes
quill-joplin-restore --id <joplin-id> --to-new
```

`--list` reports `unchanged`, `diverged`, `missing` or `unmapped` for every note
in **Quill** and its subfolders. A mapped note is recreated at its exact local
id when missing. An existing, different local note needs `--yes`; `quill-store`
snapshots it under `backups/versions/` first, and the state hash is updated so
the next sync sees the restored body as unchanged. `--to-new` creates a separate
local note and deliberately leaves the old mapping alone — the next sync will
therefore create a second Joplin note for that copy. Exit codes are 0
(success/no-op), 1 (error), 2 (ambiguous title or `--yes` needed) and 3 (Joplin
unreachable). The token is read from config/Joplin settings and never printed.

`~/.config/quill-joplin/config.json` records the same notebook, folder-mirroring
and path defaults for discoverability. It is **not read** by the shared sync
tool: the flags in `quill-joplin-sync` are the source of truth. The wrapper's
environment overrides are `QUILL_JOPLIN_NOTES_DIR`, `QUILL_JOPLIN_STATE`,
`QUILL_JOPLIN_NOTEBOOK`, `QUILL_JOPLIN_API_URL` and
`QUILL_JOPLIN_BACKUP_DIR`.

One quirk comes from the shared tool and is deliberately not patched there:

- Tags removed from a Quill note are detached from the Joplin note, but Joplin
  keeps the now-unused tag in its tag list (Joplin never deletes tags via the
  Data API).

## CLI

`scripts/quill-store` is standard-library-only and prints exactly one JSON
object on stdout. Failures print `{"error": "..."}` on stderr and exit 1.
Mutations take an exclusive `flock`, and writes are atomic, so concurrent
callers are safe. Before replacing different bytes, and before lossy
rename/move/trash/delete/pin/folder operations, the old bytes are snapshotted
under `backups/versions/` (newest 50 per note, autosave throttle 60s; see
`QUILL_VERSION_RETENTION` and `QUILL_VERSION_THROTTLE`). E2E harnesses must set
`QUILL_E2E=1` and use a clone root; mutating commands then refuse the live root.

```bash
S=~/.config/omarchy/plugins/matt.quill/scripts/quill-store
$S list [--trashed]
$S read <id> [--trashed]
printf '# Hello\n' | $S write <id> --stdin
printf '# Hello\n' | $S write <id> --create --stdin   # create a missing mapped id
$S create [--folder F] [--title T] [--content-stdin]
$S rename <id> --title "New title"
$S move <id> --folder "Work/Projects"
$S pin <id>; $S trash <id>; $S restore <id>; $S delete <id>
$S empty-trash
$S versions <id>                          # read-only snapshot listing
$S restore-version <id> <snapshot>         # exact bytes; basename or absolute path
$S folder create "Work/Projects"
$S folder rename "Work/Projects" "Archive"
$S folder delete "Archive" [--force]     # --force moves notes to the root
$S search "prefix query" --limit 50
$S tags
$S tag-rename old-tag new-tag
$S backlinks <id>
$S preview <id>                           # wiki/tag links become quill:// URLs
$S import-omanano
$S index --rebuild
$S attachment save --file IMG | --stdin [--name ALT]
$S attachment list
$S attachment gc [--dry-run]
$S stats
```

`write --content-file <path>` is an additive convenience used by the QML
editor, which cannot reliably close a child process's stdin. Files named
`.quill-save-*` are treated as throwaway buffers and removed after reading.
`write --create` lets a restore recreate an explicit mapped id: a missing file
is validated, given its parent folders, newline-normalised to LF and indexed
(no snapshot, because there is no previous content). If the file already
exists, `--create` changes nothing about today's snapshot and newline-preserving
write path.

`preview` strips the YAML frontmatter block (its title and tags are already
shown in the UI), then converts wiki links to
`[Alias](quill://note/<id>)` (or `quill://missing/<target>`), and inline tags
to `[#tag](quill://tag/<tag>)`. Fenced code, inline code, ordinary Markdown
links and bare URLs are left untouched.

The index refreshes incrementally by size + mtime, rebuilds automatically on
a schema-version change, and is safe to delete. Search uses FTS5 prefix
matching (`"term"*`) with `snippet()` highlights (`⟪…⟫` markers, rendered bold
by the note list). The library is capped at 2000 listed notes / folders per
call and 512 KiB of a note is indexed.

## Importing OmaNano

Once, from the plugin directory:

```bash
scripts/quill-store import-omanano
```

It copies `~/.local/share/omanano/notes/**/*.md` into `notes/`, keeps the
original filenames and mtimes, carries over pinned ids that exist, and never
overwrites an existing note. OmaNano's files are never moved or modified.

## Known limits

- No filesystem watcher: edits made outside Quill show up the next time the
  library refreshes (open, save, or a note action). A detached window and the
  library do not live-reload each other's saves; reopen the note to pick up
  outside edits.
- The desktop window and the detached note window are normal toplevels;
  Hyprland may tile them unless you add a float rule for `class:org.quickshell`.
- `folder delete --force` moves `.md` notes to the root and deletes other file
  types inside that folder. The UI only offers the non-forced form.
- Preview updates after autosave (600 ms) or `Ctrl+S`, because rendering is
  deliberately done from the backend's saved view of the note.
- Markdown rendering is Qt's GitHub-dialect `Text.MarkdownText`; exotic
  extensions (footnotes, definition lists, raw HTML) are not previewed. A text
  block containing inline maths is rendered as RichText instead, so those
  extensions are unavailable in that particular block (see **Maths → Limits**).
- Table formulas are Quill-only display helpers. Joplin shows the literal
  `=…` text, computed values are not exported, and sorting rows does not rewrite
  cell references.
