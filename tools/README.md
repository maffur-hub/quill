# Joplin mirror tools

Reference copies of the Joplin mirror scripts and systemd units that ship with
Quill. The installed copies are what actually runs:

- scripts → `~/.local/bin/`
- units → `~/.config/systemd/user/`

`quill-joplin-sync` is a wrapper around the shared `omanano-joplin-sync` engine
inherited from OmaNano; set `QUILL_JOPLIN_SYNC_TOOL` to use a different engine.

## Install

```bash
cp tools/omanano-joplin-sync tools/quill-joplin-sync \
   tools/quill-joplin-restore tools/quill-joplin-tags ~/.local/bin/
cp tools/systemd/quill-joplin-sync.service tools/systemd/quill-joplin-sync.timer \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now quill-joplin-sync.timer
```

The Joplin API token is read from Joplin's own configuration at run time. It is
never stored in this repository.
