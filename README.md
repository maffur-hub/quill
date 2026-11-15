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
  ContextMenuItem.qml  one themed row for Quill's menus
  DraftBanner.qml      recover/discard prompt for an adjacent crash draft
  DraftWriter.qml      serialized atomic writer for adjacent crash drafts
  ExternalChangeBanner.qml  reload/keep prompt when a dirty note changed on disk
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
  TagSuggest.js        pure contextual tag extractor (shared, node-testable)
  TagSuggestPopup.qml  toggle chips + custom tags, then Apply
  MathText.js          Markdown → RichText HTML for blocks containing maths
  WritableGuard.js     pure live-root write guard (shared with tests)
  scripts/quill-store  Python 3 stdlib backend (JSON in / JSON out)
  scripts/quill-agent  Node JSONL bridge to the OpenCode service (chat)
  scripts/quill-paste-image  clipboard image → attachment store helper
  scripts/quill-spellcheck  local hunspell spellcheck helper (JSON in / JSON out)
  scripts/quill-math   offline TeX → themed SVG renderer (JSON in / JSON out)
  scripts/quill-export-html  Markdown → one standalone HTML file (images + SVG maths)
  scripts/quill-export-pdf   Markdown → PDF via that renderer + headless Chromium
  scripts/quill-reveal       show a note's file in the file manager, selected if possible
  scripts/quill-window launcher for Detached.qml (stages it for `qs -p`)
  scripts/qmlcheck     load every component in a headless shell (part of `scripts/test`)
  scripts/qmltest      drive a real component through a scenario, offscreen
  tests/               JS unit tests, store contract tests, QML behaviour cases
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
attachments/ pasted images and attached files, content-addressed
             (created on first paste or attach)
backups/versions/  local note snapshots (newest 50 per note)
backups/joplin/    remote Joplin bodies saved before replacement/trash
                   (newest 50 per Joplin note; see Joplin sync)
state.json   pinned note ids, saved searches, UI settings (`ui`)
index.db     derived SQLite index (WAL, FTS5)
.quill-context.json  note the chat currently sees (id, title, path, selection)
AGENTS.md    instructions for the chat agent (it is embedded in Quill)
```

New files are `<epoch_ms>-<8 hex>.md`. Bodies are UTF-8 Markdown, written with
an atomic temp-file + rename. The original newline style (LF or CRLF) is kept
on every save. Notes over 1 MiB are shown read-only ("too large") rather than
risking a partial write.

While a note is dirty, Quill also writes a debounced (150 ms) copy to
`<note path>.draft`, for example `notes/Work/plan.md.draft`. The suffix is
invisible to the `*.md` note scan and to the index. A normal save removes the
draft when it matches the saved body; a newer draft is kept. If Quill exits or
crashes before the save lands, the next open shows the stored note with a
**Recover**/**Discard** banner (see **Crash drafts** below).

Titles come from frontmatter `title:`, otherwise the first non-empty line with
heading/list markers and `` ` `` `*` `_` `~` stripped, capped at 120 chars.
Tags come from frontmatter `tags:` and inline `#tag` outside code fences and
inline code. `[[Target]]`, `[[Target|Alias]]` and `[[Target#Heading]]` resolve
case-insensitively by title, then filename stem.

### Tag suggestions

The `+ Tag` chip at the end of a note's tag row suggests tags derived from that
note's own title, headings and body — locally and offline, never from its
folder or a generic list of every tag in the library. Tags already on the note
are excluded, and a library tag gets only a small ranking boost when the same
concept actually appears in the note.

Suggestions are proposals, not silent edits: toggle the ones you want, add
comma- or space-separated tags in the field, then **Apply**. Any pending editor
save is written first; the chosen tags are then appended to the end of the
body as inline `#tags` (an existing trailing tag line is extended in place,
and YAML frontmatter is never rewritten). The chips, sidebar counts and Joplin
mirror update as usual. The chip is hidden for trashed, read-only, too-large
and draft-pending notes.

The sidebar groups nested tags by their `/` segments. `#project/app` and
`#project/site` both live under a `#project` parent whose count is the whole
subtree; clicking the parent filters to every note carrying that prefix, and
clicking a leaf filters to that exact tag. Right-click a real tag (or use its
`⋯` button) to rename it, merge it into another tag, or delete it everywhere.
Renaming onto an existing tag merges the two and removes the duplicate
entries; every affected note is snapshotted first, so a bulk mistake is
recoverable from version history.

## Crash drafts

Edits are saved to the note after 600 ms, and a separate draft is written
150 ms after typing stops. The two are independent: if the shell is killed,
the machine loses power, or the note write keeps failing, the draft survives
next to the note.

On open, `quill-store read` reports a draft only when its newline-normalised
text differs from the stored note, the note is not in Trash, and the note is
not too large to edit. The library and detached window then show the **stored**
note with editing (and the format bar) disabled, plus a banner such as
"Unsaved draft from Oct 27, 14:05":

- **Recover** replaces the editor with the draft, marks it dirty and saves it
  through the normal path immediately. The store then removes the draft it
  just saved.
- **Discard** deletes the adjacent draft and re-enables editing.
- Switching notes, closing the library or closing the detached window leaves a
  pending draft on disk; the banner returns next time the note is opened.

Draft writes never wake the Joplin sync. Only the normal note save does.

A draft follows its note through a move, a trash, a restore, a folder rename
and a `folder delete --force`, so renaming or reorganising while a recovery is
pending does not lose it. A draft is never moved onto an existing one: the
destination wins and the older file is left where it is.

## Shortcuts

