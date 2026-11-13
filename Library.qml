import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ImageSizing.js" as ImageSizing
import "MarkdownFormat.js" as MarkdownFormat
import "TableEngine.js" as TableEngine
import "TagSuggest.js" as TagSuggest
import "TagTree.js" as TagTree
import "WritableGuard.js" as WritableGuard

// Quill's library: three panes, a Markdown editor with live highlighting,
// a rendered preview and a single-writer backend queue.
Item {
  id: root

  property string storePath: ""
  property string dataRoot: ""
  // Save-triggered Joplin sync. Empty disables it; a non-empty path is an
  // explicit opt-in by the caller (Panel in production, a harness in tests),
  // so tests can point this at a stub even with QUILL_E2E=1.
  property string joplinSyncPath: ""
  // Production hosts opt in explicitly. Harnesses leave this false so an
  // accidental real data root can never be written to.
  property bool allowRealData: false
  readonly property bool writesAllowed: WritableGuard.writesAllowed(
    dataRoot, allowRealData, Quickshell.env("HOME") || "")
  property bool inWindow: false
  property bool active: true

  signal requestClose()
  signal requestLibraryWindow()

  // ---------------------------------------------------------------- state
  property var notes: []
  property var trashedNotes: []
  property var folders: []
  property var tags: []
  property int trashCount: 0
  property int totalCount: 0
  // Note-link targets for the format bar. Recomputes only when the notes model
  // changes, not on editor keystrokes.
  property var noteTitleList: noteTitles()

  // Quick-switcher title cache. `titles` is much lighter than `list`: just id,
  // title, folder, modified and pinned for every live note. A cached index is
  // reused for a minute; opening the switcher refreshes it in the background
  // so a just-created note appears without a visible wait.
  property var titleIndex: []
  property bool titlesLoading: false
  property double titlesLoadedAt: 0
  // Sidebar saved searches, mirrored from `quill-store searches`. Only a
  // mutation refreshes the list; opening the library never rewrites it.
  property var savedSearches: []
  // Note templates live on disk under <data>/templates, so this is only the
  // menu's cache: adding a file through `templates save` makes it appear
  // without editing QML.
  property var templates: []
  property var templateMenuItems: []

  property string category: "all"
  property string searchText: ""
  property var searchResults: []
  property bool searching: false
  // `selectedId` is the active note: the one the editor shows. `selectedIds`
  // is the multi-selection in selection order; its first entry is always the
  // active note when the active note is part of the selection. `anchor` is the
  // row Shift ranges grow from.
  property string selectedId: ""
  property var selectedIds: []
  property string selectionAnchor: ""
  // The selection snapshot from before the first Shift extension. Keeping it
  // separate is what lets a later Shift shrink the range again instead of
  // unioning every row it ever touched.
  property var selectionRangeBase: []
  property bool selectionRangeActive: false

  property bool loadingList: true
  property bool loadingNote: false
  property bool loaded: false
  property bool tooLarge: false
  property bool suppressDirty: false
  property bool dirty: false
  property int editVersion: 0
  property double loadedModified: 0
  property string saveState: "Ready"
  property string statusText: "Ready"

  // External-editor support. The open note is watched for writes made outside
  // Quill; a clean note reloads silently, a dirty one asks first.
  property bool diskChangePending: false
  property string diskChangeText: ""
  property bool pendingEditorOpen: false
  property string inFlightSaveText: ""
  readonly property string watchPath: (root.selectedNote && root.loaded
    && !root.tooLarge && !root.loadingNote)
    ? root.notePath(root.selectedNote) : ""

  // Crash-draft recovery. While a differing adjacent draft exists, the stored
  // note stays on screen and editing is disabled until Recover or Discard.
  property bool draftPending: false
  property string draftText: ""
  property int draftModified: 0
  property string draftNoteId: ""

  property string mode: "split"
  property bool modeChosen: false
  property var backlinks: []
  property bool backlinksOpen: false
  // Broken note links in the selected note (`[[Missing note]]`). Grouped by
  // target for display; the model keeps per-source counts.
  property var unresolvedLinks: []
  property bool unresolvedOpen: false
  readonly property var unresolvedTargets: unresolvedTargetRows()
  readonly property bool unresolvedShown: unresolvedLinks.length > 0 || unresolvedOpen
  property string previewMarkdown: ""
  // Preview lines start after the frontmatter block; add this to map a
  // preview line back to the note file line.
  property int previewLineOffset: 0
  property bool previewLoading: false
  // Live buffer preview. A pause in typing writes the editor text to a temp
  // file and asks the store to render that, so the pane keeps up without
  // waiting for the 600 ms autosave. The saved-copy path below still runs
  // after loads, saves and external changes.
  property int previewSeq: 0
  // The note and exact buffer text the pane currently shows. Both must match
  // before a debounce is allowed to write and render again.
  property string previewRenderedId: ""
  property string previewRenderedText: ""
  // The temp file the live preview owns, kept so it can be removed when the
  // selection moves or the library goes away.
  property string previewTempFile: ""

  property bool deleteArmed: false
  property string deleteArmId: ""
  property bool folderDeleteArmed: false
  property string folderDeletePath: ""
  // The Undo affordance after a trash. A newer trash replaces the pending
  // batch; the timer expiring simply drops it. Ids are trash-relative, exactly
  // what `restore` takes.
  property var undoTrashIds: []
  property string undoLabel: ""
  property int undoRemaining: 0
  // Bulk tag prompt state. `bulkTagIds` is captured when the modal opens so a
  // selection change behind it can never retarget the write.
  property var bulkTagIds: []
  property int bulkTagCount: 0
  property string bulkTagMode: "add"
  property string bulkTagError: ""
  property string pendingSelectId: ""
  property bool pendingFocusEditor: false
  property bool pendingCaretToEnd: false
  property bool pendingDetach: false
  property var pendingNoteAction: null
  property string renameTargetId: ""
  property string renameNoteText: ""
  // A rename whose dry run found links to rewrite. Holds {id, title, count}.
  property var pendingRename: null
  // Old title shown in the link-update prompt, captured before the rename.
  property string renameLinksSourceTitle: ""
  // Bumped whenever a rename starts so a stale dry-run response can never
  // open the prompt for a note the user has already moved on from.
  property int renameSeq: 0
  // The note the open tag-suggestion popup was built from. Apply must target
  // this id even if the selection moved underneath it.
  property string tagSuggestNoteId: ""
  property string deleteNoteTargetId: ""
  property var pendingDeleteIds: []
  property string deleteNoteTargetTitle: ""
  property int saveSeq: 0
  // Last content written per note id. A save whose bytes equal this is a
  // no-op and must not wake the Joplin sync.
  property var savedTextById: ({})

  // Chat is remembered for this library session only: no config file, and it
  // starts closed every time the shell launches.
  property bool chatOpen: false
  property bool sidebarOpen: true
  property bool noteListOpen: true
  property bool viewMenuOpen: false
  property string chatNotice: ""

  // Table grid state. The grid replaces the preview area while open; the mode
  // it interrupted is restored on close.
  property bool tableOpen: false
  property string tableReturnMode: ""
  property bool tableSavePending: false

  // Export. The popup writes the current editor buffer; it never touches the
  // note file or the Joplin queue.
  property bool exportOpen: false
  property string exportFormat: "markdown"
  property string exportPath: ""
  property string exportError: ""
  property bool exporting: false
  property string exportPendingDest: ""
  property string exportPendingTemp: ""
  property string exportPendingTitle: ""
  property string exportPendingNoteDir: ""
  property string exportPendingFormat: ""
  property string exportCheckDest: ""
  property string exportCheckText: ""
  property string exportCheckFormat: ""
  readonly property string exportScriptPath: Quickshell.env("QUILL_EXPORT_SCRIPT")
    || String(Qt.resolvedUrl("scripts/quill-export-html")).replace(/^file:\/\//, "")
  readonly property string exportPdfScriptPath: Quickshell.env("QUILL_EXPORT_PDF_SCRIPT")
    || String(Qt.resolvedUrl("scripts/quill-export-pdf")).replace(/^file:\/\//, "")
  readonly property var exportPopupRef: exportPopup

  readonly property var visibleNotes: filteredNotes()
  readonly property var selectedNote: findAny(selectedId)
  readonly property int selectedCount: selectionIds().length
  readonly property var folderOptions: buildFolderOptions()
  readonly property string categoryLabel: labelForCategory()
  readonly property int wordCount: countWords(editor.text)
  readonly property Item focusItem: noteList
  readonly property bool editorActive: editor.activeFocus
  readonly property bool searchActive: noteList ? noteList.searchFocused : false
  readonly property bool chatInputActive: chatDock ? chatDock.inputActive : false
  readonly property bool compactHeader: editorPane ? editorPane.width < Style.space(560) : false
  // Layout metrics used by the pane/view tests; harmless to bind from QML.
  readonly property real sidebarPaneWidth: sidebar ? sidebar.width : 0
  readonly property real noteListPaneWidth: noteList ? noteList.width : 0
  readonly property real editorPaneWidth: editorPane ? editorPane.width : 0
  readonly property real editorPaneX: editorPane ? editorPane.x : 0
  readonly property real layoutColumnWidth: layoutColumn ? layoutColumn.width : 0
  readonly property real panesRowWidth: panesArea ? panesArea.width : 0
  readonly property real headerActionsWidth: headerActions ? headerActions.width : 0
  readonly property real headerTitleWidth: headerTitle ? headerTitle.width : 0
  readonly property string pluginDir: {
    var marker = "/scripts/"
    var cut = storePath.lastIndexOf(marker)
    return cut > 0 ? storePath.slice(0, cut) : ""
  }

  // ------------------------------------------------------------ backend queue
  property var jobs: []
  property bool busy: false
  property var activeJob: null

  // A long-lived `quill-daemon` bridge turns each backend call into one JSON
  // line instead of a fresh Python process. If it cannot start, every job
  // falls back to spawning `storePath` exactly as before.
  readonly property string daemonPath: {
    if (root.storePath === "") return ""
    var cut = root.storePath.lastIndexOf("/")
    if (cut <= 0) return "quill-daemon"
    return root.storePath.slice(0, cut) + "/quill-daemon"
  }
  property bool daemonReady: false
  property bool daemonStarting: false
  property bool daemonDisabled: false
  property int daemonFailures: 0
  property int daemonSeq: 0
  property var pendingJob: null

  function enqueue(job) {
    if (!root.writesAllowed && WritableGuard.isMutatingArgs(job.args || [])) {
      var message = WritableGuard.refusalMessage()
      root.saveState = "Read-only"
      root.statusText = message
      if (job.onError) job.onError(message)
      return
    }
    root.jobs.push(job)
    root.pump()
  }

  function pump() {
    if (root.busy || root.jobs.length === 0) return
    if (root.daemonDisabled || root.daemonPath === "" || root.dataRoot === "") {
      // An empty dataRoot would make the bridge fall back to the user's real
      // library, so a harness that never set the property stays on the
      // per-call path where it inherits QUILL_DATA_DIR from the environment.
      root.pumpSpawned(); return
    }
    var job = root.jobs.shift()
    root.activeJob = job
    root.busy = true
    job.daemonId = ++root.daemonSeq
    if (root.daemonReady) {
      root.daemonRequest(job)
    } else {
      root.pendingJob = job
      root.startDaemon()
    }
  }

  // The original per-call path: one backend process per job. Still the only
  // path when the bridge is missing or has failed too often.
  function pumpSpawned() {
    var job = root.jobs.shift()
    root.activeJob = job
    root.busy = true
    process.outputText = ""
    process.errorText = ""
    var command = [root.storePath].concat(job.args || [])
    process.command = command
    process.running = true
  }

  function daemonRequest(job) {
    var payload = { "id": job.daemonId, "args": job.args || [], "stdin": job.stdin || "" }
    try {
      daemon.write(JSON.stringify(payload) + "\n")
    } catch (error) {
      // A failed write means the pipe is gone. Stop the bridge and let its
      // exit path requeue this job; a bridge that was already stopped has no
      // exit left to give, so restore the job here.
      if (daemon.running) daemon.running = false
      else root.handleDaemonExit(-1)
    }
  }

  function startDaemon() {
    if (root.daemonReady || root.daemonStarting) return
    root.daemonStarting = true
    daemon.environment = { "QUILL_DATA_DIR": root.dataRoot }
    daemon.command = [root.daemonPath]
    daemon.running = true
  }

  function handleDaemonLine(raw) {
    var line = String(raw || "").trim()
    if (line === "") return
    var payload = null
    try {
      payload = JSON.parse(line)
    } catch (error) {
      return
    }
    if (!payload) return
    // Any line proves the bridge is alive. Reset the failure count here rather
    // than on start, so a daemon that starts and dies immediately cannot loop
    // forever: three such sessions still disable the bridge.
    root.daemonFailures = 0
    if (payload.event) { root.handleDaemonEvent(payload); return }
    var job = root.activeJob
    // Stale or unknown ids belong to a job that already moved on. Ignore them
    // rather than clearing the job that is running now.
    if (!job || job.daemonId === undefined || Number(job.daemonId) !== Number(payload.id)) return
    root.activeJob = null
    root.busy = false
    if (payload.ok) {
      if (job.onSuccess) job.onSuccess(payload.result || {})
    } else {
      var message = root.parseError(payload.error)
      if (!job.silent) root.statusText = message
      if (job.onError) job.onError(message)
    }
    root.pump()
  }

  function handleDaemonExit(exitCode) {
    root.daemonReady = false
    root.daemonStarting = false
    root.daemonFailures = root.daemonFailures + 1
    if (root.daemonFailures > 2) {
      root.daemonDisabled = true
      root.pendingJob = null
    }
    var job = root.activeJob
    if (job) {
      root.activeJob = null
      root.busy = false
      root.pendingJob = null
      // Rerun the exact same job, in order, through whichever path is left.
      root.jobs.unshift(job)
    }
    root.pump()
  }

  function handleDaemonEvent(payload) {
    var ids = Array.isArray(payload.ids) ? payload.ids : []
    var removed = Array.isArray(payload.removed) ? payload.removed : []
    var touched = ids.concat(removed)
    if (touched.length === 0) return
    // The open note is already covered by noteWatch/FileView; an event that
    // only mentions it needs no index refresh.
    var onlySelected = true
    for (var i = 0; i < touched.length; i++) {
      if (String(touched[i]) !== root.selectedId) { onlySelected = false; break }
    }
    if (onlySelected) return
    if (!root.active || root.dirty || root.loadingNote || root.saveState === "Saving…") return
    daemonEventTimer.restart()
  }

  function parseError(raw) {
    var text = String(raw || "").trim()
    if (!text) return "Quill backend failed"
    try {
      var payload = JSON.parse(text)
      if (payload && payload.error) return String(payload.error)
    } catch (error) { /* plain text error */ }
    return text
  }

  function handleJobExit(exitCode) {
    var job = root.activeJob
    root.activeJob = null
    root.busy = false
    if (!job) { root.pump(); return }
    if (exitCode === 0) {
      var payload = {}
      try {
        payload = JSON.parse(process.outputText || "{}")
      } catch (error) {
        root.statusText = "Could not read the notes index"
        if (job.onError) job.onError(root.statusText)
        root.pump()
        return
      }
      if (job.onSuccess) job.onSuccess(payload)
    } else {
      var message = parseError(process.errorText)
      if (!job.silent) root.statusText = message
      if (job.onError) job.onError(message)
    }
    root.pump()
  }

  // ------------------------------------------------------------ library load
  function refreshAll(statusMessage) {
    enqueue({
      args: ["list"],
      silent: true,
      onSuccess: function(result) {
        root.applyList(result, false)
        // A caller that just destroyed a local condition (for example a tag
        // add) can keep its message instead of the generic note count.
        if (statusMessage) root.statusText = String(statusMessage)
      },
      onError: function(message) { root.loadingList = false; root.statusText = message }
    })
    if (root.category === "trash") refreshTrash()
  }

  function refreshTrash() {
    enqueue({
      args: ["list", "--trashed"],
      silent: true,
      onSuccess: function(result) { root.applyList(result, true) },
      onError: function(message) { root.statusText = message }
    })
  }

  function applyList(result, trashed) {
    root.loadingList = false
    if (trashed) {
      root.trashedNotes = Array.isArray(result.notes) ? result.notes : []
    } else {
      root.notes = Array.isArray(result.notes) ? result.notes : []
      root.folders = Array.isArray(result.folders) ? result.folders : []
      root.tags = Array.isArray(result.tags) ? result.tags : []
      root.totalCount = Number(result.totalCount || root.notes.length)
      if (!root.searchText) root.statusText = root.totalCount + " notes"
    }
    root.trashCount = Number(result.trashCount || 0)
    Qt.callLater(function() { root.ensureSelection() })
  }

  // ------------------------------------------------------- quick switcher
  // A title index is cheaper than a full list and already ordered pinned
  // first, newest next. It is only a cache: selection still goes through the
  // normal note list and store read.
  function loadTitles(force) {
    if (root.titlesLoading) return
    if (!force && root.titlesLoadedAt > 0 && Date.now() - root.titlesLoadedAt < 60000) return
    root.titlesLoading = true
    enqueue({
      // Match the `list` cap: picking a title beyond it would leave the note
      // list unable to select the note the switcher chose.
      args: ["titles", "--limit", "2000"],
      silent: true,
      onSuccess: function(result) {
        root.titleIndex = Array.isArray(result.notes) ? result.notes : []
        root.titlesLoadedAt = Date.now()
        root.titlesLoading = false
      },
      onError: function(message) {
        root.titlesLoading = false
        root.statusText = message
      }
    })
  }

  function openQuickSwitcher() {
    // Open at once with whatever is cached; a cold cache shows the switcher's
    // loading state while the first title list arrives.
    if (root.titleIndex.length === 0) root.loadTitles(true)
    else if (Date.now() - root.titlesLoadedAt > 60000) root.loadTitles(false)
    quickSwitcher.open()
  }

  function openNoteFromSwitcher(id, detached) {
    var noteId = String(id || "")
    if (noteId === "") return
    flushSave()
    // The note may sit outside the current filter or in Trash. Reset the view
    // first so the normal selection machinery can find and show it.
    if (category !== "all") {
      selectCategory("all")
    } else if (searchText !== "") {
      searchText = ""
      searchResults = []
      searching = false
      lastQuery = ""
      if (noteList) noteList.clearSearch()
    }
    if (detached) {
      detachNoteById(noteId)
      return
    }
    pendingSelectId = noteId
    selectNote(noteId)
  }

  // ------------------------------------------------------- saved searches
  function loadSavedSearches() {
    enqueue({
      args: ["searches", "list"],
      silent: true,
      onSuccess: function(result) {
        root.savedSearches = Array.isArray(result.searches) ? result.searches : []
      },
      // A store without saved searches should not interrupt the library; the
      // sidebar simply stays empty.
      onError: function() {}
    })
  }

  // ------------------------------------------------------ tag management
  // Rename and delete are global: the backend rewrites every live note and
  // snapshots each one. The dialog only names the action, and its count comes
  // from the same `tags` listing the sidebar draws.
  function tagNoteCount(tag) {
    var key = String(tag || "").toLowerCase()
    for (var i = 0; i < root.tags.length; i++) {
      if (String(root.tags[i].tag || "").toLowerCase() === key) {
        return Number(root.tags[i].count || 0)
      }
    }
    return 0
  }

  function openTagManager(tag, action) {
    var name = String(tag || "")
    if (name === "" || !tagManager) return
    if (!root.writesAllowed) {
      root.statusText = WritableGuard.refusalMessage()
      return
    }
    var count = root.tagNoteCount(name)
    if (String(action) === "delete") tagManager.openDelete(name, count)
    else tagManager.openRename(name, count)
  }

  function applyTagAction(action, tag, next) {
    var name = String(tag || "")
    if (name === "") return
    if (String(action) === "delete") {
      flushSave()
      enqueue({
        args: ["tag-delete", name],
        silent: true,
        onSuccess: function(result) {
          var updated = Number(result.updated || 0)
          root.statusText = "Deleted #" + name + " from " + updated
            + (updated === 1 ? " note" : " notes")
          if (root.category === "tag:" + name) root.category = "all"
          root.refreshAll(root.statusText)
        },
        onError: function(message) { root.statusText = message }
      })
      return
    }
    var target = String(next || "").replace(/^#+/, "").trim()
    if (target === "" || target === name) return
    flushSave()
    enqueue({
      args: ["tag-rename", name, target],
      silent: true,
      onSuccess: function(result) {
        var updated = Number(result.updated || 0)
        var applied = String(result.tag || target)
        var verb = result.merged ? "Merged #" + name + " into #" + applied
          : "Renamed #" + name + " to #" + applied
        root.statusText = verb + " in " + updated + (updated === 1 ? " note" : " notes")
        if (root.category === "tag:" + name) root.category = "tag:" + applied
        // The watcher refreshes the open buffer; a rename can also move the
        // selected note out of the subtree that was being shown.
        root.refreshAll(root.statusText)
      },
      onError: function(message) { root.statusText = message }
    })
  }

  // ---------------------------------------------------------- templates
  function loadTemplates() {
    enqueue({
      args: ["templates", "list"],
      silent: true,
      onSuccess: function(result) {
        root.templates = Array.isArray(result.templates) ? result.templates : []
        root.rebuildTemplateMenu()
      },
      // An older store may not know `templates`; the menu then keeps only the
      // blank-note entry instead of interrupting the library.
      onError: function() {}
    })
  }

  function rebuildTemplateMenu() {
    if (!newNoteTemplateMenu) return
    for (var i = 0; i < templateMenuItems.length; i++) {
      newNoteTemplateMenu.removeItem(templateMenuItems[i])
    }
    templateMenuItems = []
    for (var t = 0; t < root.templates.length; t++) {
      var entry = root.templates[t]
      var label = String(entry.name || entry.id || "")
      if (label === "") continue
      var icon = String(entry.icon || "")
      var item = templateMenuItemComponent.createObject(null, {
        "text": icon === "" ? label : icon + "  " + label,
        "templateId": String(entry.id || ""),
        "templateDescription": String(entry.description || "")
      })
      if (!item) continue
      // Insert before the trailing "Manage templates…" entry so the menu keeps
      // its fixed head and foot regardless of how many files exist.
      newNoteTemplateMenu.insertItem(2 + templateMenuItems.length, item)
      templateMenuItems.push(item)
    }
  }

  function openTemplateManager() {
    if (templateManager) templateManager.open()
  }

  function saveCurrentSearch() {
    var query = String(root.searchText || "").trim()
    if (query === "") return
    enqueue({
      args: ["searches", "add", query],
      silent: true,
      onSuccess: function(result) {
        root.savedSearches = Array.isArray(result.searches) ? result.searches : root.savedSearches
        root.statusText = "Search saved"
        root.loadSavedSearches()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function removeSavedSearch(query) {
    var value = String(query || "")
    if (value === "") return
    enqueue({
      args: ["searches", "remove", value],
      silent: true,
      onSuccess: function(result) {
        root.savedSearches = Array.isArray(result.searches) ? result.searches : root.savedSearches
        // Removing the active search deliberately leaves searchText and its
        // results alone: the user can keep reading what they were looking at.
        root.loadSavedSearches()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function runSavedSearch(query) {
    var value = String(query || "")
    if (value === "") return
    flushSave()
    searchText = value
    searching = true
    // Bypass the debounce, and clear the same-query guard so re-running a
    // saved search always refreshes the result list.
    lastQuery = ""
    runSearch()
    // Mirroring the query into the field restarts the debounce timer; this
    // search already ran, so cancel that duplicate pass.
    searchTimer.stop()
  }

  // ------------------------------------------------------------- categories
  function labelForCategory() {
    if (category === "all") return "All notes"
    if (category === "pinned") return "Pinned"
    if (category === "recent") return "Recent"
    if (category === "trash") return "Trash"
    if (category.indexOf("folder:") === 0) {
      var folder = category.slice(7)
      return folder === "" ? "Inbox" : folder
    }
    if (category.indexOf("tag:") === 0) return "#" + category.slice(4)
    if (category.indexOf("tagtree:") === 0) {
      var prefix = category.slice(8)
      return prefix === "" ? "#" : "#" + prefix + "/…"
    }
    return "Notes"
  }

  function filteredNotes() {
    if (searchText.trim() !== "") return searchResults
    var source = category === "trash" ? trashedNotes : notes
    if (category === "all" || category === "trash") return source
    var now = Date.now()
    var output = []
    for (var i = 0; i < source.length; i++) {
      var note = source[i]
      var include = false
      if (category === "pinned") include = !!note.pinned
      else if (category === "recent") include = now - Number(note.modified || 0) < 7 * 86400000
      else if (category.indexOf("folder:") === 0) include = String(note.folder || "") === category.slice(7)
      else if (category.indexOf("tag:") === 0) {
        var wanted = category.slice(4).toLowerCase()
        var noteTags = note.tags || []
        for (var t = 0; t < noteTags.length; t++) {
          if (String(noteTags[t]).toLowerCase() === wanted) { include = true; break }
        }
      } else if (category.indexOf("tagtree:") === 0) {
        // A parent tag selects its whole subtree; matching is case-insensitive
        // so `#Project/App` groups under `#project` in the tree.
        var prefix = category.slice(8).toLowerCase()
        var tags = note.tags || []
        for (var u = 0; u < tags.length; u++) {
          if (TagTree.prefixMatches(String(tags[u]).toLowerCase(), prefix)) { include = true; break }
        }
      }
      if (include) output.push(note)
    }
    return output
  }

  // Note titles for the note-link popup: skip trashed/broken entries, dedupe
  // case-insensitively (a note list can contain two "Untitled" notes) and sort
  // the way a person expects.
  function noteTitles() {
    var output = []
    var seen = {}
    for (var i = 0; i < notes.length; i++) {
      var note = notes[i]
      if (!note || note.trashed || note.missing || note.invalid) continue
      var title = String(note.title === undefined || note.title === null ? "" : note.title)
        .replace(/[\r\n]+/g, " ").trim()
      if (title === "") continue
      var key = title.toLowerCase()
      if (seen[key]) continue
      seen[key] = true
      output.push(title)
    }
    output.sort(function(a, b) {
      var left = a.toLowerCase()
      var right = b.toLowerCase()
      if (left < right) return -1
      if (left > right) return 1
      return a < b ? -1 : a > b ? 1 : 0
    })
    return output
  }

  function findAny(id) {
    var key = String(id || "")
    if (!key) return null
    for (var i = 0; i < notes.length; i++) if (String(notes[i].id) === key) return notes[i]
    for (var j = 0; j < trashedNotes.length; j++) if (String(trashedNotes[j].id) === key) return trashedNotes[j]
    for (var k = 0; k < searchResults.length; k++) if (String(searchResults[k].id) === key) return searchResults[k]
    return null
  }

  // Pending selections are only valid in the current view. A trashed or
  // filtered-out id must never be selected again by a late refresh.
  function hasVisibleId(id) {
    var key = String(id || "")
    if (key === "") return false
    var list = filteredNotes()
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === key) return true
    }
    return false
  }

  // ------------------------------------------------------------ selection
  // A selection is always kept in sync with `filteredNotes()`: ids that leave
  // the current view (trashed, moved, filtered out) are pruned by
  // ensureSelection() rather than lingering as invisible state.
  function isMultiSelected(id) {
    var key = String(id || "")
    if (key === "") return false
    for (var i = 0; i < selectedIds.length; i++) {
      if (String(selectedIds[i]) === key) return true
    }
    return false
  }

  function selectionIds() {
    if (selectedIds.length > 0) return selectedIds.slice()
    return selectedId !== "" ? [selectedId] : []
  }

  function resetSelection(id) {
    var key = String(id || "")
    var next = key === "" ? [] : [key]
    var unchanged = next.length === selectedIds.length
      && (next.length === 0 || String(selectedIds[0]) === key)
    if (!unchanged) selectedIds = next
    selectionAnchor = key
    selectionRangeBase = []
    selectionRangeActive = false
  }

  function clearSelection() {
    if (selectedIds.length > 0) selectedIds = []
    selectionAnchor = ""
    selectionRangeBase = []
    selectionRangeActive = false
  }

  // A plain click, keyboard move or switcher choice asks for exactly one
  // selected note; the active row follows it.
  function collapseSelection() {
    root.resetSelection(root.selectedId)
  }

  function toggleSelection(id) {
    var key = String(id || "")
    if (key === "") return
    var next = selectedIds.slice()
    var index = next.indexOf(key)
    if (index >= 0) {
      next.splice(index, 1)
      root.selectedIds = next
      root.selectionRangeBase = []
      root.selectionRangeActive = false
      if (key === root.selectionAnchor) {
        root.selectionAnchor = next.length > 0 ? String(next[0]) : ""
      }
      if (next.length === 0) {
        // Removing the last selected row leaves the editor where it is; the
        // active note is still the single implicit selection.
        root.selectionAnchor = ""
        return
      }
      // The active note follows the remaining selection instead of pointing
      // at a row the user just removed.
      if (key === root.selectedId) {
        var follow = String(next[next.length - 1])
        var followIndex = next.indexOf(follow)
        if (followIndex > 0) {
          var reordered = next.slice()
          reordered.splice(followIndex, 1)
          reordered.unshift(follow)
          root.selectedIds = reordered
        }
        root.activateNote(follow)
      }
      return
    }
    // Prepend rather than append: bulk commands treat ids[0] as the primary
    // note, so the active note must stay first.
    next.unshift(key)
    root.selectedIds = next
    root.selectionAnchor = key
    root.selectionRangeBase = []
    root.selectionRangeActive = false
    root.activateNote(key)
  }

  function extendSelectionTo(id) {
    var key = String(id || "")
    if (key === "") return
    var list = root.filteredNotes()
    var anchor = root.selectionAnchor !== "" ? root.selectionAnchor : root.selectedId
    var from = -1
    var to = -1
    for (var i = 0; i < list.length; i++) {
      var noteId = String(list[i].id)
      if (noteId === anchor) from = i
      if (noteId === key) to = i
    }
    if (to < 0) return
    if (from < 0) {
      // The anchor fell out of this view (for example after a search); start
      // a fresh range from the row the user just Shift-clicked.
      root.resetSelection(key)
      root.activateNote(key)
      return
    }
    if (!root.selectionRangeActive) {
      root.selectionRangeBase = root.selectedIds.slice()
      root.selectionRangeActive = true
    }
    var base = root.selectionRangeBase
    var included = {}
    var output = []
    for (var b = 0; b < base.length; b++) {
      var baseId = String(base[b])
      if (baseId === "" || included[baseId]) continue
      included[baseId] = true
      output.push(baseId)
    }
    var start = Math.min(from, to)
    var end = Math.max(from, to)
    for (var r = start; r <= end; r++) {
      var rangeId = String(list[r].id)
      if (included[rangeId]) continue
      included[rangeId] = true
      output.push(rangeId)
    }
    // The endpoint becomes the active note and the primary id for a bulk
    // command; keep it first while preserving everybody else's order.
    var endpoint = output.indexOf(key)
    if (endpoint > 0) {
      output.splice(endpoint, 1)
      output.unshift(key)
    }
    root.selectedIds = output
    root.activateNote(key)
  }

  function selectAllVisible() {
    var list = root.filteredNotes()
    if (list.length === 0) return
    var ids = []
    for (var i = 0; i < list.length; i++) ids.push(String(list[i].id))
    var activeIndex = ids.indexOf(String(root.selectedId))
    if (activeIndex > 0) {
      ids.splice(activeIndex, 1)
      ids.unshift(String(root.selectedId))
    }
    root.selectionAnchor = activeIndex >= 0 ? String(root.selectedId) : ids[0]
    root.selectionRangeBase = []
    root.selectionRangeActive = false
    root.selectedIds = ids
    if (root.selectedId === "" || activeIndex < 0) root.activateNote(ids[0])
  }

  function selectCategory(nextCategory) {
    if (category === nextCategory) return
    flushSave()
    category = String(nextCategory)
    searchText = ""
    searchResults = []
    searching = false
    deleteArmed = false
    root.clearSelection()
    if (noteList) noteList.clearSearch()
    if (category === "trash") refreshTrash()
    Qt.callLater(function() { root.ensureSelection() })
  }

  function ensureSelection() {
    if (pendingSelectId) {
      // A freshly created/moved note may not be in the list snapshot that is
      // already in flight. Wait for the refresh that contains it instead of
      // falling back to another note and stealing its load flags.
      if (!root.hasVisibleId(pendingSelectId)) {
        if (!pendingSelectTimer.running) pendingSelectTimer.restart()
        return
      }
      pendingSelectTimer.stop()
      var wanted = pendingSelectId
      pendingSelectId = ""
      // A bulk move/restore puts several ids in selectedIds before the
      // refreshed list arrives; do not collapse that selection here.
      if (root.selectedIds.length > 1 && root.isMultiSelected(wanted)) root.activateNote(wanted)
      else root.selectNote(wanted)
      return
    }
    var list = filteredNotes()
    // Never keep a selection entry for a row that is no longer in this view.
    // In particular a trashed id can never be resurrected by stale selection
    // state after a refresh.
    var visible = {}
    for (var v = 0; v < list.length; v++) visible[String(list[v].id)] = true
    var kept = []
    for (var s = 0; s < selectedIds.length; s++) {
      if (visible[String(selectedIds[s])]) kept.push(String(selectedIds[s]))
    }
    if (kept.length !== selectedIds.length) {
      selectedIds = kept
      if (root.selectionAnchor !== "" && kept.indexOf(root.selectionAnchor) < 0) {
        root.selectionAnchor = kept.length > 0
          ? String(kept[0]) : String(root.selectedId || "")
      }
      root.selectionRangeBase = []
      root.selectionRangeActive = false
    }
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === selectedId) return
    }
    selectNote(list.length > 0 ? String(list[0].id) : "")
  }

  // Change the active note without touching the multi-selection. Callers that
  // mean "just this one" use selectNote() below.
  function activateNote(id) {
    var next = String(id || "")
    deleteArmed = false
    pendingDetach = false
    if (next === selectedId && (loaded || loadingNote)) return
    if (tableOpen) closeTable(false)
    // Keep the outgoing buffer safe even if the store write fails or the
    // process goes away mid-save.
    draftTimer.stop()
    root.writeDraft()
    flushSave()
    // Leaving the note abandons the banner but never the draft file: the next
    // open offers it again. Reset here so the prompt can never target the
    // previously selected note while the new one loads.
    draftPending = false
    draftText = ""
    draftModified = 0
    draftNoteId = ""
    diskChangePending = false
    diskChangeText = ""
    pendingEditorOpen = false
    inFlightSaveText = ""
    // Remove the outgoing note's buffer preview before the selection moves,
    // so any render still in flight can never land on the new note.
    root.clearPreviewTemp()
    selectedId = next
    scheduleChatContext()
    if (!next) {
      clearEditor()
      return
    }
    loadNote()
  }

  function selectNote(id) {
    root.resetSelection(id)
    root.activateNote(id)
  }

  function clearEditor() {
    if (tableOpen) closeTable(false)
    draftTimer.stop()
    previewDebounce.stop()
    root.clearPreviewTemp()
    draftPending = false
    draftText = ""
    draftModified = 0
    draftNoteId = ""
    diskChangePending = false
    diskChangeText = ""
    pendingEditorOpen = false
    inFlightSaveText = ""
    suppressDirty = true
    editor.text = ""
    editor.resetFormatHistory()
    editor.cursorPosition = 0
    suppressDirty = false
    loaded = false
    tooLarge = false
    loadingNote = false
    dirty = false
    loadedModified = 0
    previewMarkdown = ""
    previewLineOffset = 0
    backlinks = []
    backlinksOpen = false
    unresolvedLinks = []
    unresolvedOpen = false
    saveState = "Ready"
  }

  function loadNote() {
    var note = selectedNote
    if (!note) { clearEditor(); return }
    if (note.tooLarge) {
      tooLarge = true
      loaded = false
      loadingNote = false
      previewMarkdown = ""
      statusText = "This note is too large to edit safely"
      return
    }
    var requestedId = selectedId
    var requestedTrashed = !!note.trashed
    // Capture the new-note intent for *this* load. A read that was already in
    // flight when a note was created must not steal the capture focus/caret
    // meant for the new note.
    var caretAtEnd = root.pendingCaretToEnd
    var focusAfterLoad = root.pendingFocusEditor
    root.pendingCaretToEnd = false
    root.pendingFocusEditor = false
    loadingNote = true
    tooLarge = false
    // A reload (for example after a version restore) must not keep the old
    // buffer's preview or let its in-flight render land.
    previewDebounce.stop()
    root.invalidatePreview()
    // Drop the previous note's preview so its line numbers can never target a
    // line in the newly loaded note while the fresh preview is in flight.
    previewMarkdown = ""
    previewLineOffset = 0
    var args = ["read", requestedId]
    if (requestedTrashed) args.push("--trashed")
    enqueue({
      args: args,
      silent: true,
      onSuccess: function(result) {
        if (requestedId !== root.selectedId) return
        root.suppressDirty = true
        editor.text = result.tooLarge ? "" : String(result.content || "")
        editor.resetFormatHistory()
        editor.cursorPosition = caretAtEnd ? editor.text.length : 0
        root.suppressDirty = false
        root.loadingNote = false
        root.tooLarge = !!result.tooLarge
        root.loaded = !result.tooLarge
        root.loadedModified = Number(result.modified || 0)
        root.savedTextById[requestedId] = root.tooLarge ? "" : String(result.content || "")
        root.dirty = false
        root.editVersion = 0
        root.backlinksOpen = false
        root.scheduleChatContext()
        root.saveState = root.loaded
          ? "Saved " + Qt.formatTime(new Date(root.loadedModified), "HH:mm")
          : "Read only"
        root.statusText = root.tooLarge
          ? "Note is larger than " + Math.ceil(Number(result.maxBytes || 1048576) / 1048576) + " MiB"
          : root.categoryLabel
        if (result.draft && root.writesAllowed) {
          root.draftPending = true
          root.draftText = String(result.draft.content || "")
          root.draftModified = Number(result.draft.modified || 0)
          root.draftNoteId = requestedId
          root.saveState = "Draft found"
          root.statusText = "Unsaved draft found"
        } else {
          root.draftPending = false
          root.draftText = ""
          root.draftModified = 0
          root.draftNoteId = ""
        }
        if (root.loaded) {
          root.requestPreview()
          root.requestBacklinks()
          root.requestUnresolved()
          if (focusAfterLoad) {
            Qt.callLater(function() {
              editor.forceActiveFocus()
              // Some TextEdit focus paths reset the caret; assert the
              // end-of-document position once more after focus lands.
              if (caretAtEnd) editor.cursorPosition = editor.text.length
            })
          }
        }
      },
      onError: function(message) {
        if (requestedId !== root.selectedId) return
        root.loadingNote = false
        root.loaded = false
        root.statusText = message
      }
    })
  }

  // ------------------------------------------------------------ draft saving
  // Adjacent to the note and invisible to rglob("*.md"). Store ids already
  // include their folder, so the draft path is the id plus a suffix.
  function draftPath(id) {
    return root.dataRoot + "/notes/" + String(id || "") + ".draft"
  }

  function writeDraft() {
    if (!root.writesAllowed || !root.loaded || root.tooLarge || root.loadingNote) return
    if (!root.selectedNote || root.selectedNote.trashed) return
    if (root.draftPending || !root.dirty || root.selectedId === "") return
    draftWriter.enqueue(root.draftPath(root.selectedId), String(editor.text))
  }

  function recoverDraft() {
    if (!root.draftPending || root.selectedId !== root.draftNoteId) return
    draftTimer.stop()
    var text = root.draftText
    root.suppressDirty = true
    editor.text = text
    editor.resetFormatHistory()
    editor.cursorPosition = text.length
    root.suppressDirty = false
    root.draftPending = false
    root.draftText = ""
    root.draftModified = 0
    root.draftNoteId = ""
    root.dirty = true
    root.editVersion += 1
    root.saveState = "Unsaved"
    root.statusText = "Draft recovered"
    saveTimer.stop()
    root.flushSave()
  }

  function discardDraft() {
    if (!root.draftPending || root.selectedId !== root.draftNoteId) return
    var id = root.draftNoteId
    if (id === "") return
    root.enqueue({
      args: ["draft", "discard", id],
      silent: true,
      onSuccess: function(result) {
        if (root.selectedId !== id) return
        root.draftPending = false
        root.draftText = ""
        root.draftModified = 0
        root.draftNoteId = ""
        root.saveState = "Ready"
        root.statusText = "Draft discarded"
      },
      onError: function(message) {
        root.statusText = "Could not discard draft: " + message
      }
    })
  }

  // ---------------------------------------------------------------- saving
  Component {
    id: saveFileComponent

    FileView {
      id: saveView
      property string targetNoteId: ""
      property int targetVersion: 0
      property string targetText: ""
      atomicWrites: true
      blockAllReads: true
      printErrors: false
      onSaved: root.bufferSaved(saveView)
      onSaveFailed: root.bufferFailed(saveView)
    }
  }

  // Watches the open note for writes from outside Quill: the external editor,
  // Git, Syncthing, another Quill window. watchChanges follows atomic renames
  // but does not re-read, so reload explicitly and handle fresh text on load.
  FileView {
    id: noteWatch
    path: root.watchPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handleExternalContent(String(text()))
  }

  // One-shot export writer. Used for the Markdown destination and for the
  // temporary source file that feeds the HTML renderer.
  Component {
    id: exportFileComponent

    FileView {
      id: exportView
      property string targetPath: ""
      property string targetText: ""
      property string targetMode: ""
      property string tempPath: ""
      atomicWrites: true
      blockAllReads: true
      printErrors: false
      onSaved: root.exportFileSaved(exportView)
      onSaveFailed: function(error) { root.exportFileFailed(exportView, error) }
    }
  }

  // Run a note action only after the selected buffer has been written. A
  // backend command that reads the file (duplicate, rename, move) must not
  // race the asynchronous temp-file save that flushSave() starts.
  function afterSave(id, action) {
    var note = findAny(id)
    if (!note || note.trashed) return
    if (id === selectedId && dirty && loaded && !tooLarge) {
      if (!writesAllowed) {
        statusText = WritableGuard.refusalMessage()
        return
      }
      if (diskChangePending) {
        statusText = "Note changed on disk — choose Reload or Keep mine"
        return
      }
      pendingNoteAction = { id: String(id), run: action }
      flushSave()
      return
    }
    action()
  }

  // A save that could not even be prepared (for example createObject returned
  // null) must not leave a queued note action or a tag apply locked forever.
  function savePrepareFailed(message) {
    saveState = "Save failed"
    statusText = message
    pendingEditorOpen = false
    if (pendingNoteAction
        && String(pendingNoteAction.id) === String(selectedId)) {
      pendingNoteAction = null
    }
    if (tagSuggestPopup && tagSuggestPopup.applying) {
      tagSuggestPopup.showError(message)
    }
  }

  function flushSave() {
    saveTimer.stop()
    if (!root.writesAllowed) {
      saveState = "Read-only"
      statusText = WritableGuard.refusalMessage()
      return
    }
    if (tableOpen && tableEditor) tableEditor.flushWrite()
    if (dirty && diskChangePending) {
      // Never overwrite the external text that the banner is asking about.
      statusText = "Note changed on disk — choose Reload or Keep mine"
      return
    }
    if (!dirty || !loaded || tooLarge || !selectedNote || selectedNote.trashed) return
    saveSeq += 1
    var path = dataRoot + "/.quill-save-" + saveSeq + "-" + Date.now() + ".md"
    var view = saveFileComponent.createObject(root, { path: path })
    if (!view) {
      savePrepareFailed("Could not prepare a save")
      return
    }
    var text = String(editor.text)
    inFlightSaveText = text
    view.targetNoteId = selectedId
    view.targetVersion = editVersion
    view.targetText = text
    saveState = "Saving…"
    view.setText(text)
  }

  function bufferSaved(view) {
    var noteId = view.targetNoteId
    var version = view.targetVersion
    var contentPath = view.path
    var savedText = String(view.targetText || "")
    view.destroy()
    enqueue({
      args: ["write", noteId, "--content-file", contentPath],
      silent: true,
      noteId: noteId,
      version: version,
      onSuccess: function(result) { root.afterWrite(noteId, version, result, savedText) },
      onError: function(message) {
        if (root.inFlightSaveText === savedText) root.inFlightSaveText = ""
        root.pendingEditorOpen = false
        if (root.pendingNoteAction
            && String(root.pendingNoteAction.id) === String(noteId)) {
          root.pendingNoteAction = null
        }
        if (noteId === root.selectedId) {
          root.saveState = "Save failed"
          root.dirty = true
        }
        root.statusText = message
        if (tagSuggestPopup && tagSuggestPopup.applying) tagSuggestPopup.showError(message)
      }
    })
  }

  function bufferFailed(view) {
    var noteId = view.targetNoteId
    var failedText = String(view.targetText || "")
    view.destroy()
    if (inFlightSaveText === failedText) inFlightSaveText = ""
    pendingEditorOpen = false
    if (pendingNoteAction && String(pendingNoteAction.id) === String(noteId)) {
      pendingNoteAction = null
    }
    if (noteId === root.selectedId) {
      saveState = "Save failed"
      dirty = true
      statusText = "Could not write the note"
      pendingDetach = false
    }
    if (tagSuggestPopup && tagSuggestPopup.applying) {
      tagSuggestPopup.showError("Could not write the note")
    }
  }

  function afterWrite(noteId, version, result, savedText) {
    // Only the matching save clears the in-flight text: a newer edit may have
    // started another save while this one was running.
    if (inFlightSaveText === savedText) inFlightSaveText = ""
    // A write that did not change the stored bytes is a no-op. Only a real
    // change wakes the Joplin sync, and only after the write succeeded.
    var previousText = root.savedTextById[noteId]
    var changed = previousText === undefined || savedText !== previousText
    root.savedTextById[noteId] = savedText

    if (noteId === selectedId) {
      loadedModified = Number(result.modified || Date.now())
      if (editVersion === version) {
        // The store removed the equal adjacent draft. Stop a debounce that
        // would recreate it, and forget queued writes for this path. A newer
        // edit keeps its draft: only this exact saved version cleans up.
        draftTimer.stop()
        draftWriter.drop(root.draftPath(noteId))
        dirty = false
        saveState = "Saved " + Qt.formatTime(new Date(loadedModified), "HH:mm")
        if (root.tableSavePending) {
          root.tableSavePending = false
          statusText = "Table saved"
        }
      } else {
        dirty = true
        saveState = "Unsaved"
        saveTimer.restart()
      }
      requestPreview()
      requestBacklinks()
      requestUnresolved()
      root.scheduleChatContext()
    }
    refreshTimer.restart()
    if (changed) notifyJoplinSync()
    if (pendingNoteAction && String(pendingNoteAction.id) === String(noteId)
        && (noteId !== selectedId || !dirty)) {
      var pending = pendingNoteAction
      pendingNoteAction = null
      if (pending.run) pending.run()
    }
    if (pendingDetach && !dirty && noteId === selectedId) launchDetachedWindow()
    // An editor launch requested while dirty waits for a successful save of
    // the current buffer. A newer edit leaves the flag set for its own save.
    if (pendingEditorOpen && noteId === selectedId && !dirty) {
      pendingEditorOpen = false
      launchExternalEditor()
    }
  }

  // Debounced: a burst of autosaves produces one --notify call.
  function notifyJoplinSync() {
    if (!writesAllowed || joplinSyncPath === "") return
    joplinNotifyTimer.restart()
  }

  // ------------------------------------------------------- detached window
  function detachSelectedNote() {
    if (!selectedNote) return
    if (selectedNote.trashed) {
      statusText = "Restore this note before opening it in a window"
      return
    }
    if (selectedNote.tooLarge) {
      statusText = "This note is too large to detach safely"
      return
    }
    if (!pluginDir) {
      statusText = "Could not locate the Quill plugin"
      return
    }
    pendingDetach = true
    if (dirty) {
      flushSave()
      return
    }
    launchDetachedWindow()
  }

  function launchDetachedNote(id, title) {
    pendingDetach = false
    detachedProcess.command = [
      pluginDir + "/scripts/quill-window",
      String(id),
      String(title || "Note"),
      dataRoot
    ]
    detachedProcess.running = true
    statusText = "Opened “" + String(title || "note") + "” in a detached window"
  }

  function launchDetachedWindow() {
    var note = selectedNote
    if (!note) { pendingDetach = false; return }
    launchDetachedNote(note.id, note.title || "Note")
  }

  // Open an id from the quick switcher without assuming it is selected yet.
  // The title comes from the note list when loaded, otherwise from the title
  // index the switcher already has.
  function detachNoteById(id) {
    var noteId = String(id || "")
    if (noteId === "") return
    if (!pluginDir) {
      statusText = "Could not locate the Quill plugin"
      return
    }
    var title = ""
    var note = findAny(noteId)
    if (note && note.title) title = String(note.title)
    if (title === "") {
      for (var i = 0; i < titleIndex.length; i++) {
        if (String(titleIndex[i].id) === noteId) {
          title = String(titleIndex[i].title || "")
          break
        }
      }
    }
    if (title === "") title = "Note"
    // A dirty current note must reach disk before the window reads it; the
    // existing save-then-launch path runs launchDetachedWindow on success.
    if (noteId === selectedId && dirty) {
      pendingDetach = true
      // openNoteFromSwitcher already flushed; don't queue the same bytes twice.
      if (inFlightSaveText === "") flushSave()
      return
    }
    launchDetachedNote(noteId, title)
  }

  // ------------------------------------------------------- external editor
  // Open the current note in Omarchy's configured editor. Pending local edits
  // are flushed first, so the editor never starts from stale bytes.
  function openInEditor() {
    if (!root.selectedNote) {
      root.statusText = "Select a note first"
      return
    }
    if (root.selectedNote.trashed) {
      root.statusText = "Restore this note before opening it in an editor"
      return
    }
    if (!root.writesAllowed) {
      root.statusText = WritableGuard.refusalMessage()
      return
    }
    if (root.loadingNote) {
      root.statusText = "Wait for the note to finish loading"
      return
    }
    if (root.diskChangePending) {
      root.statusText = "Note changed on disk — choose Reload or Keep mine"
      return
    }
    if (root.draftPending) {
      root.statusText = "Recover or discard the draft first"
      return
    }
    // Too-large notes are read-only in Quill but can still be opened in an
    // external editor; they are deliberately not watched.
    if (root.tooLarge) {
      root.launchExternalEditor()
      return
    }
    if (root.dirty || root.saveState === "Saving…") {
      root.pendingEditorOpen = true
      if (root.dirty) root.flushSave()
      return
    }
    root.launchExternalEditor()
  }

  function launchExternalEditor() {
    var note = root.selectedNote
    if (!note) return
    var path = root.notePath(note)
    if (!path) return
    Quickshell.execDetached(["omarchy-launch-editor", path])
    root.statusText = "Opened in external editor"
  }

  // A watched FileView tells us the file changed, but not what it now says.
  // Reload explicitly and feed the fresh text through the conflict check.
  function handleExternalContent(content) {
    var value = String(content === undefined || content === null ? "" : content)
    if (noteWatch.path !== root.watchPath) return
    if (!root.loaded || root.loadingNote || root.tooLarge
      || root.draftPending || root.selectedId === "") return
    if (value === String(editor.text)) {
      // The file already holds what we have. A conflict captured for an older
      // disk state is stale now, so clear it instead of offering a reload that
      // would resurrect text the file no longer contains.
      if (root.diskChangePending) {
        root.diskChangePending = false
        root.diskChangeText = ""
        root.statusText = "Your version is on disk"
      }
      return
    }
    if (root.inFlightSaveText !== "" && value === root.inFlightSaveText) {
      if (root.diskChangePending) {
        root.diskChangePending = false
        root.diskChangeText = ""
        root.statusText = "Your version is on disk"
      }
      return
    }
    var known = root.savedTextById[root.selectedId]
    if (known !== undefined && value === known) {
      // Stale notification for content we already have (for example the
      // rename half of our own atomic save).
      root.diskChangePending = false
      root.diskChangeText = ""
      return
    }
    if (root.dirty || root.saveState === "Saving…") {
      root.diskChangePending = true
      root.diskChangeText = value
      root.statusText = "Note changed on disk"
      return
    }
    root.applyExternalContent(value)
  }

  function applyExternalContent(content, modified, message) {
    if (!root.loaded || root.loadingNote || root.tooLarge || root.selectedId === "") return
    var id = root.selectedId
    var value = String(content === undefined || content === null ? "" : content)
    var caret = editor.cursorPosition
    var scrollY = editorScroll.contentY
    root.suppressDirty = true
    editor.text = value
    editor.resetFormatHistory()
    editor.cursorPosition = Math.min(caret, value.length)
    root.suppressDirty = false
    root.savedTextById[id] = value
    root.dirty = false
    root.editVersion = 0
    root.diskChangePending = false
    root.diskChangeText = ""
    root.loadedModified = Number(modified || Date.now())
    // A clean external reload is a saved state: there is nothing to write.
    root.saveState = "Saved " + Qt.formatTime(new Date(root.loadedModified), "HH:mm")
    root.statusText = message || "Reloaded from disk"
    saveTimer.stop()
    draftTimer.stop()
    draftWriter.drop(root.draftPath(id))
    root.requestPreview()
    root.requestBacklinks()
    root.requestUnresolved()
    root.scheduleChatContext()
    refreshTimer.restart()
    root.notifyJoplinSync()
    Qt.callLater(function() {
      var maxY = Math.max(0, editorScroll.contentHeight - editorScroll.height)
      editorScroll.contentY = Math.min(scrollY, maxY)
      editor.cursorPosition = Math.min(caret, String(editor.text).length)
    })
  }

  function reloadFromDisk() {
    if (!root.diskChangePending) return
    root.applyExternalContent(root.diskChangeText)
  }

  // ------------------------------------------------------ tag suggestions
  function tagSuggestKnownTags() {
    var output = []
    for (var i = 0; i < root.tags.length; i++) {
      var row = root.tags[i]
      output.push(row && typeof row === "object" ? row.tag : row)
    }
    return output
  }

  function tagSuggestAvailable() {
    return !!root.selectedNote
      && !root.selectedNote.trashed
      && root.loaded
      && !root.loadingNote
      && !root.tooLarge
      && !root.draftPending
      && !root.diskChangePending
      && root.selectedId !== ""
      && root.writesAllowed
  }

  function openTagSuggest() {
    if (!root.tagSuggestAvailable()) return
    // Never replace an in-flight apply with a fresh popup state.
    if (tagSuggestPopup.applying) return
    var id = String(root.selectedId)
    var note = root.selectedNote
    var noteTags = note.tags ? note.tags : []
    var suggestions = TagSuggest.suggest(
      String(note.title || ""),
      String(editor.text || ""),
      noteTags,
      root.tagSuggestKnownTags())
    root.tagSuggestNoteId = id
    tagSuggestPopup.openFor(suggestions, noteTags)
  }

  function clearTagSuggestTarget() {
    root.tagSuggestNoteId = ""
  }

  // A backend tag write can hang (for example a stuck lock). Release the modal
  // after 20s so Escape/Cancel work again. A late result is still protected by
  // applySuggestedTags()'s captured editVersion: newer typing is never
  // replaced, and a clean unchanged buffer may accept the result harmlessly.
  function tagApplyTimedOut() {
    if (!tagSuggestPopup || !tagSuggestPopup.applying) return
    root.clearTagSuggestTarget()
    var message = "Adding tags timed out — try again"
    root.statusText = message
    tagSuggestPopup.showError(message)
  }

  function applySuggestedTags(tags) {
    var id = root.tagSuggestNoteId
    // A window shortcut (Ctrl+N, Ctrl+Delete, refresh removing the note) can
    // change the selection while the modal popup is open. Suggestions built
    // for note A must never be written to note B.
    if (id === "" || id !== String(root.selectedId)) {
      tagSuggestPopup.showError("The note changed — reopen Add tags")
      root.statusText = "The note changed — reopen Add tags"
      root.clearTagSuggestTarget()
      return
    }
    if (!root.tagSuggestAvailable()) {
      tagSuggestPopup.showError("This note cannot be edited right now")
      return
    }
    var note = root.selectedNote
    var seen = {}
    if (note.tags) {
      for (var t = 0; t < note.tags.length; t++) {
        seen[TagSuggest.normalizeTag(note.tags[t])] = true
      }
    }
    var clean = []
    for (var i = 0; i < tags.length; i++) {
      var tag = TagSuggest.normalizeTag(tags[i])
      if (!tag || seen[tag]) continue
      seen[tag] = true
      clean.push(tag)
    }
    if (clean.length === 0) {
      tagSuggestPopup.showError("Select or type at least one new tag")
      return
    }
    // Capture the buffer version at the moment the user presses Apply. If it
    // moves while tag-add runs, newer typing must not be replaced.
    var applyVersion = root.editVersion
    tagSuggestPopup.applying = true
    tagSuggestPopup.errorText = ""
    // Any dirty buffer is written first: tag-add must edit the saved note, not
    // race the asynchronous temp-file save.
    root.afterSave(id, function() {
      // afterSave() can still run after the user switched notes; abort before
      // issuing the backend command for an id that is no longer selected.
      if (String(root.selectedId) !== id) {
        tagSuggestPopup.showError("The note changed — reopen Add tags")
        root.statusText = "The note changed — reopen Add tags"
        root.clearTagSuggestTarget()
        return
      }
      root.enqueue({
        args: ["tag-add", id].concat(clean),
        silent: true,
        onSuccess: function(result) {
          var keptNewerEdits = false
          if (root.selectedId === id) {
            // editVersion also resets on a safe external reload, so treat the
            // buffer as unchanged when a clean editor already holds exactly
            // the tag-add result (the file watcher may have applied it first).
            var versionChanged = root.editVersion !== applyVersion
            var alreadyApplied = !root.dirty
              && String(editor.text) === String(result.content)
            if (!versionChanged || alreadyApplied) {
              root.applyExternalContent(result.content, result.modified, "Tags added")
            } else {
              // Tags landed on disk; keep the newer buffer instead of
              // clobbering it with the stale tag-add content.
              keptNewerEdits = true
            }
          }
          root.clearTagSuggestTarget()
          tagSuggestPopup.finishSuccess()
          root.statusText = keptNewerEdits
            ? "Tags added — newer edits kept" : "Tags added"
          root.refreshAll(root.statusText)
        },
        onError: function(message) {
          // Keep the popup open so the selection is not lost; the note itself
          // was not touched by a failed command.
          tagSuggestPopup.showError(message)
          root.statusText = message
        }
      })
    })
  }

  function keepDiskChange() {
    if (!root.diskChangePending) return
    var id = root.selectedId
    var diskText = root.diskChangeText
    root.diskChangePending = false
    root.diskChangeText = ""
    // Remember what is on disk so the watcher does not re-raise the conflict.
    if (id !== "") root.savedTextById[id] = diskText
    root.statusText = "Keeping your version"
    if (root.dirty) saveTimer.restart()
  }

  function onEditorEdited() {
    if (suppressDirty || !loaded || tooLarge || loadingNote) return
    if (selectedNote && selectedNote.trashed) return
    dirty = true
    editVersion += 1
    saveState = "Unsaved"
    saveTimer.restart()
    draftTimer.restart()
    // Any render already in flight now shows older bytes; invalidate it and
    // ask for a fresh one once typing pauses. Autosave and draft debouncing
    // keep their own timers.
    previewSeq += 1
    if (writesAllowed) {
      previewDebounce.restart()
    } else {
      // No live path can pick the flag back up on a read-only note.
      previewLoading = false
    }
  }

  function countWords(value) {
    var text = String(value || "").trim()
    if (!text) return 0
    var matches = text.match(/\S+/g)
    return matches ? matches.length : 0
  }

  // -------------------------------------------------------------- preview
  // A stable temp path per note: the renderer reads a copy of the buffer, so
  // it must never live inside the notes root. The id is sanitised because it
  // can contain folder separators, and only this file name is derived from it.
  function previewTempPath() {
    var id = String(root.selectedId || "")
    var safe = id.replace(/[^A-Za-z0-9._-]/g, "-")
    if (safe === "") safe = "note"
    var dir = String(Quickshell.env("TMPDIR") || "/tmp")
    return dir.replace(/\/+$/, "") + "/quill-preview-" + safe + ".md"
  }

  // Forget which buffer text the pane shows and orphan any render already in
  // flight. Used when the text changes without a keystroke or the note goes
  // away; the stale response drops itself when previewSeq no longer matches.
  function invalidatePreview() {
    previewSeq += 1
    previewRenderedId = ""
    previewRenderedText = ""
    // Reset the flag too: the response this invalidation orphans will not
    // clear it, and the next owner (a load or a read-only state) owns it now.
    previewLoading = false
  }

  function clearPreviewTemp() {
    var path = root.previewTempFile
    previewTempFile = ""
    previewWriter.pendingId = ""
    previewWriter.pendingText = ""
    previewWriter.writtenPath = ""
    previewWriter.writtenText = ""
    root.invalidatePreview()
    // A write may still be running; its onSaved notices the id mismatch,
    // removes the path it just wrote and drops the writer's cache afterwards.
    if (path !== "") Quickshell.execDetached(["rm", "-f", path])
    if (!previewWriter.busy) root.dropPreviewCache()
  }

  // FileView skips a write whose bytes match what it already holds, which
  // would leave the writer marked busy with no onSaved to finish it. Blanking
  // the path drops that cache; it is only done outside a save signal.
  function dropPreviewCache() {
    if (previewWriter.busy) return
    previewWriter.path = ""
  }

  function startPreviewWrite(text) {
    var path = root.previewTempPath()
    previewTempFile = path
    if (path === previewWriter.writtenPath && text === previewWriter.writtenText) {
      // The file already holds this buffer; re-writing it would be skipped.
      root.renderPreviewFile(path, root.selectedId, text)
      return
    }
    previewWriter.busy = true
    previewWriter.path = path
    previewWriter.targetId = root.selectedId
    previewWriter.targetText = text
    // An empty buffer would be skipped by the same cache check, and a lone
    // newline renders identically (same lineOffset, no visible markdown).
    previewWriter.setText(text === "" ? "\n" : text)
  }

  // One write at a time: a newer buffer supersedes a queued one instead of
  // racing the file the renderer is about to read.
  function pumpPreviewWrite() {
    if (previewWriter.busy) return
    var text = String(previewWriter.pendingText || "")
    var id = previewWriter.pendingId
    previewWriter.pendingText = ""
    previewWriter.pendingId = ""
    if (id === "" || id !== root.selectedId) return
    if (!root.writesAllowed || !root.loaded || root.tooLarge || root.loadingNote) return
    if (text !== String(editor.text)) return
    if (id === root.previewRenderedId && text === root.previewRenderedText) return
    root.startPreviewWrite(text)
  }

  // Debounce entry point. Only notes that can actually be written get the live
  // path; read-only and oversized notes keep the saved-copy preview.
  function requestBufferPreview() {
    if (!root.writesAllowed || !root.loaded || root.tooLarge || root.loadingNote) return
    if (!root.selectedNote || root.selectedNote.trashed) return
    var text = String(editor.text)
    if (root.selectedId === root.previewRenderedId && text === root.previewRenderedText) return
    if (previewWriter.busy) {
      previewWriter.pendingId = root.selectedId
      previewWriter.pendingText = text
      return
    }
    root.startPreviewWrite(text)
  }

  // Enqueue the render for a temp file that holds `text`. Shared by the write
  // completion and the already-written path so the staleness guards match.
  function renderPreviewFile(path, id, text) {
    if (id !== root.selectedId) return
    if (id === root.previewRenderedId && text === root.previewRenderedText) return
    var seq = previewSeq
    previewLoading = true
    enqueue({
      args: ["preview", "--content-file", path],
      silent: true,
      onSuccess: function(result) {
        if (seq !== root.previewSeq || id !== root.selectedId) return
        root.previewMarkdown = String(result.markdown || "")
        root.previewLineOffset = Number(result.lineOffset || 0)
        root.previewRenderedId = id
        root.previewRenderedText = text
        root.previewLoading = false
      },
      onError: function(message) {
        if (seq !== root.previewSeq || id !== root.selectedId) return
        // Keep the last good render: a failed buffer render is retried by the
        // next edit instead of blanking the pane mid-sentence.
        root.previewLoading = false
        root.statusText = message
      }
    })
  }

  function previewFileSaved() {
    var path = previewWriter.path
    var id = previewWriter.targetId
    var text = String(previewWriter.targetText || "")
    previewWriter.busy = false
    if (id !== root.selectedId) {
      // The selection moved while this write was in flight.
      Quickshell.execDetached(["rm", "-f", path])
      Qt.callLater(function() { root.dropPreviewCache() })
      Qt.callLater(function() { root.pumpPreviewWrite() })
      return
    }
    previewWriter.writtenPath = path
    previewWriter.writtenText = text
    if (text !== String(editor.text)) {
      // A newer keystroke landed while the file was being written; its own
      // debounce owns the next render.
      Qt.callLater(function() { root.pumpPreviewWrite() })
      return
    }
    root.renderPreviewFile(path, id, text)
    // Path changes and the next write must not happen inside FileView's saved
    // signal, or setPath would wait on (and re-emit) the finished operation.
    Qt.callLater(function() { root.pumpPreviewWrite() })
  }

  function previewFileFailed(message) {
    previewWriter.busy = false
    previewWriter.writtenPath = ""
    previewWriter.writtenText = ""
    previewWriter.pendingId = ""
    previewWriter.pendingText = ""
    // The cache holds the failed bytes; drop it so a retry is not a no-op.
    Qt.callLater(function() { root.dropPreviewCache() })
    root.statusText = String(message || "Could not prepare the live preview")
  }

  // Saved-copy preview: resolves wiki links against the index, so loads,
  // saves and external reloads keep using it. Text the live buffer already
  // renders is skipped rather than fetched twice.
  function requestPreview() {
    if (!selectedId || !loaded) { previewMarkdown = ""; previewLineOffset = 0; return }
    var requestedId = selectedId
    // A newer edit is already on its way to the live preview; rendering the
    // bytes that were just saved would only move the pane backwards.
    if (root.dirty && root.writesAllowed) return
    if (previewRenderedId === requestedId
        && previewRenderedText === savedTextById[requestedId]) return
    previewSeq += 1
    previewRenderedId = ""
    previewRenderedText = ""
    var seq = previewSeq
    previewLoading = true
    enqueue({
      args: ["preview", requestedId],
      silent: true,
      onSuccess: function(result) {
        if (seq !== root.previewSeq || requestedId !== root.selectedId) return
        root.previewMarkdown = String(result.markdown || "")
        root.previewLineOffset = Number(result.lineOffset || 0)
        root.previewLoading = false
      },
      onError: function(message) {
        if (seq !== root.previewSeq || requestedId !== root.selectedId) return
        root.previewLoading = false
        root.previewMarkdown = ""
        root.previewLineOffset = 0
        root.statusText = message
      }
    })
  }

  // --------------------------------------------------- image size editing
  // Replace one line of the editor in place so the caret/selection elsewhere
  // keeps its position and the normal dirty/autosave path runs.
  function replaceEditorLine(index, replacement) {
    var lines = String(editor.text).split("\n")
    if (index < 0 || index >= lines.length) return false
    if (lines[index] === replacement) return false
    var start = 0
    for (var i = 0; i < index; i++) start += lines[i].length + 1
    editor.remove(start, start + lines[index].length)
    editor.insert(start, replacement)
    return true
  }

  function setImageWidth(line, width) {
    if (!loaded || tooLarge || !selectedNote || selectedNote.trashed) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = ImageSizing.setWidth(lines[index], width)
    if (updated === null) return
    replaceEditorLine(index, updated)
  }

  function clearImageSize(line) {
    if (!loaded || tooLarge || !selectedNote || selectedNote.trashed) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = ImageSizing.clearSize(lines[index])
    if (updated === null) return
    replaceEditorLine(index, updated)
  }

  // --------------------------------------------------- task checkboxes
  // Flip the box on one line. The caret is left alone; the normal dirty and
  // autosave path saves the note and syncs it to Joplin as usual.
  function toggleTaskAt(line) {
    if (!loaded || tooLarge || !selectedNote || selectedNote.trashed) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = MarkdownFormat.toggleTaskLine(lines[index])
    if (updated === null || updated === lines[index]) return
    replaceEditorLine(index, updated)
  }

  // --------------------------------------------------- table grid editing
  function openTableAt(startLine, endLine) {
    if (!loaded || tooLarge || !selectedNote || selectedNote.trashed) {
      statusText = "This note is read-only"
      return
    }
    var from = Math.round(Number(startLine))
    var to = Math.round(Number(endLine))
    if (!isFinite(from) || !isFinite(to)) return

    var lines = String(editor.text).split("\n")
    var tables = TableEngine.findTables(lines)
    var found = null
    for (var i = 0; i < tables.length; i++) {
      if (tables[i].startLine === from) { found = tables[i]; break }
    }
    if (!found) {
      // The preview is rendered from the last save, so an unsaved edit above
      // the table can shift its line number. Ask for one more click instead
      // of opening the wrong range.
      statusText = "Table is not saved yet — click it again in a moment"
      flushSave()
      return
    }
    if (tableOpen) closeTable(false)
    tableReturnMode = mode
    if (mode === "edit") mode = "preview"
    tableOpen = true
    tableEditor.openRange(found.startLine, found.endLine)
    statusText = "Editing table " + (found.rows.length) + "×" + found.header.length
  }

  function applyTableWrite(newLines) {
    if (!tableOpen || !tableEditor) return
    if (!selectedNote || selectedNote.trashed) return
    var oldLines = tableEditor.pendingOldLines || []
    var start = tableEditor.startLine
    if (start < 0 || oldLines.length === 0) return
    if (!newLines || typeof newLines.length !== "number") return

    var rawLines = String(editor.text).split("\n")
    var current = []
    for (var i = 0; i < oldLines.length; i++) {
      var line = rawLines[start + i]
      current.push(line === undefined ? "" : line.replace(/\r$/, ""))
    }
    if (!TableEngine.sameLines(current, oldLines)) {
      // The note moved or changed between the grid's check and this splice.
      // Let the grid reconcile once (relocate, adopt, or raise the banner),
      // then retry against its current region rather than stale indices.
      if (!tableEditor.reconcileSource()) {
        if (!tableEditor.externalChange) {
          tableEditor.reportConflict("Table changed in the note — choose Use note or Overwrite")
        }
        return
      }
      start = tableEditor.startLine
      oldLines = tableEditor.pendingOldLines && tableEditor.pendingOldLines.length > 0
        ? tableEditor.pendingOldLines : (tableEditor.lastSnapshot || [])
      rawLines = String(editor.text).split("\n")
      current = []
      for (var k = 0; k < oldLines.length; k++) {
        var retryLine = rawLines[start + k]
        current.push(retryLine === undefined ? "" : retryLine.replace(/\r$/, ""))
      }
      if (start < 0 || oldLines.length === 0
        || !TableEngine.sameLines(current, oldLines)) {
        if (!tableEditor.externalChange) {
          tableEditor.reportConflict("Table changed in the note — choose Use note or Overwrite")
        }
        return
      }
    }

    var carriage = String(editor.text).indexOf("\r\n") >= 0 ? "\r" : ""
    var replacement = []
    for (var j = 0; j < newLines.length; j++) {
      replacement.push(String(newLines[j]).replace(/\r$/, "") + carriage)
    }
    var output = rawLines.slice(0, start)
      .concat(replacement, rawLines.slice(start + oldLines.length))
    var nextText = output.join("\n")
    if (nextText === String(editor.text)) {
      tableEditor.commitSucceeded = true
      tableSavePending = false
      statusText = "Table saved"
      return
    }

    var caret = editor.cursorPosition
    editor.text = nextText
    editor.resetFormatHistory()
    editor.cursorPosition = Math.min(caret, nextText.length)
    tableEditor.commitSucceeded = true
    tableSavePending = true
    statusText = "Table updated"
  }

  function closeTable(restoreMode) {
    if (!tableOpen) return
    if (tableEditor) tableEditor.flushWrite()
    var target = restoreMode ? tableReturnMode : ""
    tableOpen = false
    tableReturnMode = ""
    if (target !== "") mode = target
    if (root.active) {
      Qt.callLater(function() {
        if (!root.tableOpen && editor) editor.forceActiveFocus()
      })
    }
  }

  // Ctrl+T: insert a 3×3 table (header + three body rows) at the caret and
  // open it in the grid. Blank lines around the table keep GFM happy.
  function insertTableTemplate() {
    if (!loaded || tooLarge || !selectedNote || selectedNote.trashed) {
      statusText = "This note is read-only"
      return
    }
    var template = [
      "| Column 1 | Column 2 | Column 3 |",
      "| :--- | :--- | :--- |",
      "|  |  |  |",
      "|  |  |  |",
      "|  |  |  |"
    ]
    var text = String(editor.text)
    var eol = text.indexOf("\r\n") >= 0 ? "\r\n" : "\n"
    var position = Math.max(0, Math.min(editor.cursorPosition, text.length))
    // Never insert a table before YAML frontmatter: that would turn the
    // metadata into body text. A caret inside the block moves below it.
    if (/^---\r?\n/.test(text)) {
      var closing = text.indexOf("\n---", 3)
      if (closing >= 0) {
        var bodyStart = text.indexOf("\n", closing + 1)
        bodyStart = bodyStart < 0 ? text.length : bodyStart + 1
        if (position < bodyStart) position = bodyStart
      }
    }
    var before = text.slice(0, position)
    var after = text.slice(position)

    var leading = ""
    if (position > 0 && text.charAt(position - 1) !== "\n") leading += eol
    var prior = before + leading
    var priorLines = prior.split("\n")
    var previous = priorLines.length >= 2 ? priorLines[priorLines.length - 2] : ""
    if (previous !== undefined && previous.trim() !== "") leading += eol

    var trailing = eol
    if (after.length > 0 && after.charAt(0) !== "\n") trailing += eol

    var block = leading + template.join(eol) + trailing
    var startLine = (before + leading).split("\n").length - 1
    editor.insert(position, block)
    editor.cursorPosition = position + block.length
    openTableAt(startLine, startLine + template.length - 1)
  }

  function requestBacklinks() {
    if (!selectedId) { backlinks = []; return }
    var requestedId = selectedId
    enqueue({
      args: ["backlinks", requestedId],
      silent: true,
      onSuccess: function(result) {
        if (requestedId !== root.selectedId) return
        root.backlinks = Array.isArray(result.backlinks) ? result.backlinks : []
      }
    })
  }

  // Broken `[[note]]` links in the open note. The store scans every source,
  // so an empty result after creating a note is the authoritative "resolved".
  function requestUnresolved() {
    if (!selectedId) { unresolvedLinks = []; return }
    var requestedId = selectedId
    enqueue({
      args: ["unresolved", "--id", requestedId],
      silent: true,
      onSuccess: function(result) {
        if (requestedId !== root.selectedId) return
        root.unresolvedLinks = Array.isArray(result.unresolved) ? result.unresolved : []
        if (root.unresolvedLinks.length === 0) root.unresolvedOpen = false
      }
    })
  }

  // The backend reports one row per (source, target). The pane only needs one
  // row per target, so merge case-insensitively and sum the occurrence counts.
  function unresolvedTargetRows() {
    var rows = []
    var index = {}
    var list = Array.isArray(root.unresolvedLinks) ? root.unresolvedLinks : []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var target = String(row.target === undefined || row.target === null ? "" : row.target).trim()
      if (target === "") continue
      var key = target.toLowerCase()
      if (index[key] === undefined) {
        index[key] = rows.length
        rows.push({ target: target, count: Number(row.count || 0) })
      } else {
        rows[index[key]].count += Number(row.count || 0)
      }
    }
    return rows
  }

  // Local Markdown links are stored as absolute paths (`[spec](/home/me/spec.pdf)`).
  // Qt.openUrlExternally needs a URL, not a bare path, so local paths get a
  // file:// prefix (already-percent-encoded hrefs stay encoded). Anything with
  // a scheme is passed through untouched.
  function externalLinkUrl(link) {
    var value = String(link === undefined || link === null ? "" : link).trim()
    if (value === "") return ""
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return value
    if (value.slice(0, 2) === "~/") {
      value = (Quickshell.env("HOME") || "") + value.slice(1)
    }
    if (value.charAt(0) === "/") return "file://" + value
    return value
  }

  function openLink(link) {
    var value = String(link || "")
    if (value.indexOf("quill://note/") === 0) {
      var noteId = decodeURIComponent(value.slice("quill://note/".length))
      selectNote(noteId)
    } else if (value.indexOf("quill://tag/") === 0) {
      var tag = decodeURIComponent(value.slice("quill://tag/".length))
      selectCategory("tag:" + tag)
    } else if (value.indexOf("quill://missing/") === 0) {
      statusText = "No note matches “" + decodeURIComponent(value.slice("quill://missing/".length)) + "”"
    } else {
      var target = root.externalLinkUrl(value)
      if (target !== "") Qt.openUrlExternally(target)
    }
  }

  // -------------------------------------------------------------- actions
  function buildFolderOptions() {
    var options = [{ value: "", label: "Inbox" }]
    for (var i = 0; i < folders.length; i++) options.push({ value: String(folders[i]), label: String(folders[i]) })
    return options
  }

  function afterCreate(result, folder, focusEditor) {
    root.pendingSelectId = String(result.id || "")
    root.pendingFocusEditor = !!focusEditor
    root.pendingCaretToEnd = true
    root.clearSelection()
    if (folder) root.category = "folder:" + folder
    else if (root.category === "trash" || root.category === "pinned" || root.category === "recent" || root.category.indexOf("tag:") === 0 || root.category.indexOf("tagtree:") === 0) root.category = "all"
    root.searchText = ""
    root.searchResults = []
    root.searching = false
    if (noteList) noteList.clearSearch()
    root.refreshAll()
    root.statusText = "Created a note"
  }

  function createNote(inCurrentFolder, focusEditor) {
    flushSave()
    var folder = ""
    if (inCurrentFolder && category.indexOf("folder:") === 0) folder = category.slice(7)
    enqueue({
      args: ["create", "--folder", folder],
      silent: true,
      onSuccess: function(result) { root.afterCreate(result, folder, focusEditor) },
      onError: function(message) { root.statusText = message }
    })
  }

  function createNoteFromTemplate(templateId, inCurrentFolder) {
    flushSave()
    var folder = ""
    if (inCurrentFolder && category.indexOf("folder:") === 0) folder = category.slice(7)
    enqueue({
      args: ["create", "--folder", folder, "--template", String(templateId)],
      silent: true,
      onSuccess: function(result) { root.afterCreate(result, folder, false) },
      onError: function(message) { root.statusText = message }
    })
  }

  function capture() {
    createNote(false, true)
  }

  function openLibraryWindow() {
    flushSave()
    requestLibraryWindow()
  }

  // ------------------------------------------------------------- layout
  function toggleSidebar() {
    sidebarOpen = !sidebarOpen
  }

  function toggleNoteList() {
    noteListOpen = !noteListOpen
  }

  // Editor and Preview can never both be off. Turning one off leaves the
  // other visible; turning one on from the opposite single-pane mode restores
  // split.
  function toggleEditor() {
    setMode(mode === "preview" ? "split" : "preview")
  }

  function togglePreview() {
    setMode(mode === "edit" ? "split" : "edit")
  }

  function resetLayout() {
    sidebarOpen = true
    noteListOpen = true
    setMode("split")
    chatOpen = false
  }

  function focusSidebar() {
    if (!sidebarOpen) {
      sidebarOpen = true
      Qt.callLater(function() {
        if (sidebar) sidebar.forceActiveFocus()
      })
      return
    }
    sidebar.forceActiveFocus()
  }

  function focusNotes() {
    if (!noteListOpen) {
      noteListOpen = true
      Qt.callLater(function() {
        if (noteList) noteList.forceActiveFocus()
      })
      return
    }
    noteList.forceActiveFocus()
  }

  function focusSearch() {
    if (!noteListOpen) {
      noteListOpen = true
      Qt.callLater(function() {
        if (noteList) noteList.focusSearch()
      })
      return
    }
    noteList.focusSearch()
  }

  // Focus search and show the filter grammar without replacing what is
  // already typed. runSearch() passes the query through unchanged.
  function focusAdvancedSearch() {
    focusSearch()
    statusText = 'Filters: tag: folder: before: after: "phrase" -exclude'
  }

  function openViewMenu() {
    viewMenuOpen = true
  }

  function closeViewMenu() {
    viewMenuOpen = false
  }

  // ---------------------------------------------------------------- chat
  function showChatNotice(message) {
    chatNotice = String(message || "")
    chatNoticeTimer.restart()
  }

  function toggleChat() {
    if (chatOpen) {
      chatOpen = false
      return
    }
    if (root.width < Style.space(980)) {
      showChatNotice("Widen the window to use chat")
      return
    }
    chatOpen = true
    Qt.callLater(function() {
      if (root.chatOpen && chatDock) chatDock.initialise()
    })
    pushChatContext(true)
  }

  function notePath(note) {
    if (!note || !dataRoot) return ""
    var id = String(note.id || "")
    if (id === "") return ""
    // Store ids already include their folder ("Work/plan.md"). Only prepend a
    // folder for an id that does not carry it, so nested notes never double up.
    var folder = String(note.folder || "")
    if (folder !== "" && id.indexOf(folder + "/") !== 0 && id.indexOf("/") < 0) {
      return dataRoot + "/notes/" + folder + "/" + id
    }
    return dataRoot + "/notes/" + id
  }

  // ---------------------------------------------------------------- export
  function safeExportName(title) {
    var name = String(title === undefined || title === null ? "" : title)
      .replace(/[\/\\:*?"<>|\u0000-\u001f\u007f]/g, "-")
      .trim()
    name = name.replace(/[. ]+$/, "")
    return name === "" ? "Untitled" : name
  }

  function defaultExportPath(title, format) {
    var home = Quickshell.env("HOME") || ""
    var ext = format === "html" ? ".html" : (format === "pdf" ? ".pdf" : ".md")
    return home + "/" + safeExportName(title) + ext
  }

  function openExport() {
    if (root.exporting) return
    if (!root.selectedNote || !root.loaded || root.tooLarge || root.loadingNote) return
    if (root.draftPending) {
      root.exportError = "Recover or discard the draft first"
      root.statusText = root.exportError
      return
    }
    root.exportError = ""
    root.exportFormat = "markdown"
    root.exportPath = root.defaultExportPath(root.selectedNote.title, "markdown")
    root.exportOpen = true
    if (exportPopup) exportPopup.open()
    Qt.callLater(function() {
      if (root.exportOpen && exportPathField) {
        exportPathField.text = root.exportPath
        exportPathField.forceActiveFocus()
        exportPathField.cursorPosition = exportPathField.text.length
      }
    })
  }

  function closeExport() {
    if (exportPopup) exportPopup.close()
    root.exportOpen = false
  }

  function setExportFormat(format) {
    if (root.exporting) return
    var next = format === "html" || format === "pdf" ? format : "markdown"
    if (root.exportFormat === next) return
    var ext = next === "html" ? ".html" : (next === "pdf" ? ".pdf" : ".md")
    var path = String(root.exportPath || "")
    // Only rewrite a known export extension; a bare name or some other suffix
    // is left exactly as the user typed it.
    if (/\.(md|html?|pdf)$/i.test(path)) path = path.replace(/\.(md|html?|pdf)$/i, ext)
    root.exportFormat = next
    root.exportPath = path
    root.exportError = ""
    if (exportPathField) exportPathField.text = path
  }

  function normaliseExportPath() {
    var value = String(root.exportPath || "").trim()
    if (value === "") return { ok: false, error: "Choose an export path" }
    var home = Quickshell.env("HOME") || ""
    if (value === "~") value = home
    else if (value.indexOf("~/") === 0) value = home + value.slice(1)
    if (value.charAt(0) !== "/") return { ok: false, error: "Choose an absolute path" }
    if (value.charAt(value.length - 1) === "/") return { ok: false, error: "Choose a file name, not a folder" }
    return { ok: true, path: value }
  }

  // Store ids already include their folder. Prepending notePath()'s folder
  // again would double-count nested directories.
  function exportNoteDir() {
    var base = root.dataRoot + "/notes"
    var id = String(root.selectedId || "")
    var slash = id.lastIndexOf("/")
    if (slash > 0) base += "/" + id.slice(0, slash)
    return base
  }

  function performExport() {
    if (root.exporting) return
    if (!root.selectedNote || !root.loaded || root.tooLarge || root.loadingNote) {
      root.exportError = "No note is ready to export"
      return
    }
    if (root.draftPending) {
      root.exportError = "Recover or discard the draft first"
      root.statusText = root.exportError
      return
    }
    var target = root.normaliseExportPath()
    if (!target.ok) {
      root.exportError = target.error
      return
    }
    root.exportError = ""
    root.exporting = true
    var text = String(editor.text)
    // FileView creates missing parent directories on save, so check first:
    // an export must never silently invent a folder tree.
    var slash = target.path.lastIndexOf("/")
    var parent = slash <= 0 ? "/" : target.path.slice(0, slash)
    root.exportCheckDest = target.path
    root.exportCheckText = text
    root.exportCheckFormat = root.exportFormat
    exportValidateProcess.command = ["test", "-d", parent]
    exportValidateProcess.running = true
  }

  function afterExportPathCheck(exitCode) {
    var dest = root.exportCheckDest
    var text = root.exportCheckText
    var format = root.exportCheckFormat
    root.exportCheckDest = ""
    root.exportCheckText = ""
    root.exportCheckFormat = ""
    if (exitCode !== 0) {
      root.exporting = false
      root.exportError = "Export folder does not exist"
      root.statusText = root.exportError
      return
    }
    if (format === "pdf") root.exportPdf(dest, text)
    else if (format === "html") root.exportHtml(dest, text)
    else root.exportMarkdown(dest, text)
  }

  function exportMarkdown(dest, text) {
    var view = exportFileComponent.createObject(root, { path: dest })
    if (!view) {
      root.exporting = false
      root.exportError = "Could not prepare the export"
      return
    }
    view.targetPath = dest
    view.targetText = text
    view.targetMode = "markdown"
    view.setText(text)
  }

  function exportHtml(dest, text) {
    root.exportRich(dest, text, "html")
  }

  function exportPdf(dest, text) {
    root.exportRich(dest, text, "pdf")
  }

  // Shared body for the script-backed exports: both HTML and PDF render the
  // same temporary Markdown source, and the pending format picks the script.
  function exportRich(dest, text, format) {
    var temp = root.dataRoot + "/.quill-export-" + Date.now() + ".md"
    var view = exportFileComponent.createObject(root, { path: temp })
    if (!view) {
      root.exporting = false
      root.exportError = "Could not prepare the export"
      return
    }
    view.targetPath = dest
    view.targetText = text
    view.targetMode = "html-source"
    view.tempPath = temp
    root.exportPendingFormat = format
    root.exportPendingTitle = root.selectedNote ? String(root.selectedNote.title || "Untitled") : "Untitled"
    root.exportPendingNoteDir = root.exportNoteDir()
    view.setText(text)
  }

  function exportFileSaved(view) {
    var mode = String(view.targetMode || "")
    var dest = String(view.targetPath || "")
    var temp = String(view.tempPath || "")
    view.destroy()
    if (mode === "markdown") {
      root.finishExport(true, dest)
      return
    }
    root.runHtmlExporter(dest, temp)
  }

  function exportFileFailed(view, error) {
    var mode = String(view.targetMode || "")
    var temp = String(view.tempPath || "")
    view.destroy()
    if (temp !== "") root.cleanupExportTemp(temp)
    var message = String(error === undefined ? "" : error).trim()
    if (message === "") message = "Could not write the export file"
    root.finishExport(false, mode === "html-source"
      ? "Could not write the export source: " + message
      : message)
  }

  function runHtmlExporter(dest, temp) {
    root.exportPendingDest = dest
    root.exportPendingTemp = temp
    var script = root.exportPendingFormat === "pdf" ? root.exportPdfScriptPath : root.exportScriptPath
    exportChmodProcess.command = ["chmod", "+x", script]
    exportChmodProcess.running = true
  }

  // Runs whichever rich exporter is selected (HTML or PDF); the command line is
  // identical, so the pending format alone decides which script starts.
  function startHtmlProcess() {
    var script = root.exportPendingFormat === "pdf" ? root.exportPdfScriptPath : root.exportScriptPath
    exportProcess.command = [
      script,
      "--input", root.exportPendingTemp,
      "--output", root.exportPendingDest,
      "--title", root.exportPendingTitle,
      "--note-dir", root.exportPendingNoteDir,
      "--color", String(Commons.Color.foreground),
      "--font-px", String(Style.font.body)
    ]
    exportProcess.running = true
  }

  function cleanupExportTemp(temp) {
    var target = String(temp || "")
    if (target === "") return
    if (exportCleanupProcess.running) return
    exportCleanupProcess.command = ["rm", "-f", "--", target]
    exportCleanupProcess.running = true
  }

  function finishExport(ok, detail) {
    root.exporting = false
    if (ok) {
      root.exportError = ""
      root.exportOpen = false
      if (exportPopup) exportPopup.close()
      root.statusText = "Exported to " + String(detail || "")
    } else {
      root.exportError = String(detail || "Export failed")
      root.statusText = root.exportError
    }
  }

  function handleHtmlExportExit(exitCode) {
    var dest = root.exportPendingDest
    var temp = root.exportPendingTemp
    var format = root.exportPendingFormat
    var out = String(exportProcess.outputText || "")
    var err = String(exportProcess.errorText || "")
    root.exportPendingDest = ""
    root.exportPendingTemp = ""
    root.exportPendingFormat = ""
    root.cleanupExportTemp(temp)
    var payload = null
    try { payload = JSON.parse(out.trim()) } catch (error) { payload = null }
    if (exitCode === 0 && payload && payload.ok) {
      root.finishExport(true, dest)
      return
    }
    var message = payload && payload.error ? String(payload.error) : ""
    if (message === "") {
      var lines = err.trim().split("\n")
      message = lines.length > 0 ? String(lines[lines.length - 1]).trim() : ""
    }
    if (message === "") message = format === "pdf" ? "PDF export failed" : "HTML export failed"
    root.finishExport(false, message.slice(0, 300))
  }

  // .quill-context.json is how the agent knows "this note" and "here". Keep it
  // small: the id/title/folder path plus at most 2000 characters of selection.
  function pushChatContext(force) {
    if (!chatOpen && force !== true) return
    if (!chatDock || !chatDock.agent) return
    var note = selectedNote
    var selection = editor ? String(editor.selectedText || "") : ""
    if (selection.length > 2000) selection = selection.slice(0, 2000)
    var context = note ? {
      id: String(note.id || ""),
      title: String(note.title || ""),
      folder: String(note.folder || ""),
      path: notePath(note),
      selectedText: selection,
      updated: Number(note.modified || 0)
    } : {
      id: "",
      title: "",
      folder: "",
      path: "",
      selectedText: "",
      updated: 0
    }
    chatDock.agent.sendContext(context)
  }

  function scheduleChatContext() {
    if (!chatOpen) return
    chatContextTimer.restart()
  }

  // ------------------------------------------------------- bulk actions
  // The backend takes the first id positionally and every extra id as a
  // repeatable --id. Keeping one helper means all bulk commands phrase their
  // arguments exactly the same way.
  function bulkArgs(command, ids, extra) {
    var list = cleanIds(ids)
    var args = [command, list[0]]
    for (var i = 1; i < list.length; i++) args.push("--id", list[i])
    return args.concat(extra || [])
  }

  function cleanIds(ids) {
    var source = Array.isArray(ids) ? ids : []
    var seen = {}
    var output = []
    for (var i = 0; i < source.length; i++) {
      var id = String(source[i] === undefined || source[i] === null ? "" : source[i])
      if (id === "" || seen[id]) continue
      seen[id] = true
      output.push(id)
    }
    return output
  }

  // The ids a menu/keyboard action applies to. A right-click inside a
  // multi-selection acts on the whole selection; anywhere else it is single.
  function actionIdsFor(id) {
    var key = String(id || "")
    if (root.selectedIds.length > 1 && root.isMultiSelected(key)) {
      return root.selectedIds.slice()
    }
    return key === "" ? [] : [key]
  }

  // Bulk results describe the positional note with unqualified keys, so move
  // the open note to the front when it belongs to the batch. Tag writes use
  // that content to keep the editor in sync.
  function primaryFirst(ids) {
    var list = cleanIds(ids)
    var active = String(root.selectedId)
    var index = list.indexOf(active)
    if (index > 0) {
      list.splice(index, 1)
      list.unshift(active)
    }
    return list
  }

  function armUndoTrash(ids) {
    var list = cleanIds(ids)
    if (list.length === 0) { root.clearUndoTrash(); return }
    root.undoTrashIds = list
    root.undoLabel = list.length === 1
      ? "Moved 1 note to Trash" : "Moved " + list.length + " notes to Trash"
    root.undoRemaining = 12
    undoTimer.restart()
    undoTickTimer.restart()
  }

  function clearUndoTrash() {
    undoTimer.stop()
    undoTickTimer.stop()
    if (root.undoTrashIds.length > 0) root.undoTrashIds = []
    root.undoLabel = ""
    root.undoRemaining = 0
  }

  function undoTrash() {
    var list = root.cleanIds(root.undoTrashIds)
    var count = list.length
    // Clear first: a second click while the restore runs must not queue it
    // twice, and a failure must not leave a stale Undo behind.
    root.clearUndoTrash()
    if (count === 0) return
    root.enqueue({
      args: root.bulkArgs("restore", list),
      silent: true,
      onSuccess: function(result) {
        var restored = Number(result.count || count)
        root.statusText = restored === 1
          ? "Restored 1 note" : "Restored " + restored + " notes"
        root.refreshAll(root.statusText)
        root.refreshTrash()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function pinNotes(ids) {
    var requested = root.cleanIds(ids)
    var list = []
    for (var n = 0; n < requested.length; n++) {
      var candidate = root.findAny(requested[n])
      if (candidate && !candidate.trashed) list.push(requested[n])
    }
    if (list.length === 0) return
    var everyPinned = true
    for (var i = 0; i < list.length; i++) {
      var note = root.findAny(list[i])
      if (!note || !note.pinned) { everyPinned = false; break }
    }
    var state = everyPinned ? "off" : "on"
    root.enqueue({
      args: root.bulkArgs("pin", list, ["--state", state]),
      silent: true,
      onSuccess: function(result) {
        var count = Number(result.count || list.length)
        root.statusText = result.pinned
          ? (count === 1 ? "Pinned" : "Pinned " + count + " notes")
          : (count === 1 ? "Unpinned" : "Unpinned " + count + " notes")
        root.refreshAll(root.statusText)
      },
      onError: function(message) { root.statusText = message }
    })
  }

  // The visible note a deletion leaves behind: the first surviving row after
  // the last removed one, or the first survivor when the tail was removed.
  function nextVisibleAfter(removed) {
    var gone = {}
    for (var g = 0; g < removed.length; g++) gone[String(removed[g])] = true
    var list = root.filteredNotes()
    var lastIndex = -1
    for (var i = 0; i < list.length; i++) {
      if (gone[String(list[i].id)]) lastIndex = i
    }
    for (var after = lastIndex + 1; after < list.length; after++) {
      var nextId = String(list[after].id)
      if (!gone[nextId]) return nextId
    }
    for (var from = 0; from < list.length; from++) {
      var fallback = String(list[from].id)
      if (!gone[fallback]) return fallback
    }
    return ""
  }

  function trashNotes(ids) {
    var list = root.cleanIds(ids)
    if (list.length === 0) return
    var activeId = String(root.selectedId)
    // If the active buffer is in the batch, its pending edits must land before
    // the backend moves the file. Other rows are untouched by the flush.
    var run = function() {
      if (root.tableOpen && list.indexOf(activeId) >= 0) root.closeTable(false)
      var nextId = root.nextVisibleAfter(list)
      root.enqueue({
        args: root.bulkArgs("trash", list),
        silent: true,
        onSuccess: function(result) {
          var removed = Array.isArray(result.ids) ? result.ids.map(String) : list
          // The whole batch is gone; the editor moves to the next survivor.
          if (removed.indexOf(String(root.selectedId)) >= 0) {
            root.selectedId = ""
            root.clearEditor()
          }
          root.selectedIds = []
          root.selectionAnchor = ""
          root.selectionRangeBase = []
          root.selectionRangeActive = false
          root.pendingSelectId = nextId
          root.armUndoTrash(removed)
          root.refreshAll(root.undoLabel)
          root.refreshTrash()
        },
        onError: function(message) { root.statusText = message }
      })
    }
    if (list.indexOf(activeId) >= 0) root.afterSave(activeId, run)
    else run()
  }

  function restoreNotes(ids) {
    var list = root.cleanIds(ids)
    if (list.length === 0) return
    root.enqueue({
      args: root.bulkArgs("restore", list),
      silent: true,
      onSuccess: function(result) {
        var restored = Array.isArray(result.ids) ? result.ids.map(String) : list
        var count = Number(result.count || restored.length)
        root.selectedIds = []
        root.selectionAnchor = ""
        root.selectionRangeBase = []
        root.selectionRangeActive = false
        root.pendingSelectId = String(result.id || restored[0] || "")
        root.category = "all"
        root.statusText = count === 1
          ? "Restored 1 note" : "Restored " + count + " notes"
        root.refreshAll(root.statusText)
        root.refreshTrash()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function deleteForeverNotes(ids) {
    var list = root.cleanIds(ids)
    if (list.length === 0) return
    root.enqueue({
      args: root.bulkArgs("delete", list),
      silent: true,
      onSuccess: function(result) {
        var removed = Array.isArray(result.ids) ? result.ids.map(String) : list
        var count = Number(result.count || removed.length)
        var activeRemoved = removed.indexOf(String(root.selectedId)) >= 0
        var kept = []
        for (var i = 0; i < root.selectedIds.length; i++) {
          var id = String(root.selectedIds[i])
          if (removed.indexOf(id) < 0) kept.push(id)
        }
        root.selectedIds = kept
        if (activeRemoved) {
          root.selectedId = ""
          root.clearEditor()
          root.pendingSelectId = ""
        }
        if (kept.length === 0 || root.selectionAnchor === "" || removed.indexOf(root.selectionAnchor) >= 0) {
          root.selectionAnchor = kept.length > 0 ? String(kept[0]) : ""
          root.selectionRangeBase = []
          root.selectionRangeActive = false
        }
        root.statusText = count === 1
          ? "Deleted forever" : "Deleted " + count + " notes forever"
        root.refreshTrash()
        root.refreshAll(root.statusText)
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function moveNotes(ids, folder) {
    var list = root.cleanIds(ids)
    if (list.length === 0) return
    var targetFolder = String(folder || "")
    // Rows already at the destination need no write; an all-no-op drop still
    // gets a clear status instead of a silent nothing.
    var moving = []
    for (var i = 0; i < list.length; i++) {
      var note = root.findAny(list[i])
      // Skip only a row we know is already at the destination. A missing or
      // stale id is left in the batch so the backend's all-or-nothing
      // validation reports it instead of a silent partial move.
      if (note && !note.trashed && String(note.folder || "") === targetFolder) continue
      moving.push(list[i])
    }
    if (moving.length === 0) {
      root.statusText = "Already in " + (targetFolder === "" ? "Inbox" : targetFolder)
      return
    }
    var activeId = String(root.selectedId)
    var run = function() {
      if (root.tableOpen && moving.indexOf(activeId) >= 0) root.closeTable(false)
      root.enqueue({
        args: root.bulkArgs("move", moving, ["--folder", targetFolder]),
        silent: true,
        onSuccess: function(result) {
          var moved = Array.isArray(result.ids) ? result.ids.map(String) : moving
          var count = Number(result.count || moved.length)
          var label = targetFolder === "" ? "Inbox" : targetFolder
          var primary = String(result.id || moved[0] || "")
          // Follow the batch into its new home so the rows stay visible, then
          // keep them selected for the next bulk action.
          root.category = targetFolder === "" ? "all" : "folder:" + targetFolder
          root.searchText = ""
          root.searchResults = []
          root.searching = false
          if (noteList) noteList.clearSearch()
          root.selectedIds = moved
          root.selectionAnchor = primary
          root.selectionRangeBase = []
          root.selectionRangeActive = false
          root.pendingSelectId = primary
          root.statusText = count === 1
            ? "Moved 1 note to " + label
            : "Moved " + count + " notes to " + label
          root.refreshAll(root.statusText)
        },
        onError: function(message) { root.statusText = message }
      })
    }
    if (moving.indexOf(activeId) >= 0) root.afterSave(activeId, run)
    else run()
  }

  function parseBulkTags(value) {
    var parts = String(value || "").split(/[\s,]+/)
    var seen = {}
    var output = []
    for (var i = 0; i < parts.length; i++) {
      var tag = TagSuggest.normalizeTag(parts[i])
      if (!tag || seen[tag]) continue
      seen[tag] = true
      output.push(tag)
    }
    return output
  }

  function openBulkTagPrompt(mode) {
    var requested = root.selectionIds()
    var ids = []
    for (var i = 0; i < requested.length; i++) {
      var note = root.findAny(requested[i])
      if (note && !note.trashed) ids.push(requested[i])
    }
    if (requested.length > 0 && ids.length === 0) {
      root.statusText = "Restore this note before adding tags"
      return
    }
    if (ids.length === 0) {
      root.statusText = "Select a note first"
      return
    }
    root.bulkTagIds = ids
    root.bulkTagCount = ids.length
    root.bulkTagMode = String(mode || "add") === "remove" ? "remove" : "add"
    root.bulkTagError = ""
    bulkTagPopup.open()
  }

  function confirmBulkTags(mode) {
    if (!root.writesAllowed) {
      root.bulkTagError = WritableGuard.refusalMessage()
      root.statusText = root.bulkTagError
      return
    }
    var tags = root.parseBulkTags(bulkTagField.text)
    if (tags.length === 0) {
      root.bulkTagError = "Type at least one tag"
      root.statusText = root.bulkTagError
      return
    }
    var ids = root.cleanIds(root.bulkTagIds)
    if (ids.length === 0) {
      root.bulkTagError = "Select a note first"
      return
    }
    root.bulkTagError = ""
    bulkTagPopup.close()
    if (String(mode) === "remove") root.removeTagsFromNotes(ids, tags)
    else root.addTagsToNotes(ids, tags)
  }

  function addTagsToNotes(ids, tags) {
    root.writeTagsForNotes("tag-add", ids, tags)
  }

  function removeTagsFromNotes(ids, tags) {
    root.writeTagsForNotes("tag-remove", ids, tags)
  }

  function writeTagsForNotes(command, ids, tags) {
    var clean = root.cleanIds(tags)
    var ordered = root.primaryFirst(ids)
    if (ordered.length === 0 || clean.length === 0) return
    var activeId = String(root.selectedId)
    var applyVersion = root.editVersion
    var run = function() {
      root.enqueue({
        args: root.bulkArgs(command, ordered, clean),
        silent: true,
        onSuccess: function(result) {
          var updated = Number(result.updated || ordered.length)
          if (String(result.id || ordered[0]) === activeId
              && String(root.selectedId) === activeId
              && result.content !== undefined) {
            // Same discipline as applySuggestedTags(): replace the buffer only
            // when it has not gained newer edits since the command started.
            var versionChanged = root.editVersion !== applyVersion
            var alreadyApplied = !root.dirty
              && String(editor.text) === String(result.content)
            if (!versionChanged || alreadyApplied) {
              root.applyExternalContent(result.content, result.modified,
                command === "tag-add" ? "Tags added" : "Tags removed")
            }
          }
          root.statusText = command === "tag-add"
            ? (updated === 1 ? "Tags added" : "Tags added to " + updated + " notes")
            : (updated === 1 ? "Tags removed" : "Tags removed from " + updated + " notes")
          root.refreshAll(root.statusText)
        },
        onError: function(message) {
          root.bulkTagError = message
          root.statusText = message
        }
      })
    }
    if (ordered.indexOf(activeId) >= 0) root.afterSave(activeId, run)
    else run()
  }

  function togglePin() {
    root.pinNotes(root.selectionIds())
  }

  // The arm key includes the whole selection so changing it between the two
  // presses disarms the delete instead of applying it to a surprise batch.
  function selectionArmKey() {
    if (root.selectedIds.length > 1) {
      return "@selection:" + root.selectedIds.join("|")
    }
    return String(root.selectedId)
  }

  function armDelete(deleteForever, count) {
    var total = Number(count || 1)
    deleteArmed = true
    deleteArmId = root.selectionArmKey()
    armTimer.restart()
    if (deleteForever) {
      statusText = total > 1
        ? "Press Ctrl+Delete again to delete " + total + " notes forever"
        : "Press Ctrl+Delete again to delete forever"
    } else {
      statusText = total > 1
        ? "Press Ctrl+Delete again to move " + total + " notes to Trash"
        : "Press Ctrl+Delete again to move to Trash"
    }
  }

  function trashSelected() {
    var ids = root.selectionIds()
    if (ids.length === 0) return
    if (root.selectedNote && root.selectedNote.trashed) {
      root.deleteForeverSelected()
      return
    }
    if (!deleteArmed || deleteArmId !== root.selectionArmKey()) {
      root.armDelete(false, ids.length)
      return
    }
    deleteArmed = false
    root.trashNotes(ids)
  }

  function restoreSelected() {
    root.restoreNotes(root.selectionIds())
  }

  function deleteForeverSelected() {
    var ids = root.selectionIds()
    var trashed = []
    for (var i = 0; i < ids.length; i++) {
      var note = root.findAny(ids[i])
      if (note && note.trashed) trashed.push(ids[i])
    }
    if (trashed.length === 0) return
    if (!deleteArmed || deleteArmId !== root.selectionArmKey()) {
      root.armDelete(true, trashed.length)
      return
    }
    deleteArmed = false
    root.deleteForeverNotes(trashed)
  }

  function emptyTrash() {
    if (trashCount === 0) return
    if (!deleteArmed) {
      deleteArmed = true
      deleteArmId = "@trash"
      armTimer.restart()
      statusText = "Press Empty trash again to delete everything in Trash"
      return
    }
    deleteArmed = false
    enqueue({
      args: ["empty-trash"],
      silent: true,
      onSuccess: function(result) {
        root.statusText = "Emptied Trash (" + Number(result.deleted || 0) + ")"
        root.refreshTrash()
        root.refreshAll()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function moveSelectedTo(folder) {
    root.moveNotes(root.selectionIds(), folder)
  }

  function setPinnedNote(id) {
    root.pinNotes(root.actionIdsFor(id))
  }

  function beginRenameNote(id) {
    var note = findAny(id)
    if (!note || note.trashed) return
    // A second rename supersedes any in-flight dry run and its prompt.
    root.renameSeq += 1
    root.pendingRename = null
    root.renameLinksSourceTitle = ""
    if (renameLinksPopup) renameLinksPopup.close()
    root.renameTargetId = String(id)
    root.renameNoteText = String(note.title || "Untitled")
    renameNotePopup.open()
  }

  function confirmRenameNote() {
    var id = root.renameTargetId
    var title = String(root.renameNoteText || "").replace(/\s+/g, " ").trim()
    if (id === "" || title === "") return
    var note = root.findAny(id)
    var sourceTitle = String(note && note.title ? note.title : "Untitled")
    root.renameTargetId = ""
    root.renameNoteText = ""
    root.renameSeq += 1
    var seq = root.renameSeq
    root.pendingRename = null
    root.renameLinksSourceTitle = ""
    renameNotePopup.close()
    root.afterSave(id, function() {
      // The save above can resolve after the user started another rename.
      if (seq !== root.renameSeq) return
      root.enqueue({
        args: ["rename", id, "--title", title, "--dry-run"],
        silent: true,
        onSuccess: function(result) {
          if (seq !== root.renameSeq) return
          var count = Number(result.linksUpdated || 0)
          if (count > 0) {
            root.renameLinksSourceTitle = sourceTitle
            root.pendingRename = { id: id, title: title, count: count }
            renameLinksPopup.open()
          } else {
            // Nothing points at the old title, so the dry run already told us
            // everything the real rename would: skip the extra scan.
            root.performRename(id, title, "skip")
          }
        },
        onError: function(message) {
          if (seq !== root.renameSeq) return
          root.statusText = message
        }
      })
    })
  }

  function renameLinksMessageText() {
    var pending = root.pendingRename
    if (!pending) return ""
    var count = Number(pending.count || 0)
    return "Update " + count + " " + (count === 1 ? "link" : "links")
      + " to “" + String(root.renameLinksSourceTitle || "this note") + "”?"
  }

  function performRename(id, title, mode) {
    root.pendingRename = null
    root.renameLinksSourceTitle = ""
    if (renameLinksPopup) renameLinksPopup.close()
    root.enqueue({
      args: ["rename", id, "--title", title, "--links", mode],
      silent: true,
      onSuccess: function(result) {
        var updated = Number(result.linksUpdated || 0)
        root.statusText = updated > 0
          ? "Renamed · " + updated + (updated === 1 ? " link updated" : " links updated")
          : "Renamed"
        root.refreshAll()
        root.reloadRenamedNote(id)
        root.reloadRewrittenNote(id, result.sources)
      },
      onError: function(message) { root.statusText = message }
    })
  }

  // The rename rewrote every note that linked to the old title on disk. If one
  // of those is open, reload it like any clean external change so the editor
  // never reports our own write as a conflict.
  function reloadRewrittenNote(renamedId, sources) {
    var selected = root.selectedId
    if (selected === "" || selected === renamedId) return
    var list = Array.isArray(sources) ? sources : []
    var rewritten = false
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (row && String(row.id || "") === selected) { rewritten = true; break }
    }
    if (!rewritten) return
    if (!(root.loaded && !root.dirty && root.saveState !== "Saving…"
        && !root.loadingNote && !root.tooLarge)) {
      root.statusText = "Links to the renamed note were updated on disk — Reload to see them"
      return
    }
    var requestedId = selected
    root.enqueue({
      args: ["read", requestedId],
      silent: true,
      onSuccess: function(result) {
        if (requestedId !== root.selectedId) return
        // The read sits behind the refresh list job; keep newer typing.
        if (!root.loaded || root.dirty || root.saveState === "Saving…"
            || root.loadingNote || root.tooLarge) {
          root.statusText = "Links to the renamed note were updated on disk — Reload to see them"
          return
        }
        root.applyExternalContent(result.content, result.modified, "Links updated")
      },
      onError: function(message) { root.statusText = message }
    })
  }

  // Rename rewrites the title on disk. Reload it into the open editor at once,
  // otherwise the next keystroke autosaves the old title back over it.
  function reloadRenamedNote(id) {
    if (id !== root.selectedId) return
    enqueue({
      args: ["read", id],
      silent: true,
      onSuccess: function(result) {
        if (id !== root.selectedId || !root.loaded || root.loadingNote
            || root.tooLarge) return
        var content = String(result.content || "")
        if (root.dirty || root.saveState === "Saving…") {
          root.diskChangePending = true
          root.diskChangeText = content
          root.statusText = "Note changed on disk"
          return
        }
        root.applyExternalContent(content, result.modified, "Renamed")
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function duplicateNote(id) {
    var note = findAny(id)
    if (!note || note.trashed) return
    var folder = String(note.folder || "")
    var targetCategory = folder === "" ? "all" : "folder:" + folder
    root.afterSave(id, function() {
      enqueue({
        args: ["duplicate", id],
        silent: true,
        onSuccess: function(result) {
          var newId = String(result.id || "")
          if (root.category !== "all" && root.category !== targetCategory) {
            root.category = targetCategory
          }
          root.pendingSelectId = newId
          root.searchText = ""
          root.searchResults = []
          root.searching = false
          if (noteList) noteList.clearSearch()
          root.statusText = "Duplicated"
          root.refreshAll()
        },
        onError: function(message) { root.statusText = message }
      })
    })
  }

  // Create the missing target from the backlinks pane. The store reindexes on
  // create, so every existing `[[target]]` in this note resolves immediately.
  function createBrokenLinkNote(target) {
    var title = String(target === undefined || target === null ? "" : target).trim()
    if (title === "" || !root.writesAllowed) return
    root.enqueue({
      args: ["create", "--title", title],
      silent: true,
      onSuccess: function(result) {
        root.pendingSelectId = String(result.id || "")
        root.searchText = ""
        root.searchResults = []
        root.searching = false
        if (noteList) noteList.clearSearch()
        root.statusText = "Created “" + title + "”"
        root.refreshAll()
        root.requestUnresolved()
        root.requestBacklinks()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function moveNoteTo(id, folder) {
    root.moveNotes(root.actionIdsFor(id), folder)
  }

  function trashNote(id) {
    root.trashNotes(root.actionIdsFor(id))
  }

  function restoreNote(id) {
    root.restoreNotes(root.actionIdsFor(id))
  }

  function requestDeleteNote(id) {
    var ids = root.actionIdsFor(id)
    if (ids.length === 0) return
    var note = root.findAny(ids[0])
    if (!note || !note.trashed) return
    root.deleteNoteTargetId = String(ids[0])
    root.pendingDeleteIds = ids
    root.deleteNoteTargetTitle = ids.length > 1
      ? ids.length + " notes" : String(note.title || "Untitled")
    deleteNotePopup.open()
  }

  function confirmDeleteNote() {
    var ids = root.pendingDeleteIds.length > 0
      ? root.pendingDeleteIds.slice() : (root.deleteNoteTargetId === "" ? [] : [root.deleteNoteTargetId])
    if (ids.length === 0) return
    root.deleteNoteTargetId = ""
    root.pendingDeleteIds = []
    deleteNotePopup.close()
    root.deleteForeverNotes(ids)
  }

  function handleNoteAction(id, action) {
    var ids = root.actionIdsFor(id)
    if (action === "pin") root.pinNotes(ids)
    else if (action === "duplicate") root.duplicateNote(id)
    else if (action === "trash") root.trashNotes(ids)
    else if (action === "restore") root.restoreNotes(ids)
    else if (action === "delete-forever") root.requestDeleteNote(id)
    else if (action === "tag-add") root.openBulkTagPrompt("add")
    else if (action === "tag-remove") root.openBulkTagPrompt("remove")
  }

  function createFolder(path) {
    enqueue({
      args: ["folder", "create", path],
      silent: true,
      onSuccess: function(result) {
        root.category = "folder:" + String(result.folder || path)
        root.statusText = "Created folder " + String(result.folder || path)
        root.refreshAll()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function renameFolder(path, next) {
    enqueue({
      args: ["folder", "rename", path, next],
      silent: true,
      onSuccess: function(result) {
        root.category = "folder:" + String(result.folder || next)
        root.statusText = "Renamed folder"
        root.refreshAll()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  function requestDeleteFolder(path) {
    if (!folderDeleteArmed || folderDeletePath !== path) {
      folderDeleteArmed = true
      folderDeletePath = path
      folderArmTimer.restart()
      statusText = "Press × again to delete folder " + path
      return
    }
    folderDeleteArmed = false
    enqueue({
      args: ["folder", "delete", path],
      silent: true,
      onSuccess: function() {
        if (root.category === "folder:" + path) root.category = "all"
        root.statusText = "Deleted folder"
        root.refreshAll()
      },
      onError: function(message) { root.statusText = message }
    })
  }

  // -------------------------------------------------------------- shortcuts
  function cycleMode() {
    if (tableOpen) closeTable(false)
    var order = ["edit", "split", "preview"]
    var index = order.indexOf(mode)
    mode = order[(index + 1) % order.length]
    modeChosen = true
    if (mode !== "edit") flushSave()
  }

  function setMode(next) {
    if (tableOpen) closeTable(false)
    mode = next
    modeChosen = true
    if (next !== "edit") flushSave()
  }

  function handleEscape() {
    // A multi-selection is the innermost thing to dismiss: collapse it back to
    // the active note before touching popups or panes.
    if (root.selectedIds.length > 1) {
      root.collapseSelection()
      return
    }
    if (quickSwitcher && quickSwitcher.opened) {
      quickSwitcher.close()
      return
    }
    if (renameLinksPopup && renameLinksPopup.opened) {
      root.pendingRename = null
      root.renameLinksSourceTitle = ""
      renameLinksPopup.close()
      root.statusText = "Cancelled"
      return
    }
    if (versionHistory && versionHistory.opened) {
      versionHistory.close()
      return
    }
    if (bulkTagPopup && bulkTagPopup.opened) {
      bulkTagPopup.close()
      return
    }
    if (tagSuggestPopup && tagSuggestPopup.opened) {
      // Escape is the popup's cancel key, but never while a tag write is in
      // flight: closing then would let the result overwrite newer typing.
      if (!tagSuggestPopup.applying) tagSuggestPopup.close()
      return
    }
    if (root.exportOpen) {
      root.closeExport()
      return
    }
    if (viewMenuOpen) {
      viewMenuOpen = false
      return
    }
    if (tableOpen) {
      tableEditor.handleEscape()
      return
    }
    if (deleteArmed) {
      deleteArmed = false
      deleteArmId = ""
      statusText = "Cancelled"
      return
    }
    folderDeleteArmed = false
    if (searchText !== "") {
      searchText = ""
      searchResults = []
      searching = false
      root.clearSelection()
      noteList.clearSearch()
      ensureSelection()
      return
    }
    requestClose()
  }

  function focusInitial() {
    if (noteListOpen && noteList) noteList.forceActiveFocus()
    else if (sidebarOpen && sidebar) sidebar.forceActiveFocus()
    else if (editor) editor.forceActiveFocus()
  }

  // ------------------------------------------------------------------- UI
  focus: true

  Component.onCompleted: {
    mode = width >= Style.space(1000) ? "split" : "edit"
    if (active) refreshAll()
    root.loadSavedSearches()
    root.loadTemplates()
  }

  Component.onDestruction: {
    // Stop the bridge before its data root goes away. The queue dies with the
    // window, so the exit handler has nothing to requeue or respawn.
    root.activeJob = null
    root.pendingJob = null
    root.jobs = []
    daemonEventTimer.stop()
    daemon.running = false
    // A hard crash may leave the temp file; a normal shutdown should not.
    if (root.previewTempFile !== "") {
      Quickshell.execDetached(["rm", "-f", root.previewTempFile])
    }
  }

  onWidthChanged: {
    if (!modeChosen) mode = width >= Style.space(1000) ? "split" : "edit"
    if (chatOpen && width < Style.space(980)) {
      chatOpen = false
      showChatNotice("Widen the window to use chat")
    }
  }

  onActiveChanged: {
    if (!active) viewMenuOpen = false
  }

  Timer { id: saveTimer; interval: 600; onTriggered: root.flushSave() }
  // Coalesces unsolicited index-change events from the bridge: a burst of
  // writes from sync or a detached window becomes one refresh.
  Timer { id: daemonEventTimer; interval: 400; onTriggered: root.refreshAll() }
  Timer {
    id: tagApplyTimer
    objectName: "tagApplyTimeoutTimer"
    interval: 20000
    repeat: false
    onTriggered: root.tagApplyTimedOut()
  }
  Connections {
    target: tagSuggestPopup
    function onApplyingChanged() {
      if (tagSuggestPopup.applying) tagApplyTimer.restart()
      else tagApplyTimer.stop()
    }
  }
  Timer {
    id: joplinNotifyTimer
    interval: 2500
    repeat: false
    onTriggered: {
      if (root.joplinSyncPath === "" || !root.writesAllowed) return
      joplinNotifyProcess.command = [root.joplinSyncPath, "--notify"]
      joplinNotifyProcess.running = true
    }
  }
  Timer { id: searchTimer; interval: 170; onTriggered: root.runSearch() }
  Timer { id: refreshTimer; interval: 1100; onTriggered: if (!root.dirty) root.refreshAll() }
  Timer { id: armTimer; interval: 3200; onTriggered: { root.deleteArmed = false; root.deleteArmId = "" } }
  // Twelve-second Undo window. The tick only refreshes the visible countdown;
  // the single-shot timer owns the actual expiry.
  Timer {
    id: undoTimer
    interval: 12000
    repeat: false
    onTriggered: root.clearUndoTrash()
  }
  Timer {
    id: undoTickTimer
    interval: 1000
    repeat: true
    onTriggered: if (root.undoRemaining > 0) root.undoRemaining -= 1
  }
  Timer { id: folderArmTimer; interval: 3200; onTriggered: { root.folderDeleteArmed = false; root.folderDeletePath = "" } }
  Timer { id: chatContextTimer; interval: 400; onTriggered: root.pushChatContext(false) }
  Timer { id: chatNoticeTimer; interval: 2200; onTriggered: root.chatNotice = "" }
  Timer {
    id: pendingSelectTimer
    interval: 2500
    onTriggered: {
      if (root.pendingSelectId && !root.hasVisibleId(root.pendingSelectId)) {
        root.pendingSelectId = ""
        root.pendingFocusEditor = false
        root.pendingCaretToEnd = false
        root.ensureSelection()
      }
    }
  }

  DraftWriter {
    id: draftWriter
    objectName: "draftWriter"
    onFailed: function(path, error) {
      if (root.dirty && !root.draftPending) root.statusText = "Could not save draft"
    }
  }

  // Live preview writer. The render is enqueued from onSaved, never from the
  // debounce, so the backend always finds a complete file to read.
  FileView {
    id: previewWriter
    property bool busy: false
    property string pendingId: ""
    property string pendingText: ""
    property string targetId: ""
    property string targetText: ""
    // The last buffer successfully written, so a repeat can skip the write.
    property string writtenPath: ""
    property string writtenText: ""
    atomicWrites: true
    blockAllReads: true
    printErrors: false
    onSaved: root.previewFileSaved()
    onSaveFailed: function(error) { root.previewFileFailed(String(error)) }
  }

  // Wait for a pause in typing before rendering the buffer. The autosave and
  // draft timers are deliberately independent of this one.
  Timer { id: previewDebounce; interval: 200; onTriggered: root.requestBufferPreview() }

  Timer { id: draftTimer; interval: 150; onTriggered: root.writeDraft() }

  function runSearch() {
    var query = searchText.trim()
    if (!query) {
      searching = false
      searchResults = []
      root.clearSelection()
      ensureSelection()
      return
    }
    if (root.searching && root.searchResults.length > 0 && root.lastQuery === query) return
    root.lastQuery = query
    searching = true
    enqueue({
      args: ["search", query, "--limit", "80"],
      silent: true,
      onSuccess: function(result) {
        if (root.searchText.trim() !== query) return
        root.searchResults = Array.isArray(result.results) ? result.results : []
        root.searching = false
        root.ensureSelection()
      },
      onError: function(message) {
        if (root.searchText.trim() !== query) return
        root.searching = false
        root.searchResults = []
        root.statusText = message
      }
    })
  }

  property string lastQuery: ""

  Shortcut { sequence: "Ctrl+N"; enabled: root.active; onActivated: root.createNote(false, false) }
  Shortcut { sequence: "Ctrl+Shift+N"; enabled: root.active; onActivated: root.createNote(true, false) }
  Shortcut { sequence: "Ctrl+F"; enabled: root.active; onActivated: root.focusSearch() }
  Shortcut {
    sequence: "/"
    enabled: root.active && !root.editorActive && !root.searchActive && !root.chatInputActive
      && !quickSwitcher.opened
    onActivated: root.focusSearch()
  }
  Shortcut { sequence: "Ctrl+P"; enabled: root.active; onActivated: root.openQuickSwitcher() }
  Shortcut { sequence: "Ctrl+Shift+P"; enabled: root.active; onActivated: root.togglePin() }
  Shortcut { sequence: "Ctrl+Shift+T"; enabled: root.active; onActivated: root.openBulkTagPrompt("add") }
  Shortcut { sequence: "Ctrl+Shift+F"; enabled: root.active; onActivated: root.focusAdvancedSearch() }
  Shortcut { sequence: "Ctrl+E"; enabled: root.active; onActivated: root.cycleMode() }
  Shortcut { sequence: "Ctrl+S"; enabled: root.active; onActivated: root.flushSave() }
  Shortcut { sequence: "Ctrl+Shift+O"; enabled: root.active; onActivated: root.openInEditor() }
  Shortcut { sequence: "Ctrl+Shift+E"; enabled: root.active; onActivated: root.openExport() }
  Shortcut {
    sequence: "Ctrl+T"
    enabled: root.active && root.editorActive
    onActivated: root.insertTableTemplate()
  }
  Shortcut { sequence: "Ctrl+Shift+Return"; enabled: root.active; onActivated: root.openLibraryWindow() }
  Shortcut { sequence: "Ctrl+Return"; enabled: root.active; onActivated: root.detachSelectedNote() }
  Shortcut { sequence: "Ctrl+Delete"; enabled: root.active; onActivated: root.trashSelected() }
  Shortcut { sequence: "Escape"; enabled: root.active; onActivated: root.handleEscape() }
  Shortcut { sequence: "Ctrl+1"; enabled: root.active; onActivated: root.focusSidebar() }
  Shortcut { sequence: "Ctrl+2"; enabled: root.active; onActivated: root.focusNotes() }
  Shortcut { sequence: "Ctrl+3"; enabled: root.active; onActivated: editor.forceActiveFocus() }

  Process {
    id: process
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: process.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: process.errorText = String(text || "")
    }
    onExited: function(exitCode) { root.handleJobExit(exitCode) }
  }

  // Persistent backend bridge. One JSON request per line goes in; one response
  // or event per line comes out. `pendingJob` keeps the request that started
  // the bridge until `onStarted` can write it. stderr is diagnostics only:
  // replies carry their own error messages, and an exit is the failure signal.
  Process {
    id: daemon
    // Kept for diagnostics only: replies carry their own error messages.
    property string lastError: ""
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.handleDaemonLine(line) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: daemon.lastError = String(text || "")
    }
    onStarted: {
      root.daemonReady = true
      root.daemonStarting = false
      var job = root.pendingJob
      root.pendingJob = null
      if (job) root.daemonRequest(job)
    }
    onExited: function(exitCode) { root.handleDaemonExit(exitCode) }
  }

  // `quill-window` daemonizes quickshell and returns immediately; a non-zero
  // exit only means the launcher could not start (missing note id, bad path).
  Process {
    id: detachedProcess
    stderr: StdioCollector { id: detachedError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.statusText = String(detachedError.text || "").trim() || "Could not open a detached window"
      }
    }
  }

  // Fire-and-forget: the sync tool queues the work and returns immediately.
  // Failures (including a missing tool) are deliberately not surfaced.
  Process {
    id: joplinNotifyProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Rich export (HTML or PDF): chmod the renderer, run it with the temp
  // Markdown source, then remove that source. The temporary file lives in
  // dataRoot, never in notes/, so the library index can never mistake it for
  // a note.
  Process {
    id: exportValidateProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.afterExportPathCheck(exitCode) }
  }

  Process {
    id: exportChmodProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var temp = root.exportPendingTemp
        var fmt = root.exportPendingFormat
        root.exportPendingDest = ""
        root.exportPendingTemp = ""
        root.exportPendingFormat = ""
        root.cleanupExportTemp(temp)
        root.finishExport(false, fmt === "pdf"
          ? "Could not run the PDF export renderer"
          : "Could not run the HTML export renderer")
        return
      }
      root.startHtmlProcess()
    }
  }

  Process {
    id: exportProcess
    property string outputText: ""
    property string errorText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: exportProcess.outputText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: exportProcess.errorText = String(text || "")
    }
    onExited: function(exitCode) { root.handleHtmlExportExit(exitCode) }
  }

  Process {
    id: exportCleanupProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Column {
    id: layoutColumn
    anchors.fill: parent
    spacing: Style.space(8)

    // ------------------------------------------------------------- header
    Row {
      id: headerRow
      width: parent.width
      height: Style.space(42)
      spacing: Style.space(10)

      Column {
        id: headerTitle
        width: parent.width - headerActions.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: "QUILL  /  " + root.categoryLabel.toUpperCase()
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: "Local Markdown" + (root.totalCount > 0 ? "  ·  " + root.totalCount + " notes" : "")
            + (root.trashCount > 0 ? "  ·  " + root.trashCount + " in trash" : "")
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      Row {
        id: headerActions
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Row {
          spacing: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          ModeButton { label: "Edit"; current: root.mode === "edit"; onActivated: root.setMode("edit") }
          ModeButton { label: "Split"; current: root.mode === "split"; onActivated: root.setMode("split") }
          ModeButton { label: "Preview"; current: root.mode === "preview"; onActivated: root.setMode("preview") }
          ModeButton {
            label: "Agent"
            current: root.chatOpen
            onActivated: root.toggleChat()
          }
        }

        Button {
          text: root.inWindow ? "Dock" : "Window"
          iconText: root.inWindow ? "⤡" : "⤢"
          tooltipText: root.inWindow
            ? "Dock back into the bar panel (Ctrl+Shift+Enter)"
            : "Open the Quill library in its own window (Ctrl+Shift+Enter)"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(5)
          onClicked: root.openLibraryWindow()
        }
        Row {
          spacing: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter

          Button {
            text: "New note"
            iconText: "+"
            active: true
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(9)
            verticalPadding: Style.space(5)
            tooltipText: "New note (Ctrl+N)"
            onClicked: root.createNote(false, false)
          }
          Button {
            id: newNoteTemplateButton
            objectName: "newNoteTemplateButton"
            text: "▾"
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(4)
            verticalPadding: Style.space(5)
            tooltipText: "New note from template"
            onClicked: newNoteTemplateMenu.popup(
              newNoteTemplateButton, 0,
              newNoteTemplateButton.height + Style.space(4))
          }
        }
        Button {
          id: viewButton
          text: "View"
          iconText: "☰"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(5)
          tooltipText: "Show or hide panes"
          onClicked: root.viewMenuOpen ? root.closeViewMenu() : root.openViewMenu()
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Util.alpha(Commons.Color.foreground, 0.14)
    }

    // -------------------------------------------------------------- panes
    Item {
      id: panesArea
      width: parent.width
      height: parent.height - y - statusBar.height - parent.spacing

      readonly property real gap: Style.space(8)
      readonly property real sidebarSlot: sidebar.visible
        ? sidebar.width : (sidebarRail.visible ? sidebarRail.width : 0)
      readonly property real noteSlot: noteList.visible
        ? noteList.width : (noteRail.visible ? noteRail.width : 0)

      Sidebar {
        id: sidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: root.sidebarOpen
        width: visible ? Math.max(Style.space(160), Math.min(Style.space(205), root.width * 0.16)) : 0
        notes: root.notes
        folders: root.folders
        tags: root.tags
        savedSearches: root.savedSearches
        activeSearch: root.searchText
        category: root.category
        trashCount: root.trashCount
        onCategorySelected: function(next) { root.selectCategory(next) }
        onTagSubtreeSelected: function(prefix) {
          root.selectCategory("tagtree:" + String(prefix || ""))
        }
        onTagActionRequested: function(tag, action) {
          root.openTagManager(String(tag || ""), String(action || ""))
        }
        onCreateFolderRequested: function(path) { root.createFolder(path) }
        onRenameFolderRequested: function(path, next) { root.renameFolder(path, next) }
        onDeleteFolderRequested: function(path) { root.requestDeleteFolder(path) }
        onSavedSearchSelected: function(query) { root.runSavedSearch(query) }
        onSavedSearchRemoveRequested: function(query) { root.removeSavedSearch(query) }
        onSavedSearchSaveRequested: root.saveCurrentSearch()
        onCollapseRequested: root.sidebarOpen = false
        onNoteDropRequested: function(payload, folder) {
          var parts = String(payload || "").split("\n")
          var ids = []
          for (var i = 0; i < parts.length; i++) {
            var id = String(parts[i] || "").trim()
            if (id !== "") ids.push(id)
          }
          root.moveNotes(ids, folder)
        }
      }

      PaneRail {
        id: sidebarRail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: !root.sidebarOpen
        width: visible ? Style.space(20) : 0
        label: "Library"
        onExpandRequested: root.sidebarOpen = true
      }

      NoteList {
        id: noteList
        anchors.left: parent.left
        anchors.leftMargin: panesArea.sidebarSlot + panesArea.gap
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: root.noteListOpen
        width: visible ? Math.max(Style.space(280), Math.min(Style.space(340), root.width * 0.28)) : 0
        notes: root.visibleNotes
        selectedId: root.selectedId
        selectedIds: root.selectedIds
        searchText: root.searchText
        searching: root.searching
        showTrash: root.category === "trash"
        loading: root.loadingList
        folderOptions: root.folderOptions
        onNoteSelected: function(id) { root.selectNote(id) }
        onNoteActionRequested: function(id, action) { root.handleNoteAction(id, action) }
        onNoteRenameRequested: function(id) { root.beginRenameNote(id) }
        onNoteMoveRequested: function(id, folder) { root.moveNoteTo(id, folder) }
        onSelectionToggleRequested: function(id) { root.toggleSelection(id) }
        onSelectionRangeRequested: function(id) { root.extendSelectionTo(id) }
        onSelectAllRequested: root.selectAllVisible()
        onSelectionCleared: root.collapseSelection()
        onSearchQueryChanged: function(text) {
          root.searchText = text
          if (text.trim() !== "") {
            root.searching = true
            searchTimer.restart()
          } else {
            root.searching = false
            root.searchResults = []
            root.clearSelection()
            root.ensureSelection()
          }
        }
        onEscapePressed: function() { root.handleEscape() }
        onEditorFocusRequested: function() { editor.forceActiveFocus() }
        onCollapseRequested: root.noteListOpen = false
      }

      PaneRail {
        id: noteRail
        anchors.left: parent.left
        anchors.leftMargin: panesArea.sidebarSlot + panesArea.gap
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: !root.noteListOpen
        width: visible ? Style.space(20) : 0
        label: "Notes"
        onExpandRequested: root.noteListOpen = true
      }

      BorderSurface {
        id: editorPane
        // Anchors avoid the Row's stale child positions when the window
        // shrinks and a child width depends on sibling widths.
        anchors.left: parent.left
        anchors.leftMargin: panesArea.sidebarSlot + panesArea.noteSlot + panesArea.gap * 2
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: chatDock.visible ? chatDock.left : parent.right
        anchors.rightMargin: chatDock.visible ? panesArea.gap : 0
        color: Util.alpha(Commons.Color.foreground, 0.022)
        borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
        radius: Style.cornerRadius

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(11)
          spacing: Style.space(6)

          NoteHeader {
            id: noteHeader
            width: parent.width
            height: root.selectedNote ? Style.space(62) : Style.space(36)
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(Commons.Color.foreground, 0.1)
          }

          DraftBanner {
            width: parent.width
            visible: root.draftPending
            draftModified: root.draftModified
            onRecoverRequested: root.recoverDraft()
            onDiscardRequested: root.discardDraft()
          }

          ExternalChangeBanner {
            width: parent.width
            visible: root.diskChangePending
            onReloadRequested: root.reloadFromDisk()
            onKeepRequested: root.keepDiskChange()
          }

          FormatBar {
            id: formatBar
            // Full pane width: the surrounding column has 11 px margins for
            // the note header and editor, but the toolbar reads as a full
            // strip and gains 22 px at the user's 669/176 editor widths.
            width: parent.width + Style.space(22)
            x: -Style.space(11)
            visible: root.mode !== "preview"
            available: root.loaded && !root.tooLarge && !!root.selectedNote
              && !root.selectedNote.trashed && !root.draftPending
            canUndo: editor ? editor.canUndo : false
            canRedo: editor ? editor.canRedo : false
            linkValue: editor ? editor.currentLinkURL() : ""
            noteTitles: root.noteTitleList
            onAction: function(name, value) {
              if (!editor) return
              if (name === "attach") editor.openAttachPicker()
              else if (name === "draw") editor.openDrawCanvas()
              else editor.applyFormat(name, value)
            }
          }

          Row {
            id: contentRow
            width: parent.width
            height: Math.max(0, parent.height - y - backlinksBox.height - parent.spacing)
            spacing: 0

            Flickable {
              id: editorScroll
              width: root.mode === "edit" ? parent.width : root.mode === "preview" ? 0 : Math.floor((parent.width - Style.space(1)) / 2)
              height: parent.height
              visible: root.mode !== "preview"
              clip: true
              contentWidth: width
              contentHeight: editor.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              function ensureVisible(rect) {
                if (contentY >= rect.y) contentY = rect.y
                else if (contentY + height <= rect.y + rect.height) contentY = rect.y + rect.height - height
              }

              MarkdownEditor {
                id: editor
                objectName: "markdownEditor"
                width: editorScroll.width
                height: Math.max(editorScroll.height, implicitHeight)
                storePath: root.storePath
                enabled: root.loaded && !root.tooLarge && !root.loadingNote
                  && !!root.selectedNote && !root.selectedNote.trashed
                  && !root.draftPending
                readOnly: (root.selectedNote ? !!root.selectedNote.trashed : true) || root.draftPending
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                onCursorRectangleChanged: editorScroll.ensureVisible(cursorRectangle)
                foregroundColor: enabled || readOnly ? Commons.Color.foreground : Util.alpha(Commons.Color.foreground, 0.38)
                accentColor: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                leftPadding: Style.space(10)
                rightPadding: Style.space(10)
                topPadding: Style.space(8)
                bottomPadding: Style.space(24)
                placeholderText: root.tooLarge
                  ? "This note is too large to edit safely in Quill."
                  : root.selectedNote
                    ? (root.selectedNote.trashed ? "This note is in Trash" : root.loaded ? "Start writing Markdown…" : "Loading note…")
                    : "Select or create a note"
                placeholderTextColor: Util.alpha(Commons.Color.foreground, 0.28)
                onTextChanged: root.onEditorEdited()
                onSelectedTextChanged: root.scheduleChatContext()
                onLinkRequested: formatBar.openLinkPopover()
                onNoteLinkRequested: formatBar.openNoteLink()
                onFormatRejected: function(message) { root.statusText = message }
                onImagePasted: function(path) { root.statusText = "Image added" }
                onPasteFailed: function(message) { root.statusText = message }
                onAttachmentAdded: function(path) { root.statusText = "File attached" }
                onAttachFailed: function(message) { root.statusText = message }
              }
            }

            Rectangle {
              visible: root.mode === "split"
              width: Style.space(1)
              height: parent.height
              color: Util.alpha(Commons.Color.foreground, 0.1)
            }

            Item {
              id: previewArea
              width: root.mode === "preview" ? parent.width
                : root.mode === "edit" ? 0
                : Math.floor((parent.width - Style.space(1)) / 2)
              height: parent.height

              PreviewPane {
                anchors.fill: parent
                visible: root.mode !== "edit" && !root.tableOpen
                markdown: root.previewMarkdown
                loading: root.previewLoading || root.loadingNote
                dirty: root.dirty
                hasNote: !!root.selectedNote
                tooLarge: root.tooLarge
                editable: root.loaded && !root.tooLarge && !!root.selectedNote
                  && !root.selectedNote.trashed && !root.draftPending
                lineOffset: root.previewLineOffset
                onLinkActivated: function(link) { root.openLink(link) }
                onImageResized: function(line, width) { root.setImageWidth(line, width) }
                onImageReset: function(line) { root.clearImageSize(line) }
                onTaskToggled: function(line) { root.toggleTaskAt(line) }
                onTableActivated: function(startLine, endLine) {
                  root.openTableAt(startLine, endLine)
                }
              }

              TableGrid {
                id: tableEditor
                anchors.fill: parent
                visible: root.tableOpen
                sourceText: editor.text
                editable: root.loaded && !root.tooLarge && !!root.selectedNote
                  && !root.selectedNote.trashed && !root.draftPending
                onCommitRequested: function(newLines) { root.applyTableWrite(newLines) }
                onStatusMessage: function(message) { root.statusText = message }
                onClosed: {
                  if (root.tableOpen) root.closeTable(true)
                }
              }
            }
          }

          // ---------------------------------------------------- backlinks
          BorderSurface {
            id: backlinksBox
            width: parent.width
            // Header rows are 20-22 px plus the box's 3 px top/bottom margins.
            // The broken-links section adds its own header and, when open, a
            // short scrolling list so the editor pane above can still shrink
            // without the panes collapsing into each other.
            height: {
              var total = root.backlinksOpen ? Style.space(142) : Style.space(26)
              if (root.unresolvedShown) {
                total += Style.space(24)
                if (root.unresolvedOpen) total += Style.space(96)
              }
              return total
            }
            color: Util.alpha(Commons.Color.foreground, 0.014)
            borderSpec: Border.none
            radius: Style.cornerRadius

            Column {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              anchors.topMargin: Style.space(3)
              anchors.bottomMargin: Style.space(3)
              spacing: 0

              Item {
                width: parent.width
                height: Style.space(20)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.backlinksOpen ? "▾  " : "▸  ") + "Backlinks (" + root.backlinks.length + ")"
                  color: root.backlinks.length > 0 ? Commons.Color.foreground : Util.alpha(Commons.Color.foreground, 0.46)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.backlinks.length > 0
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.backlinksOpen = !root.backlinksOpen
                }
              }

              ListView {
                visible: root.backlinksOpen
                width: parent.width
                height: root.backlinksOpen ? Style.space(116) : 0
                clip: true
                model: root.backlinks
                spacing: Style.space(2)

                delegate: BorderSurface {
                  id: backlinkRow
                  required property var modelData
                  width: ListView.view.width
                  height: Style.space(28)
                  color: backMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
                  borderSpec: Border.none
                  radius: Style.cornerRadius

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(6)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "←"
                      color: Util.alpha(Commons.Color.foreground, 0.35)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: parent.width - Style.space(22)
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(backlinkRow.modelData.title || "Untitled")
                      textFormat: Text.PlainText
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    id: backMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectNote(String(backlinkRow.modelData.id))
                  }
                }

                Text {
                  visible: root.backlinks.length === 0
                  anchors.centerIn: parent
                  text: "No other note links here yet"
                  color: Util.alpha(Commons.Color.foreground, 0.32)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // -------------------------------------------- broken links
              Item {
                width: parent.width
                height: root.unresolvedShown ? Style.space(22) : 0
                visible: root.unresolvedShown

                Text {
                  objectName: "brokenLinksHeader"
                  anchors.verticalCenter: parent.verticalCenter
                  text: "⚠  Broken links (" + root.unresolvedTargets.length + ")"
                  textFormat: Text.PlainText
                  color: root.unresolvedTargets.length > 0
                    ? Commons.Color.urgent
                    : Util.alpha(Commons.Color.foreground, 0.46)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.unresolvedTargets.length > 0
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.unresolvedOpen = !root.unresolvedOpen
                }
              }

              ListView {
                objectName: "brokenLinksList"
                visible: root.unresolvedOpen
                width: parent.width
                height: root.unresolvedOpen ? Style.space(96) : 0
                clip: true
                model: root.unresolvedTargets
                spacing: Style.space(2)

                delegate: BorderSurface {
                  id: brokenLinkRow
                  required property var modelData
                  width: ListView.view.width
                  height: Style.space(28)
                  color: brokenMouse.containsMouse
                    ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                    : "transparent"
                  borderSpec: Border.none
                  radius: Style.cornerRadius

                  MouseArea {
                    id: brokenMouse
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(6)

                    Text {
                      width: Math.max(0, parent.width - brokenCreateButton.width - parent.spacing)
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(brokenLinkRow.modelData.target || "")
                      textFormat: Text.PlainText
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    Button {
                      id: brokenCreateButton
                      objectName: "brokenLinkCreateButton"
                      text: "Create"
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(7)
                      verticalPadding: Style.space(2)
                      enabled: root.writesAllowed
                      opacity: enabled ? 1 : 0.45
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.createBrokenLinkNote(
                        String(brokenLinkRow.modelData.target || ""))
                    }
                  }
                }
              }
            }
          }
        }
      }

      ChatDock {
        id: chatDock
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: root.chatOpen
        width: Style.space(340)
        dataRoot: root.dataRoot
        pluginDir: root.pluginDir
        onCloseRequested: root.chatOpen = false
        onLinkActivated: function(link) { root.openLink(link) }
      }
    }

    Row {
      id: statusBar
      width: parent.width
      height: Style.space(20)
      spacing: Style.space(6)

      Rectangle {
        width: Style.space(6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.dirty ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.3)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.statusText
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: Math.max(0, parent.width - shortcuts.width - undoSlot.width - Style.space(28))
      }
      // A fixed slot reserves the space even while Undo is hidden, so the
      // status row never jumps when a trash arms the affordance.
      Item {
        id: undoSlot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(54)
        height: Style.space(16)

        Text {
          id: undoButton
          objectName: "undoTrashButton"
          visible: root.undoTrashIds.length > 0
          anchors.centerIn: parent
          text: root.undoRemaining > 0 ? "Undo · " + root.undoRemaining + "s" : "Undo"
          textFormat: Text.PlainText
          color: undoMouse.containsMouse
            ? Commons.Color.accent : Util.alpha(Commons.Color.accent, 0.82)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: undoMouse.containsMouse

          MouseArea {
            id: undoMouse
            anchors.fill: parent
            anchors.margins: -Style.space(2)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.undoTrash()
          }
        }
      }
      Text {
        id: shortcuts
        anchors.verticalCenter: parent.verticalCenter
        text: "Ctrl+N new · Ctrl+T table · Ctrl+S save · Ctrl+E view · Ctrl+1/2/3 panes"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: Math.min(implicitWidth, parent.width * 0.5)
      }
    }
  }

  // The bridge reports ready before the service is necessarily usable; send
  // the current note context once it is up so "this note" works immediately.
  Connections {
    target: chatDock.agent

    function onReadyChanged() {
      if (root.chatOpen && chatDock.agent.ready) root.pushChatContext(true)
    }
  }

  Rectangle {
    id: chatToast
    visible: root.chatNotice !== ""
    z: 150
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(32)
    width: chatToastLabel.implicitWidth + Style.space(24)
    height: chatToastLabel.implicitHeight + Style.space(12)
    color: Util.alpha(Commons.Color.background, 0.96)
    border.width: 1
    border.color: Util.alpha(Commons.Color.accent, 0.35)
    radius: Style.cornerRadius

    Text {
      id: chatToastLabel
      anchors.centerIn: parent
      text: root.chatNotice
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ------------------------------------------------------------ view menu
  // Drawn in the library scene rather than as a native Qt menu so it follows
  // the theme and stays visible in grabToImage. The backdrop closes it on the
  // first click outside; rows deliberately keep it open.
  Item {
    id: viewOverlay
    anchors.fill: parent
    visible: root.viewMenuOpen
    z: 100

    MouseArea {
      anchors.fill: parent
      onClicked: root.closeViewMenu()
    }

    BorderSurface {
      id: viewMenu
      width: Style.space(196)
      height: viewMenuColumn.implicitHeight + Style.space(10)
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius

      // The View button is the last header action, so the menu right-aligns
      // with the header's right edge. Avoid mapToItem here: a binding inside a
      // layout can evaluate before the header settles.
      x: Math.max(Style.space(8), root.width - width - Style.space(2))
      y: headerRow.y + headerRow.height + Style.space(4)

      // Clicks on padding should not reach the backdrop.
      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Column {
        id: viewMenuColumn
        anchors.fill: parent
        anchors.margins: Style.space(5)
        spacing: Style.space(1)

        ViewMenuRow {
          label: "Library"
          checked: root.sidebarOpen
          onActivated: root.toggleSidebar()
        }
        ViewMenuRow {
          label: "Notes"
          checked: root.noteListOpen
          onActivated: root.toggleNoteList()
        }
        ViewMenuRow {
          label: "Editor"
          checked: root.mode !== "preview"
          onActivated: root.toggleEditor()
        }
        ViewMenuRow {
          label: "Preview"
          checked: root.mode !== "edit"
          onActivated: root.togglePreview()
        }
        ViewMenuRow {
          label: "Agent"
          checked: root.chatOpen
          onActivated: root.toggleChat()
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(Commons.Color.foreground, 0.12)
        }

        ViewMenuRow {
          label: "Reset layout"
          showCheck: false
          onActivated: root.resetLayout()
        }
      }
    }
  }

  // ------------------------------------------------------- tag suggestions
  TagSuggestPopup {
    id: tagSuggestPopup
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    onApplied: function(tags) { root.applySuggestedTags(tags) }
    onCancelled: root.clearTagSuggestTarget()
  }

  // Bulk tag entry for the whole selection. Add and Remove send one backend
  // call for every captured id; the field takes spaces or commas.
  Popup {
    id: bulkTagPopup
    objectName: "bulkTagPopup"
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(360)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onOpened: {
      bulkTagField.text = ""
      bulkTagField.forceActiveFocus()
    }
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      width: bulkTagPopup.availableWidth
      spacing: Style.space(9)

      Text {
        width: parent.width
        text: root.bulkTagCount === 1
          ? "Tags for 1 note" : "Tags for " + root.bulkTagCount + " notes"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      TextField {
        id: bulkTagField
        objectName: "bulkTagField"
        width: parent.width
        placeholderText: "Tags, comma or space separated"
        font.pixelSize: Style.font.bodySmall
        onTextEdited: if (root.bulkTagError !== "") root.bulkTagError = ""
        onAccepted: root.confirmBulkTags("add")
      }

      Text {
        width: parent.width
        visible: root.bulkTagError !== ""
        text: root.bulkTagError
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: Math.max(0, parent.width - bulkTagCancel.width
            - bulkTagRemove.width - bulkTagAdd.width - parent.spacing * 3)
          height: 1
        }

        Button {
          id: bulkTagCancel
          objectName: "bulkTagCancelButton"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: bulkTagPopup.close()
        }
        Button {
          id: bulkTagRemove
          objectName: "bulkTagRemoveButton"
          text: "Remove"
          active: root.bulkTagMode === "remove"
          enabled: bulkTagField.text.trim() !== ""
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.confirmBulkTags("remove")
        }
        Button {
          id: bulkTagAdd
          objectName: "bulkTagAddButton"
          text: "Add"
          active: root.bulkTagMode !== "remove"
          enabled: bulkTagField.text.trim() !== ""
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.confirmBulkTags("add")
        }
      }
    }
  }

  // ------------------------------------------------------- quick switcher
  QuickSwitcher {
    id: quickSwitcher
    entries: root.titleIndex
    selectedId: root.selectedId
    loading: root.titlesLoading
    onNoteChosen: function(id, detached) { root.openNoteFromSwitcher(id, detached) }
  }

  // ---------------------------------------------------------- rename dialog
  Popup {
    id: renameNotePopup
    objectName: "renameNotePopup"
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(360)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onOpened: {
      // Set the text explicitly: typing can break the initial binding, and a
      // second rename must show the newly selected note's title.
      renameNoteField.text = root.renameNoteText
      renameNoteField.forceActiveFocus()
      renameNoteField.selectAll()
    }
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      width: renameNotePopup.availableWidth
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: "Rename note"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      TextField {
        id: renameNoteField
        objectName: "renameNoteField"
        width: parent.width
        text: root.renameNoteText
        font.pixelSize: Style.font.bodySmall
        onTextEdited: root.renameNoteText = text
        onAccepted: root.confirmRenameNote()
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: Math.max(0, parent.width - renameCancelButton.width
            - renameConfirmButton.width - parent.spacing * 2)
          height: 1
        }

        Button {
          id: renameCancelButton
          objectName: "renameCancelButton"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: {
            root.renameTargetId = ""
            renameNotePopup.close()
          }
        }
        Button {
          id: renameConfirmButton
          objectName: "renameConfirmButton"
          text: "Rename"
          active: true
          enabled: String(root.renameNoteText).trim() !== ""
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.confirmRenameNote()
        }
      }
    }
  }

  // ------------------------------------------------- rename link updates
  // Dry runs that found `[[old title]]` links ask before rewriting other
  // notes. Skipping still renames; the links keep pointing at the old title
  // and show up under Broken links.
  Popup {
    id: renameLinksPopup
    objectName: "renameLinksPopup"
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(380)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onClosed: {
      root.pendingRename = null
      root.renameLinksSourceTitle = ""
    }
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      width: renameLinksPopup.availableWidth
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: "Update links?"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        objectName: "renameLinksMessage"
        width: parent.width
        text: root.renameLinksMessageText()
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Util.alpha(Commons.Color.foreground, 0.56)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: Math.max(0, parent.width - renameLinksUpdateButton.width
            - renameLinksSkipButton.width - renameLinksCancelButton.width
            - parent.spacing * (renameLinksUpdateButton.visible ? 3 : 2))
          height: 1
        }

        Button {
          id: renameLinksUpdateButton
          objectName: "renameLinksUpdateButton"
          width: visible ? implicitWidth : 0
          visible: !!root.pendingRename && Number(root.pendingRename.count || 0) > 0
          text: "Update links"
          active: true
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: {
            if (!root.pendingRename) return
            root.performRename(root.pendingRename.id, root.pendingRename.title, "update")
          }
        }
        Button {
          id: renameLinksSkipButton
          objectName: "renameLinksSkipButton"
          text: "Just rename"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: {
            if (!root.pendingRename) return
            root.performRename(root.pendingRename.id, root.pendingRename.title, "skip")
          }
        }
        Button {
          id: renameLinksCancelButton
          objectName: "renameLinksCancelButton"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: {
            root.pendingRename = null
            root.renameLinksSourceTitle = ""
            renameLinksPopup.close()
            root.statusText = "Cancelled"
          }
        }
      }
    }
  }

  // ------------------------------------------------------- delete forever
  // Permanent deletion always goes through this modal; a menu row alone is
  // never the confirmation.
  Popup {
    id: deleteNotePopup
    objectName: "deleteNotePopup"
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(380)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      width: deleteNotePopup.availableWidth
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: root.pendingDeleteIds.length > 1
          ? "Delete " + root.pendingDeleteIds.length + " notes forever?"
          : "Delete note forever?"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        objectName: "deleteNoteTitle"
        width: parent.width
        text: root.pendingDeleteIds.length > 1
          ? root.pendingDeleteIds.length + " notes will be permanently deleted. This cannot be undone."
          : "“" + root.deleteNoteTargetTitle + "” will be permanently deleted. This cannot be undone."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Util.alpha(Commons.Color.foreground, 0.56)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: Math.max(0, parent.width - deleteNoteCancelButton.width
            - deleteNoteConfirmButton.width - parent.spacing * 2)
          height: 1
        }

        Button {
          id: deleteNoteCancelButton
          objectName: "deleteNoteCancelButton"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: {
            root.deleteNoteTargetId = ""
            root.pendingDeleteIds = []
            deleteNotePopup.close()
          }
        }
        Button {
          id: deleteNoteConfirmButton
          objectName: "deleteNoteConfirmButton"
          text: "Delete forever"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.confirmDeleteNote()
        }
      }
    }
  }

  // ------------------------------------------------------------ export menu
  // Themed modal. A native dialog would ignore the shell theme (and Qt's
  // platform dialogs are light), so the format choice, path field and errors
  // all live in one BorderSurface-backed Popup.
  Popup {
    id: exportPopup
    objectName: "exportPopup"
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(360)
    padding: Style.space(12)
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onOpened: {
      exportPathField.text = root.exportPath
      exportPathField.forceActiveFocus()
      exportPathField.cursorPosition = exportPathField.text.length
    }
    onClosed: {
      if (root.exportOpen) root.exportOpen = false
    }
    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      width: exportPopup.availableWidth
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: "Export note"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          objectName: "exportMarkdownButton"
          width: (parent.width - parent.spacing * 2) / 3
          text: "Markdown"
          active: root.exportFormat === "markdown"
          enabled: !root.exporting
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(5)
          onClicked: root.setExportFormat("markdown")
        }
        Button {
          objectName: "exportHtmlButton"
          width: (parent.width - parent.spacing * 2) / 3
          text: "HTML"
          active: root.exportFormat === "html"
          enabled: !root.exporting
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(5)
          onClicked: root.setExportFormat("html")
        }
        Button {
          objectName: "exportPdfButton"
          width: (parent.width - parent.spacing * 2) / 3
          text: "PDF"
          active: root.exportFormat === "pdf"
          enabled: !root.exporting
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(5)
          onClicked: root.setExportFormat("pdf")
        }
      }

      TextField {
        id: exportPathField
        objectName: "exportPathField"
        width: parent.width
        placeholderText: "/home/you/Note.md"
        font.pixelSize: Style.font.bodySmall
        enabled: !root.exporting
        onTextEdited: {
          root.exportPath = text
          if (root.exportError !== "") root.exportError = ""
        }
        onAccepted: root.performExport()
      }

      Text {
        id: exportErrorText
        objectName: "exportErrorText"
        width: parent.width
        text: root.exportError !== ""
          ? root.exportError
          : "Markdown copies the buffer verbatim; HTML is one standalone file with embedded images and maths, and PDF prints that same rendering via headless Chromium."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.exportError !== ""
          ? Commons.Color.urgent
          : Util.alpha(Commons.Color.foreground, 0.48)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: Math.max(0, parent.width - exportCancelButton.width - exportConfirmButton.width - parent.spacing * 2)
          height: 1
        }

        Button {
          id: exportCancelButton
          objectName: "exportCancelButton"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.closeExport()
        }
        Button {
          id: exportConfirmButton
          objectName: "exportConfirmButton"
          text: root.exporting ? "Exporting…" : "Export"
          active: true
          enabled: !root.exporting && String(root.exportPath).trim() !== ""
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(5)
          onClicked: root.performExport()
        }
      }
    }
  }

  // ------------------------------------------------------- version history
  // Restoring is only offered while the open buffer is clean: the store
  // snapshots the current note first, so any unsaved text would be captured
  // as the "before restore" entry instead of being written.
  VersionHistory {
    id: versionHistory
    storePath: root.storePath
    canRestore: root.loaded && !root.dirty && root.saveState !== "Saving…"
      && !root.loadingNote && root.writesAllowed
    onRestored: function(id) {
      if (id === root.selectedId) {
        // The watcher may report the restored bytes before loadNote() finishes.
        // A restore is only possible from a clean buffer, so any pending
        // conflict belongs to an older disk state and must not become a banner.
        root.diskChangePending = false
        root.diskChangeText = ""
        root.loadNote()
      }
      root.statusText = "Restored version"
    }
  }

  // --------------------------------------------------------- tag dialogs
  // The dialog owns the wording and merge warning; the write stays here so it
  // passes through the same WritableGuard queue as every other command.
  TagManager {
    id: tagManager
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(380)
    tags: root.tags
    onCommitRequested: function(action, tag, next) {
      root.applyTagAction(String(action || ""), String(tag || ""), String(next || ""))
    }
  }

  // Templates are files, so this panel is only an editor; a template created
  // from the CLI appears in the menu on the next load.
  TemplateManager {
    id: templateManager
    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    width: Style.space(760)
    height: Style.space(520)
    storePath: root.storePath
    dataRoot: root.dataRoot
    onTemplatesChanged: root.loadTemplates()
  }

  // ------------------------------------------------------- template menu
  // Kept out of the main New note button: Ctrl+N and the button itself stay
  // an instant blank note. The chevron opts in to a built-in template.
  Menu {
    id: newNoteTemplateMenu
    objectName: "newNoteTemplateMenu"
    width: Style.space(220)
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    palette.window: Commons.Color.menu.background
    palette.windowText: Commons.Color.menu.text
    palette.text: Commons.Color.menu.text
    palette.buttonText: Commons.Color.menu.text
    palette.light: Commons.Color.menu.selectedBackground
    palette.midlight: Util.alpha(Commons.Color.foreground, 0.12)
    palette.mid: Util.alpha(Commons.Color.foreground, 0.16)
    palette.dark: Commons.Color.menu.border

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    ContextMenuItem {
      objectName: "templateBlankItem"
      text: "Blank note"
      onTriggered: root.createNote(false, false)
    }

    MenuSeparator {}

    // Template entries are inserted between this separator and the manage
    // item by rebuildTemplateMenu(); index 2 is the first free slot.
    ContextMenuItem {
      objectName: "templateManageItem"
      text: "Manage templates…"
      onTriggered: {
        newNoteTemplateMenu.close()
        root.openTemplateManager()
      }
    }
  }

  Component {
    id: templateMenuItemComponent
    ContextMenuItem {
      id: templateMenuItem
      property string templateId: ""
      property string templateDescription: ""
      onTriggered: {
        newNoteTemplateMenu.close()
        if (templateMenuItem.templateId !== "") {
          root.createNoteFromTemplate(templateMenuItem.templateId)
        }
      }
    }
  }

  // --------------------------------------------------------- note header
  component NoteHeader: Item {
    id: noteHeaderRoot
    width: parent ? parent.width : 0

    Column {
      anchors.fill: parent
      spacing: Style.space(4)
      visible: !!root.selectedNote

      Row {
        width: parent.width
        height: Style.space(32)
        spacing: Style.space(8)

        Column {
          width: parent.width - headerTools.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0
          Text {
            width: parent.width
            text: root.selectedNote ? String(root.selectedNote.title || "Untitled") : "No note selected"
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: root.selectedNote
              ? (root.selectedNote.folder ? String(root.selectedNote.folder) : "Inbox")
                + "  ·  " + root.relativeTime(root.selectedNote.modified)
                + "  ·  " + root.wordCount + (root.wordCount === 1 ? " word" : " words")
                + (root.backlinks.length > 0 ? "  ·  " + root.backlinks.length + (root.backlinks.length === 1 ? " backlink" : " backlinks") : "")
              : ""
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, 0.46)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Row {
          id: headerTools
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.saveState
            color: root.saveState.indexOf("Unsaved") === 0 || root.saveState.indexOf("Saving") === 0 || root.saveState.indexOf("failed") >= 0
              ? Commons.Color.accent
              : Util.alpha(Commons.Color.foreground, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            objectName: "externalEditorButton"
            visible: !!root.selectedNote && !root.selectedNote.trashed
            width: Style.space(23)
            height: Style.space(23)
            text: ""
            iconText: "\uf044"
            iconSize: Style.font.bodySmall
            tooltipText: "Open in editor (Ctrl+Shift+O)"
            horizontalPadding: 0
            verticalPadding: 0
            onClicked: root.openInEditor()
          }

          Button {
            objectName: "historyButton"
            visible: !!root.selectedNote && !root.selectedNote.trashed
            width: Style.space(23)
            height: Style.space(23)
            text: ""
            iconText: "\uf1da"
            iconSize: Style.font.bodySmall
            tooltipText: "Version history"
            horizontalPadding: 0
            verticalPadding: 0
            onClicked: versionHistory.openFor(root.selectedId,
              root.selectedNote ? root.selectedNote.title : "")
          }

          Dropdown {
            visible: !!root.selectedNote && !root.selectedNote.trashed
            width: root.compactHeader ? Style.space(104) : Style.space(136)
            rowHeight: Style.space(26)
            showLabel: false
            options: root.folderOptions
            value: root.selectedNote ? String(root.selectedNote.folder || "") : ""
            onChanged: function(value) { root.moveSelectedTo(value) }
          }

          Button {
            visible: !!root.selectedNote && !root.selectedNote.trashed && !root.compactHeader
            text: root.selectedNote && root.selectedNote.pinned ? "Unpin" : "Pin"
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(4)
            onClicked: root.togglePin()
          }
          Button {
            objectName: "exportButton"
            visible: !!root.selectedNote && !root.compactHeader
            text: "Export"
            tooltipText: "Export note (Ctrl+Shift+E)"
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(4)
            onClicked: root.openExport()
          }
          Button {
            visible: !!root.selectedNote && !root.selectedNote.trashed && !root.compactHeader
            text: root.deleteArmed && root.deleteArmId === root.selectionArmKey() ? "Confirm trash" : "Trash"
            foreground: root.deleteArmed ? Commons.Color.urgent : Util.alpha(Commons.Color.foreground, 0.6)
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(4)
            onClicked: root.trashSelected()
          }
          Button {
            visible: !!root.selectedNote && !!root.selectedNote.trashed && !root.compactHeader
            text: "Restore"
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(4)
            onClicked: root.restoreSelected()
          }
          Button {
            visible: !!root.selectedNote && !!root.selectedNote.trashed && !root.compactHeader
            text: root.deleteArmed && root.deleteArmId === root.selectionArmKey() ? "Confirm delete" : "Delete forever"
            foreground: root.deleteArmed ? Commons.Color.urgent : Util.alpha(Commons.Color.foreground, 0.6)
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(4)
            onClicked: root.deleteForeverSelected()
          }
        }
      }

      Row {
        width: parent.width
        height: Style.space(20)
        spacing: Style.space(5)
        visible: !!root.selectedNote

        Repeater {
          model: root.selectedNote && root.selectedNote.tags ? root.selectedNote.tags : []
          delegate: TagChip {
            required property var modelData
            label: "#" + String(modelData)
            onActivated: root.selectCategory("tag:" + String(modelData))
          }
        }

        TagChip {
          objectName: "addTagChip"
          label: "+ Tag"
          visible: root.tagSuggestAvailable()
          opacity: 0.8
          onActivated: root.openTagSuggest()
        }

        Item { width: Math.max(0, parent.width - x); height: 1 }

        Text {
          visible: root.category === "trash"
          anchors.verticalCenter: parent.verticalCenter
          text: "Empty trash"
          color: root.deleteArmed ? Commons.Color.urgent : Util.alpha(Commons.Color.foreground, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: root.emptyTrash()
          }
        }
      }
    }

    Text {
      visible: !root.selectedNote
      anchors.verticalCenter: parent.verticalCenter
      text: "Choose a note from the list, or press Ctrl+N to start one"
      color: Util.alpha(Commons.Color.foreground, 0.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  component TagChip: BorderSurface {
    id: chip
    property string label: ""
    signal activated()
    width: chipLabel.implicitWidth + Style.space(12)
    height: Style.space(18)
    color: chipMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : Util.alpha(Commons.Color.accent, 0.09)
    borderSpec: Border.flat(Util.alpha(Commons.Color.accent, 0.22), 1)
    radius: Style.cornerRadius

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.accent, 0.9)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.activated()
    }
  }

  component ViewMenuRow: BorderSurface {
    id: viewRow

    property string label: ""
    property bool checked: false
    property bool showCheck: true
    signal activated()

    width: parent ? parent.width : 0
    height: Style.space(26)
    color: viewRowMouse.containsMouse
      ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
      : "transparent"
    borderSpec: Border.none
    radius: Style.cornerRadius

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(7)
      anchors.rightMargin: Style.space(7)
      spacing: Style.space(5)

      Text {
        width: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: viewRow.showCheck && viewRow.checked ? "✓" : ""
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width - Style.space(19)
        anchors.verticalCenter: parent.verticalCenter
        text: viewRow.label
        textFormat: Text.PlainText
        color: viewRow.checked || !viewRow.showCheck
          ? Commons.Color.foreground
          : Util.alpha(Commons.Color.foreground, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: viewRowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: viewRow.activated()
    }
  }

  component ModeButton: BorderSurface {
    id: modeButton
    property string label: ""
    property bool current: false
    signal activated()
    width: modeLabel.implicitWidth + Style.space(14)
    height: Style.space(26)
    color: current ? Style.selectedAccentFill : modeMouse.containsMouse ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent) : "transparent"
    borderSpec: current ? Border.controlSpec("selected", Commons.Color.accent, Commons.Color.accent) : Border.none
    radius: Style.cornerRadius

    Text {
      id: modeLabel
      anchors.centerIn: parent
      text: modeButton.label
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: modeButton.current
    }
    MouseArea {
      id: modeMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: modeButton.activated()
    }
  }

  function relativeTime(milliseconds) {
    var value = Number(milliseconds || 0)
    if (!value) return ""
    var date = new Date(value)
    var now = new Date()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (value >= today) return Qt.formatTime(date, "HH:mm")
    if (value >= today - 86400000) return "Yesterday"
    if (date.getFullYear() === now.getFullYear()) return Qt.formatDate(date, "MMM d")
    return Qt.formatDate(date, "yyyy-MM-dd")
  }
}
