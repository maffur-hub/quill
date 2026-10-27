# Joplin mirror tools

Reference copies of the Joplin mirror scripts and systemd units that ship with
Quill. The installed copies are what actually runs:

- scripts → `~/.local/bin/`
- units → `~/.config/systemd/user/`

`quill-joplin-sync` is a wrapper around the shared `omanano-joplin-sync` engine
inherited from OmaNano; set `QUILL_JOPLIN_SYNC_TOOL` to use a different engine.
It also implements the save-triggered pending queue (`--notify`, `--flush`,
`--work`); see the plugin README's **Joplin sync** section.

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