| Key | Action |
| --- | --- |
| `Ctrl+N` | New note |
| `Ctrl+Shift+N` | New note in the current folder |
| `Ctrl+F`, `/` | Focus search |
| `Ctrl+Shift+F` | Focus search and show the filter grammar hint |
| `Ctrl+P` | Quick switcher: jump to any note; `Ctrl+Enter` opens it detached |
| `Ctrl+Shift+P` | Pin / unpin the selection |
| `Ctrl+A` | Select all visible notes |
| `Ctrl+click`, `Shift+click` | Toggle one row / extend the range from the anchor |
| `Shift+↑` / `Shift+↓` | Move the active note and extend the selection |
| `Ctrl+Shift+T` | Add or remove tags on the selection |
| `Ctrl+E` | Cycle Edit → Split → Preview |
| `Ctrl+T` | Insert a 3×3 table at the caret and open the grid |
| `Ctrl+S` | Flush the 600 ms autosave now |
| `Ctrl+Shift+O` | Open the current note in Omarchy's editor (pencil button) |
| `Ctrl+Shift+E` | Export the current buffer as Markdown, HTML or PDF |
| `Ctrl+B` / `Ctrl+I` | Bold / italic |
| `Ctrl+U` / `Ctrl+Shift+X` | Underline / strikethrough |
| `Ctrl+Shift+H` | Highlight (==text==) |
| `Ctrl+K` | Link popover |
| `Ctrl+Shift+K` | Note-link popover |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| `Ctrl+Shift+Enter` | Open the library in its own window |
| `Ctrl+Return` | Open the selected note in a detached window |
| `Ctrl+Shift+Delete` | Trash the selection (press twice; again to delete forever in Trash) |
| `Shift+F10`, `Menu` | Note actions menu for the selected note |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Focus sidebar / list / editor |
| `Esc` | Clear search, then close |
| `Tab` / `Shift+Tab` | Insert two spaces, or indent / outdent the selected lines |
| `Ctrl+V` / `Ctrl+Shift+V` | Paste text, or store a clipboard image and insert it |
| `Ctrl+C` | Copy selected preview text (when the preview has focus) |

