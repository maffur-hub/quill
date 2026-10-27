# Joplin mirror tools

Reference copies of the Joplin mirror scripts and systemd units that ship with
Quill. The installed copies are what actually runs:

- scripts → `~/.local/bin/`
- units → `~/.config/systemd/user/`

`quill-joplin-sync` is a wrapper around the shared `omanano-joplin-sync` engine
inherited from OmaNano; set `QUILL_JOPLIN_SYNC_TOOL` to use a different engine.
It also implements the save-triggered pending queue (`--notify`, `--flush`,
`--work`); see the plugin README's **Joplin sync** section.

## Attachments (resources)

The wrapper always passes `--attachments-dir` (default
`~/.local/share/quill/attachments`, override with
`QUILL_JOPLIN_ATTACHMENTS_DIR`). In that mode the engine uploads each local
file referenced by a note as a Joplin resource and rewrites the Markdown link
to Joplin's `:/<resource id>` form, for example `![shot](:/r1a2b3c)`.

- Uploads happen once per content-addressed filename and are cached in the
  state file, so two notes sharing `attachments/<sha>.<ext>` share one
  resource. Editing a note body reuses the cached ids.
- `attachments/x.png` links are resolved relative to the attachments directory;
  absolute links are only used when they resolve inside it (symlinks that
  escape are skipped with a warning). Files that are missing are warned about
  once and the link is left as text.
- `--dry-run` uploads nothing, writes no state, and reports
  `would upload resource: <name>` in verbose output.
- `--prune` trashes notes only. **Resources are never deleted**: they are
  shared objects and may be referenced by many notes.
- Without `--attachments-dir` (OmaNano's default), behaviour is byte-identical
  to before: local paths stay as text.

State file keys: top-level `resources` maps the attachment filename to
`{"id": <Joplin resource id>, "mime": <mime type>, "size": <bytes>}`, alongside
`folders` and `notes`. Each `notes[<relative path>]` entry also stores a
`body_hash` (sha256 of the body sent to Joplin) so prerendered resource links
are idempotent; entries from older versions are migrated on the next sync.

## Install

```bash
cp tools/omanano-joplin-sync tools/quill-joplin-sync \
   tools/quill-joplin-restore tools/quill-joplin-tags ~/.local/bin/
mkdir -p ~/.config/systemd/user
cp tools/systemd/quill-joplin-sync.service tools/systemd/quill-joplin-sync.timer \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now quill-joplin-sync.timer
```

The timer runs `--flush` every 15 minutes after boot, but that only starts the
detached worker when a save left a pending marker; an idle timer makes no
Joplin API call. Quill calls `--notify` itself after its 2.5 s debounce, so no
extra wiring is needed. Set `QUILL_JOPLIN_AUTOSYNC=0` for the shell session to
disable save-triggered sync. The queue and its log live in
`~/.local/share/quill-joplin/queue/` (override with
`QUILL_JOPLIN_QUEUE_DIR`).

The Joplin API token is read from Joplin's own configuration at run time. It is
never stored in this repository.