Split is the default when the library is at least 1000 px wide; narrow layouts
open in Edit mode. The mode choice is remembered across restarts once you click
a mode button or press `Ctrl+E` (see [Settings](#settings)).

## Creating notes and templates

**New note** (and `Ctrl+N`) creates a blank `# Untitled` note immediately.
`Ctrl+Shift+N` does the same in the current folder. The small `▾` beside the
New note button opens the template menu.

Templates are Markdown files in `<data>/templates/`, one per template, with
frontmatter for `name`, `description` and `icon`:

```markdown
---
name: Weekly review
description: What moved, what stalled, what is next
icon: ★
---

# Weekly review — {{date}}

## Wins
-
```

The four templates that ship with Quill (Meeting notes, Daily log, Project
spec, Task list) are written there on first run and can be edited, renamed or
deleted like any other. **Manage templates…** at the bottom of the menu opens
the editor: pick a template or press **New template**, set the fields and body,
then **Save** (or **Delete…** twice). Adding a template never requires editing
QML — `quill-store templates save weekly-review --name … --content-file …`
works too, and the menu picks it up on the next open.

Templates fill `{{date}}`, `{{time}}` and `{{datetime}}` with the local time
when the note is created; any other `{{…}}` is left as written. The menu also
has a **Blank note** row. Templates are plain Markdown; edit or delete any
section after creation.

## Note actions

Right-click a row in the note list (or select it and press `Shift+F10` or the
`Menu` key) to open a themed context menu at the pointer. It flips and clamps
to stay inside the window. On an active note the menu offers **Pin** /
**Unpin**, **Rename…**, **Duplicate**, **Move to folder…**, **Add tag…**,
**Remove tag…**, **Move to Trash**, and **Select all** when more than one row is
visible; the folder chooser lists Inbox and every folder. With more than one
row selected the same menu shows plural bulk actions and drops Rename and
Duplicate. In Trash it offers **Restore** and **Delete forever…**.

**Open file location** shows the note's Markdown file in the file manager with
the file selected — via the desktop's `org.freedesktop.FileManager1` interface,
falling back to `nautilus`/`dolphin`/`thunar --select`, then to opening the
folder. It also appears in the Trash menu, where it points into `trash/`.

**Rename** opens a modal with the current title prefilled and keeps the same
file id. A frontmatter `title` is updated when present, otherwise the first
heading is. **Duplicate** copies the note bytes and tags into the same folder
under a fresh id and picks the first free title suffix: `<title> copy`,
`<title> copy 2`, and so on. A trailing ` copy` / ` copy N` is replaced, pins
are not copied, and the new copy is selected after the list refreshes.

**Delete forever…** always opens a confirmation dialog naming the note.
Closing the menu is not a confirmation.

## Bulk actions

Select more than one row with `Ctrl+click`, a `Shift+click` range, `Shift+↑` /
`Shift+↓`, or `Ctrl+A`. Ranges grow from the row where the selection started,
so the same keys can shrink a range again. The row the editor is showing stays
the active note and follows the end of a Shift range.

The context menu and keyboard shortcuts then act on the whole selection:
**Pin 3 notes**, **Move 3 notes to folder…**, **Move 3 notes to Trash**,
**Add tag…**, **Remove tag…**, and **Ctrl+Shift+P** / **Ctrl+Shift+Delete** /
**Ctrl+Shift+T** do the same without opening the menu. **Ctrl+Shift+Delete** still asks
for a second press. In Trash the same selection can be restored or deleted
forever in one action. The bulk tag prompt takes one space- or
comma-separated list.

Dragging a row onto a folder in the library rail moves it there; dragging a
row that is part of a multi-selection moves the whole selection. Dropping on
**Inbox** clears the folder. After a trash, the status bar shows **Undo** for
twelve seconds; it restores that whole batch in one step. A second trash
replaces the pending Undo.

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
slim rail with a **›** button and a vertical label. Both are restored on the
next start while **Reopen last session** is on. **Ctrl+1** / **Ctrl+2** reopen
the target pane if it is collapsed and then focus it; **Ctrl+F** also reopens
Notes when needed. The detached note window keeps its own fixed two-pane layout
and is unaffected.

The gear beside the Edit / Split / Preview buttons opens **Settings**, described
below. Opening Settings closes the View menu and vice versa; Escape, a click
outside, or the window losing focus closes it.

## Linked scrolling

In split mode the editor and the preview can follow each other. The chain button
in the header turns this on and off, and Settings picks how the two panes are
matched:

| Mode | Behaviour |
| --- | --- |
| Off | The panes scroll independently |
| By position | Each pane mirrors its fraction of the scrollable range |
| By line | The same source line stays at the top of both panes |

**By line** is the default mode, and the accurate one. Every preview block
records the source lines it renders (`PreviewBlocks.js` stamps
`startLine`/`endLine`), and `PreviewSync.js` converts a line to a pixel offset
and back between those block anchors. The editor side uses
`positionToRectangle` / `positionAt` over a cached line-start table, since
`TextEdit` exposes no line lookup. Block boundaries are exact; inside a block the
mapping is interpolated, so a very long paragraph whose lines wrap differently in
the two panes can drift by a line or two.

Linked scrolling is a stored preference rather than a session flag, so the
mode you choose survives a shell restart.

## Settings

The gear beside Edit / Split / Preview opens a panel under the header with every
preference in one place:

| Setting | Values |
| --- | --- |
| Reopen last session | on / off |
| Linked scrolling | off / by position / by line |
| Spellcheck | on / off |
| Syntax highlighting | on / off |
| Printer | System default, or any CUPS queue |
| Copies | 1–9 |

Choices are written 400 ms after a change and flushed when the window closes.
They live in `<data root>/state.json` under `ui`, next to pins and saved
searches, so they survive a shell restart. The store owns the file:
`quill-store settings get` returns `{"ui": …}` and `settings set --json '<object>'`
replaces it; the keys are opaque to the CLI, which only enforces a 64 KiB cap
and 64-character key names. Editing preferences therefore never touches a note.

### Reopening where you left off

With **Reopen last session** on, the next shell start restores the note you had
open, the Edit / Split / Preview mode, the library and notes panes if they were
visible, and the active view — All, Pinned, Recent, Trash, a folder or a tag. A
saved note, folder or tag that no longer exists is dropped: the window falls
back to All notes and the first visible row rather than opening empty.

Turn the toggle off to always start from the default layout with nothing
selected. The other settings — spellcheck, highlighting, printer, copies and
linked scrolling — are remembered either way.

The panel's own state is read once at startup, before the first list is loaded,
so the restored category is in place when the notes arrive and the first row is
never selected over the note you left open. If the store does not answer within
two seconds the defaults are used and the window opens normally.

## Search filters

The search box takes filters in the same query string as ordinary words:

| Filter | Matches |
| --- | --- |
| `tag:alpha`, `tag:"two words"` | Notes carrying that tag |
| `folder:Projects` | That folder and every folder below it |
| `folder:` | The Inbox (notes with no folder) |
| `after:2025-01-01` | Modified on or after that local day |
| `before:2025-02-01` | Modified before that local day |
| `"exact phrase"` | Words in that order |
| `-term`, `-tag:x`, `-folder:y` | Exclude a word or filter |

Plain terms still use prefix matching and the typo-tolerant fallback, so
`proj` finds "project" and near misses appear with `≈`. **Ctrl+Shift+F** focuses
the search box and shows a one-line reminder of the grammar without replacing
the current query.

Searches worth keeping can be saved from the sidebar: run a query, then click
**＋** beside the **SEARCHES** header. Clicking a saved search re-runs it, and
**×** on the row removes it. Saved searches live in the store (`quill-store
searches`), not in shell configuration.

## Formatting toolbar

A slim toolbar sits above the editor in Edit and Split; it is hidden in
Preview-only and disabled for trashed or read-only notes. It scrolls
horizontally when the editor is narrow. Groups are undo/redo, inline emphasis,
highlight/colour/size/super/subscript, a heading menu, lists and blocks,
links/code, rule/table, an insert menu (date, time, emoji, attach file, note
link) and clear formatting. Buttons never take keyboard focus; after an action
the editor regains focus and the selection is restored.

Right-clicking the editor opens a compact horizontal icon strip centred above
the pointer (it flips below the click near the top edge). It carries
undo/redo, the clipboard actions, select all, a spelling-suggestions action,
the inline formatting actions and date/time insertion; each icon has a
tooltip. It works in both the Library and detached note windows.

The toolbar writes ordinary Markdown plus a tiny HTML whitelist that Joplin
also accepts:

| Action | Stored text |
| --- | --- |
| Bold / italic / strike | `**text**` / `*text*` / `~~text~~` |
| Underline | `<u>text</u>` |
| Highlight | `==text==` |
| Highlight colour | `<span style="background-color: rgb(191, 237, 210);">text</span>`; **No colour** removes it |
| Superscript / subscript | `<sup>text</sup>` / `<sub>text</sub>` |
| Heading | `#` … `######`; Normal removes the prefix |
| Date / time | `YYYY-MM-DD` / `HH:mm` at the caret |
| Emoji | the chosen glyph at the caret, from a searchable local picker |
| Note link | `[[Title]]`; the title stays selected |
| Colour | `<span style="color: rgb(224, 62, 45);">text</span>` |
| Size | `<span style="font-size: 10px;">…</span>` (S), no span (M), `18px` (L), `22px` (XL) |
| Lists | `- ` / `1. ` / `- [ ] ` / `> ` |
| Link | `[label](url)` |
| Table | GFM pipe table; the picker chooses body rows plus a header row |

**Emoji** opens a compact searchable grid from a curated built-in list; names
and keywords match case-insensitively, Enter inserts the first result and
Escape closes the picker. It needs no network or system emoji package, and the
inserted glyph is ordinary text at the caret.

Colours accept `#RGB`, `#RRGGBB` (with or without `#`) and `rgb(r, g, b)`
integers, and are stored in the same canonical `rgb(r, g, b)` form Joplin
writes. Old hex spans still parse and are replaced in place. Re-applying colour
to a coloured selection replaces the property instead of nesting spans;
**No colour** removes it. Small/Normal/Large/Extra
large use CSS pixels after probing Qt RichText: percentages and `em` were
ignored by Qt, while `px` and `<font size>` rendered. Pixels are therefore the
documented fallback; Joplin renders the same inline style in its HTML preview.

### Highlight colours

`==text==` remains the default yellow highlight. The chevron beside the
highlight button opens a small palette (yellow, green, blue, pink, orange,
purple); choosing a colour stores an ordinary
`<span style="background-color: rgb(r, g, b);">text</span>`, which Joplin also
renders. After a colour has been chosen the main highlight button applies that
colour; pick the yellow swatch to return to `==`. **No colour** removes only
the background property and leaves text colour, size, underline and other
formatting intact. Quill computes a readable dark or light text colour when
rendering, so the note itself never stores a theme-dependent `color` value.

Qt's `Text.MarkdownText` paints `_text_` as **underline** even though Markdown
defines it as italic. Quill's editor underlay has always rendered italic; the
preview and agent chat now route underscore emphasis through `MathText.js`, so
all three agree. Use `<u>…</u>` for underline.

## Spellcheck

Spelling is checked locally with `hunspell` through
`scripts/quill-spellcheck`; nothing leaves the machine and no service is
contacted. The helper reads the note body on stdin and returns JSON with
UTF-16 offsets (the same indexing QML uses, including for emoji). After about
800 ms without typing, misspelled prose words get a subtle red squiggle in the
editor, drawn by a Canvas behind the transparent TextArea so selection, the
caret, IME and undo/redo behave normally.

The right-click strip has a **Spelling** action. It opens a themed suggestion
popup for the misspelled word under the click (or under the caret): choose a
suggestion to replace exactly that word, or see “No suggestions”. The list
comes from the local dictionary; applying one is a normal edit, so native
undo still works. The action is disabled for read-only notes and when no
suggestion target is available.

Markdown is masked before checking, so the following never produce squiggles:
YAML frontmatter, fenced (``` / ~~~) and inline code, URLs, `www.` addresses
and email addresses, Markdown link destinations, wiki links (`[[…]]`), inline
`#tags`, HTML tags and entities, and `$…$`, `$$…$$`, `\(…\)` or `\[…\]`
maths. Prose inside link text and headings is still checked. Single-letter
tokens, pure numbers and short all-caps acronyms are skipped.

The default dictionary is `en_AU`. Set `QUILL_HUNSPELL` to use a different
hunspell binary and `QUILL_HUNSPELL_DICTIONARY` to pass a different `-d`
dictionary. A missing binary or dictionary is reported through the editor's
`spellError` property rather than blocking editing. Spellcheck is skipped for
notes over 200,000 characters; the helper also caps input at 2 MiB and 5,000
unique words. This is **spellcheck only: there is no grammar checking** and no
LanguageTool or network integration.

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

## External editor

The pencil button in the note header (or `Ctrl+Shift+O`) opens the current
note's Markdown file in Omarchy's configured editor. It calls
`omarchy-launch-editor` without `--inline`, so `$EDITOR` opens in a terminal
rather than inside the GUI process, and Omarchy's GUI editor choice is respected
when one is configured. Pending edits are flushed first; the editor is launched
only after the save lands, so it never starts from stale bytes.

The open note is watched for changes on disk. Saves made by that editor, Git,
Syncthing or another Quill window reload the note silently when the buffer is
clean, keeping the caret position and scroll offset. The library and detached
note windows therefore live-reload each other's saves. A too-large note can
still be opened externally as an escape hatch, but it is not watched while
Quill shows it read-only.

If the note changed on disk **and** the buffer has unsaved edits, Quill does not
choose for you: it shows a **This note changed on disk** banner (and refuses
autosaves so the external text is not overwritten). **Reload** replaces the
buffer with the disk text; **Keep mine** keeps the local text and saves it over
the external change.

## Markdown preview

The preview splits a note into blocks, so it can render what Qt's
`Text.MarkdownText` cannot: task checkboxes, GFM tables, images with the size
handles described below, display and inline maths, footnotes (`[^note]`, with
first-reference numbering and a clickable jump to the notes section), Pandoc
definition lists (a bold `Term` line followed by indented `: definition`
lines), and syntax-highlighted fenced code for JavaScript/TypeScript, Python,
shell, JSON, YAML, HTML/CSS, SQL, Rust, C/C++, Go, Markdown and diff. Nested
blockquotes, inline `<kbd>` key caps (theme-coloured) and `<mark>` highlights
render through the RichText path.

Raw HTML is a sanitised allowlist (`<u>`, `<span style>`, `<sup>`, `<sub>`,
`<kbd>`, `<mark>`, `<b>`, `<i>`, `<s>`, `<code>`, `<var>`, `<samp>`, `<cite>`,
`<dfn>`, `<del>`, `<ins>`, `<br>`), not full HTML: anything else stays literal
text. The preview renders the live editor buffer (200 ms after typing stops,
through `preview --content-file`), so edits appear without waiting for the
autosave. Trashed, read-only and draft-pending notes keep showing the saved
body.

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
drag) and show a slim scroll bar along the bottom whenever the columns overflow;
the bar sits in reserved space so it never covers the last row. Long cells end
in an ellipsis. Hover a table to see **Grid**, then click
anywhere on it to open the editor. Read-only notes show a **Read-only** hint
instead, and the detached window shows **Open in the library to edit** (tables
there are rendered, not editable).

Task lines (`- [ ] buy milk`, `* [x] done`, `+ [ ] nested`) render as themed
checkboxes in the preview. Clicking a checkbox flips `[ ]` ↔ `[x]` in the note
and the normal autosave mirrors the change to Joplin; read-only notes show the
state without accepting clicks, and task-looking lines inside fenced code
blocks stay as plain code.

Select prose or a task label with the mouse, then press `Ctrl+C` to copy it to
the Wayland clipboard. Selections are per rendered block: a prose block usually
contains several paragraphs, and each task label is its own block. Moving the
selection to another block clears the previous highlight, and `Ctrl+C` always
belongs to the editor while the editor has focus. Table cells are not selected
in the preview; click the table to open the grid, where cells can be selected,
edited and copied. Dragging over prose selects text rather than scrolling the
preview; use the wheel or trackpad to scroll.

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

Wide sheets also show a slim horizontal scroll bar below the cells, in space
reserved for it, so the last visible row is never covered.

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
  matched to MarkdownText, but raw HTML in the same block follows the
  sanitised allowlist, so it can look slightly different. Footnotes and
  definition lists have their own blocks and are unaffected.
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

Only PNG, JPEG, GIF, WebP and BMP are accepted from the clipboard, up to
20 MiB; `attachment save` accepts any regular file (see **Attachments**). `gc`
never deletes a file mentioned by any note, including trashed notes, and skips
symlinks.

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

Pasted images are ordinary attachments, so the next sync uploads them as Joplin
resources (see **Attachments → Joplin**). The preview and HTML export still
read the file from the Quill data directory.

## Attachments

**Attach file…** in the editor's Insert (⊕) menu copies a file into the library
and links it from the current note. The picker is a themed in-app browser, not a
system file dialog: click a folder to open it, use **↑ Up** to go back, tick
**Hidden files** to show dotfiles, type in **Filter…** to narrow the list, or
type a path in the field at the bottom — Enter there opens a directory or
attaches a file. A single click on a file selects it; double-click it, or press
**Attach**, to attach. The picker is not offered for trashed or read-only
notes, or while a crash-draft banner is up. The status bar confirms
**File attached** or shows the store's error message.

**Draw…** in the same menu opens a modal freehand canvas. Pick one of the
palette swatches, choose a brush width (2, 4, 8 or 16 px) and drag on the white
surface; **Eraser** paints in white, **Undo** removes the last stroke and
**Clear** starts over. **Insert** exports the sketch as a PNG and adds it to
the note at the caret through the same attachment pipeline, so the image is
content-addressed under `<data>/attachments/` and mirrored to Joplin like any
other attached image. The exported file always has a white background, even in
a dark theme. **Cancel** or Escape closes the canvas without touching the note
or writing a file. The canvas is not offered for trashed or read-only notes.

The store copies the bytes to `<data>/attachments/<sha256>.<ext>` (mode 0644,
20 MiB maximum) and links that copy. Nothing is linked in place, so the original
can be moved or deleted afterwards without breaking the note, and the note stays
ordinary Markdown. Identical bytes are stored once, in one note or many. Images
are recognised by their magic bytes and get one of `.png`, `.jpg`, `.gif`,
`.webp` or `.bmp`; any other regular file keeps its own lowercased suffix when
that is 1–10 letters or digits, and otherwise gets `.bin`.

An attached image is written as `![alt](/abs/path.png)` and any other file as
`[alt](/abs/path.pdf)`, with angle brackets only when the path contains a space
or parenthesis. The link is inserted on its own line at the caret; clicking it
in the preview opens the file with the system default application. Alt text
comes from `--name`, with square and round brackets and control characters
stripped; without it, images fall back to `image` and other files to the source
name without its suffix. The picker passes the chosen file's name as the alt.

```bash
S=~/.config/omarchy/plugins/matt.quill/scripts/quill-store
$S attachment save --file PATH [--name ALT]
$S attachment list                        # path, size, mtime, referenced
$S attachment gc [--dry-run]              # delete only unreferenced files
```

`attachment save` prints one JSON object with `id`, `path`, `markdown`, `kind`
(`image` or `file`), `name` (the stored basename), `size`, `mime` and `deduped`.
It accepts any regular file; empty files, directories, FIFOs and files over
20 MiB are refused. `attachment list` reports whether each file is referenced by
a note. `attachment gc` deletes only unreferenced files: anything mentioned by a
note, including a trashed note, is kept, and `--dry-run` only reports.

### Joplin

On the next sync, each attachment a note references is uploaded once as a
Joplin resource and the mirrored body is rewritten to Joplin's `:/<id>` form,
for example `![shot](:/r1a2b3c)`. The id is cached in the sync state under
`resources`, keyed by the content-addressed filename, so later edits reuse it,
notes sharing a file share one resource, and a resource purged in Joplin is
uploaded again. A note mirrored before this feature gets its attachments on its
next sync, because the rewrite changes its body once.

Only files inside `attachments/` are uploaded. A link to anywhere else, or a
symlink that resolves outside the directory, is left as written; a referenced
file that has gone missing warns once and stays a local path in the mirrored
body. `--dry-run` uploads nothing and writes no state; with `--verbose` it
reports `would upload resource: <name>`.

Attachments are never deleted from Joplin: resources are shared objects, and
`--prune` still only trashes notes. `quill-joplin-restore` stays GET-only and
leaves `:/<id>` links exactly as Joplin wrote them, so a restored note points at
Joplin's store rather than the local `attachments/` file.

## Export

The **Export** button in the note header (or `Ctrl+Shift+E`) opens a themed
dialog for the current editor buffer:

- **Markdown** writes exactly what is in the editor, byte for byte, to the
  chosen path. The default is `~/<note title>.md`.
- **HTML** writes one standalone file with embedded CSS, local images as
  base64 `data:` URIs and maths as inline SVG. Remote `http(s)` images stay
  remote; missing, non-image or larger-than-10-MiB files become an inline
  "missing image" note instead of breaking the export.
- **PDF** reuses that HTML renderer, injects a print stylesheet and prints it
  with a headless Chromium/Chrome: A4 paper with 18 mm margins by default (the
  screen wrapper's padding is dropped on paper, so the margin is the whole
  margin),
  code wrapped instead of clipped, and blocks kept off page breaks. It needs
  `chromium` (or another Chrome-family browser) on `PATH`, or `QUILL_CHROMIUM`
  pointing at one; when no browser is found the export fails with a clear
  message and writes nothing. Only the chosen PDF file is written.

The dialog validates absolute paths, expands a leading `~/`, and never creates
parent directories. Export reads the live buffer, so unsaved edits are
included, but it does not save the note, create a Joplin note, or wake the
Joplin sync. `scripts/quill-export-html` is the self-contained renderer used by
the HTML option; it uses the vendored MathJax tree and needs no install step.
`scripts/quill-export-pdf` drives that renderer and a headless browser for the
PDF option.

## Printing

The **Print** button sits beside **Export** in the note header, or press
`Ctrl+Alt+P`. Both open Quill's own print dialog: the note title, a **Printer**
menu, one menu for each option the queue actually supports — normally **Paper**,
**Colour**, **Two-sided** and **Quality** — a **Margins** menu, a **Copies**
stepper, and **Cancel / Preview / Print**. Every menu row shows the current value
and opens a list of everything the queue offers, with a checkmark on the active
one.

Those option rows come from the printer, not from Quill: the dialog reads
`lpoptions -p <queue> -l` and shows only the settings that queue reports, in the
driver's own values. A queue that offers greyscale and duplex therefore grows
**Colour — Greyscale** and **Two-sided — Long edge** rows, while a driver with
no duplex shows none. Switching the printer reloads them, and each choice is
remembered for the next print.

**Margins** is Quill's own, not the driver's: **Narrow** 10 mm, **Normal** 15 mm
(the default) and **Wide** 22 mm, applied as the PDF's `@page` margin. The
renderer drops its on-screen wrapper padding on paper, so the page margin is the
only margin — a note that opens with a heading starts at the margin instead of
being pushed down by the heading's own spacing.

The dialog exists because there is no system print dialog to borrow — no GTK
print dialog and no portal one — so **Print** would otherwise submit silently to
whatever CUPS considers the default. The **Printer** row shows the queue's state
next to the name, including CUPS complaints such as an offline printer or a
failing filter, so a job that would disappear into the queue is visible first.

**Preview** renders the PDF, keeps it, and opens it in your default viewer with
`xdg-open`. That is where a real print dialog lives: check the pages, then print
from the viewer. Preview submits nothing to CUPS, and Quill closes as the viewer
comes up — the library floats above ordinary windows, so leaving it open would
hide the pages you just asked to see.

Printing uses the same PDF renderer as **PDF** export and hands the file to
`scripts/quill-print`, which submits it with `lp`. The note file is never
modified: Print reads the live editor buffer, so unsaved edits are included, but
it does not save the note or touch the Joplin queue. The temporary Markdown is
always removed, and a job PDF is removed unless a preview needed it.

`scripts/quill-print --list` prints the queues, their state, the current default
and the options the selected queue supports as JSON. The printer, the copy count
and every option choice are remembered in **Settings**; `--printer NAME`,
`--copies N`, `--page-margin <css-length>`, repeatable `--option KEY=VALUE` and
`--render-only` are the same knobs on the command line, and an option is rejected if the queue does not list
it.

Failures are reported inside the dialog, in the warning colour: a missing
printer, a stopped CUPS daemon, a script that will not run, or stderr from `lp`.
A job CUPS accepts while the queue reports a problem is reported the same way —
accepting a job is not printing it — so a queue with a failing filter cannot fail
silently, with only a cheerful job number to show for it.

## Joplin sync

`~/.local/bin/quill-joplin-sync` mirrors `~/.local/share/quill/notes` into a
Joplin notebook called **Quill**. It is a thin wrapper around the proven
`omanano-joplin-sync` tool: local Markdown stays the source of truth, one Joplin
note is created per file, Quill's subfolders become nested notebooks, and the
relpath → note-id mapping lives in `~/.local/share/quill-joplin/state.json`.
Joplin's copy is only written to; an edit made in Joplin is skipped as a
conflict unless you pass `--force`. Attachments referenced by a note are
uploaded as Joplin resources (see **Attachments → Joplin**).

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
service` turned on** to receive notes. When it is not, the sync exits with
status 3 and the pending work stays queued; nothing is lost. No API call is
made while the queue is empty, so a closed Joplin costs nothing until the next
save.

Sync is **save-triggered**. After Quill saves a note, it waits `2.5 s` for
further autosaves (debounce) and then calls `quill-joplin-sync --notify`, which
writes a pending marker and starts one detached worker. The worker syncs
immediately, repeats the normal tag pass, and then exits once the queue is
drained. If Joplin is unreachable (exit 3) it retries only while work is
pending, using `10 30 60 120 300 600 900` second backoff (the last delay
repeats), up to 8 attempts. Other failures are logged and deferred rather than
retried in a tight loop. A new save during a sync queues exactly one more run.

A systemd user timer wakes `2 min` after boot and every `15 min` after the
previous run, but it runs `--flush`, which does nothing (and makes no network
call) unless a pending marker exists. It is a safety net for work deferred
after the retry limit or while the shell was not running, not the primary
trigger.

The queue lives in `~/.local/share/quill-joplin/queue/` (override with
`QUILL_JOPLIN_QUEUE_DIR`): `pending` is the marker, `queue.lock` enforces one
worker, and `queue.log` records attempts and is rotated at 256 KiB. The worker
also retries after the retry budget on the next timer wake. Set
`QUILL_JOPLIN_QUEUE_BACKOFF` and `QUILL_JOPLIN_QUEUE_MAX_ATTEMPTS` to tune it,
or `QUILL_JOPLIN_AUTOSYNC=0` to disable save-triggered sync entirely (the
timer then stays idle until you run the sync by hand).

```bash
quill-joplin-sync                      # sync now
quill-joplin-sync --notify             # queue a sync after a save (Quill's call)
quill-joplin-sync --flush              # start the worker only if work is pending
quill-joplin-sync --work               # run the worker loop in the foreground
quill-joplin-sync --dry-run            # show what would change, write nothing
quill-joplin-sync --verbose            # per-note detail
quill-joplin-sync --force              # overwrite edits made in Joplin
quill-joplin-sync --prune              # also trash notes deleted locally
systemctl --user start quill-joplin-sync.service
systemctl --user list-timers quill-joplin-sync.timer
journalctl --user -u quill-joplin-sync.service -n 20
tail -f ~/.local/share/quill-joplin/queue/queue.log
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
`QUILL_JOPLIN_NOTEBOOK`, `QUILL_JOPLIN_API_URL`, `QUILL_JOPLIN_BACKUP_DIR`,
`QUILL_JOPLIN_ATTACHMENTS_DIR`, `QUILL_JOPLIN_QUEUE_DIR`,
`QUILL_JOPLIN_QUEUE_BACKOFF` and `QUILL_JOPLIN_QUEUE_MAX_ATTEMPTS`; Quill's QML
side also honours `QUILL_JOPLIN_SYNC_PATH` and `QUILL_JOPLIN_AUTOSYNC` (see
above). `tools/README.md` describes the attachment store override.

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
$S draft discard <id>                      # delete <note>.draft, keep the note
$S create [--folder F] [--title T] [--content-stdin]
$S create --template <id> [--folder F]
$S templates list
$S templates show <id>
$S templates save <id> [--name N] [--description D] [--icon I] [--content-file F]
$S templates delete <id>
$S rename <id> --title "New title"
$S duplicate <id>                          # same folder, "<title> copy" title
$S move <id> --folder "Work/Projects"
$S pin <id>; $S trash <id>; $S restore <id>; $S delete <id>
$S empty-trash
$S versions <id>                          # read-only snapshot listing
$S restore-version <id> <snapshot>         # exact bytes; basename or absolute path
$S folder create "Work/Projects"
$S folder rename "Work/Projects" "Archive"
$S folder delete "Archive" [--force]     # --force moves notes to the root
$S search "prefix query" --limit 50    # prefix + typo-tolerant
$S tags
$S tag-rename old-tag new-tag
$S tag-add <id> <tag> [<tag>...]          # append inline #tags to the body
$S backlinks <id>
$S preview <id>                           # wiki/tag links become quill:// URLs
$S import-omanano
$S index --rebuild
$S attachment save --file PATH | --stdin [--name ALT]
$S attachment list
$S attachment gc [--dry-run]
$S stats
```

For a long-lived backend, `scripts/quill-daemon` starts or reuses one
`quill-store __serve` process on a Unix socket (never inside the data root) and
bridges stdin/stdout to it. Commands, JSON shapes and errors are unchanged, the
index stays warm and current through an inotify watcher, and `--status` /
`--stop` inspect or stop the daemon. `scripts/bench --daemon` times the same
metrics through one persistent socket instead of one process per command.

`write --content-file <path>` is an additive convenience used by the QML
editor, which cannot reliably close a child process's stdin. Files named
`.quill-save-*` are treated as throwaway buffers and removed after reading.
`write --create` lets a restore recreate an explicit mapped id: a missing file
is validated, given its parent folders, newline-normalised to LF and indexed
(no snapshot, because there is no previous content). If the file already
exists, `--create` changes nothing about today's snapshot and newline-preserving
write path.

`read` adds `draft: {content, modified}` only when an adjacent `.draft` exists,
differs from the stored body (newline style aside), and the note is neither
trashed nor too large. `write` removes that draft when its normalised text
equals the bytes just saved; a newer draft is kept. `draft discard <id>`
removes the adjacent draft and returns `{"id": ..., "discarded": true|false}`.
Draft commands are mutations for the `QUILL_E2E` live-root guard.

`tag-add` normalises requested tags the same way as inline tags, ignores
invalid ones and tags already on the note (case-insensitive), caps one call at
20 additions, and returns `{id, tags, content, modified}`. It extends a
trailing tag-only line or adds one blank line plus a new `#tag` line, keeps
the note's newline style, snapshots the previous body, and reindexes the note.

`preview` strips the YAML frontmatter block (its title and tags are already
shown in the UI), then converts wiki links to
`[Alias](quill://note/<id>)` (or `quill://missing/<target>`), and inline tags
to `[#tag](quill://tag/<tag>)`. Fenced code, inline code, ordinary Markdown
links and bare URLs are left untouched.

The index refreshes incrementally by size + mtime, rebuilds automatically on
a schema-version change, and is safe to delete. Search uses FTS5 prefix
matching (`"term"*`) with `snippet()` highlights (`⟪…⟫` markers, rendered bold
by the note list). Exact prefix hits come first; when fewer than 5 exact hits
exist the store retries with typo-tolerant term expansion over the `fts5vocab`
vocabulary, using optimal-string-alignment distance (1 edit up to 5
characters, 2 beyond). Expansions into words that appear in more than 60% of
notes are dropped, and near matches are appended after the exact results.
Those results carry `"fuzzy": true` and the note list prefixes their snippet
with `≈`. The fallback costs nothing when a normal search already has hits.
The library is capped at 2000 listed notes / folders per call and 512 KiB of a
note is indexed.

## Importing OmaNano

Once, from the plugin directory:

```bash
scripts/quill-store import-omanano
```

It copies `~/.local/share/omanano/notes/**/*.md` into `notes/`, keeps the
original filenames and mtimes, carries over pinned ids that exist, and never
overwrites an existing note. OmaNano's files are never moved or modified.

## Testing

`./scripts/test` runs all four suites and exits non-zero if any fails:

1. `node --test tests/js` — the pure modules (formatting, tables, maths, fuzzy
   ranking, URLs, tag suggestions) plus golden HTML files.
2. `python3 -m unittest discover -s tests/store` — the store CLI and the helper
   scripts, against a throwaway `QUILL_DATA_DIR`.
3. `./scripts/qmlcheck` — loads every component in a headless Quickshell so a
   broken attached property or import fails here instead of on the desktop.
4. `./scripts/qmltest` — behaviour cases: each one creates a real component
   (today, the library), drives it, and asserts on what reached the disk.

The behaviour cases exist because loading is not enough. A component can load
cleanly and still be broken at runtime — a variable captured in the wrong scope
once stopped every save from being written while the UI cheerfully said
"Saving…". `tests/qml/library-save.qml` now covers exactly that: a save reaches
the disk, a stale save is refused, the conflict is reported, and "Keep mine"
then wins.

Nothing here touches your notes: every suite runs with a temporary
`QUILL_DATA_DIR` and `QUILL_E2E=1`, and the store refuses to serve the real data
root under that flag.

## Performance

`scripts/bench` builds a disposable library (temp `QUILL_DATA_DIR`, never the
live one) and reports the median of three runs:

```
./scripts/bench --notes 2000 --runs 3
```

Measured on an AMD Ryzen 7 desktop, 2,000 notes / 7.8 MiB of Markdown:

| operation | median |
| --- | --- |
| index rebuild | 4.0 s |
| list | 244 ms |
| search (FTS5, bm25) | 213 ms |
| tags | 191 ms |
| write one note | 142 ms |
| read one note | 139 ms |
| index size | 11.9 MB |

A 16-note library answers list/search/tags in about 140 ms. Those figures
include one process start per command, which is what a detached CLI caller
pays; the library's editor and the detached window keep a `quill-store
__serve` bridge open instead, so their calls skip it — add `--daemon` to the
benchmark to time the same commands over one persistent connection.

## Known limits

- Only the note currently open in the library or a detached window is watched.
  Notes that are not open are picked up by the normal index refresh (open, save,
  or a note action) rather than a filesystem watcher.
- Too-large notes are not watched while Quill shows them read-only; editing one
  externally requires closing and reopening it (or another refresh) to see the
  change.
- The desktop window and the detached note window are normal toplevels;
  Hyprland may tile them unless you add a float rule for `class:org.quickshell`.
- `folder delete --force` moves `.md` notes to the root and deletes other file
  types inside that folder. The UI only offers the non-forced form.
- Preview updates as you type (200 ms after the last keystroke) through
  `preview --content-file`; trashed, read-only and draft-pending notes render
  the saved body instead.
- Crash drafts follow the note's path on move, trash, restore, folder rename
  and folder delete. Two drafts for the same note (a crash and a manual copy)
  are never merged: the destination file wins.
- The library and a detached window can both edit the same note: each save
  names the version its buffer was based on, and a window working from older
  text gets the usual reload-or-keep banner instead of overwriting. Crash
  drafts are still last-writer-wins.
- Markdown rendering is split between Qt's GitHub-dialect
  `Text.MarkdownText` and Quill's RichText converter. Footnotes, definition
  lists and fenced code have their own blocks; raw HTML is a sanitised
  allowlist rather than full HTML. A text block containing inline maths
  switches that whole block to RichText, so its paragraph spacing can differ
  slightly from MarkdownText (see **Maths → Limits**).
- Table formulas are Quill-only display helpers. Joplin shows the literal
  `=…` text, computed values are not exported, and sorting rows does not rewrite
  cell references.
- Settings are stored per data root, not per machine or per window. Session
  restore applies to the library only: a detached window still opens the note
  it was launched with, and a note that was moved or trashed between sessions
  falls back to the first visible row.

## License

MIT — see [LICENSE](LICENSE).
