import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ImageSizing.js" as ImageSizing
import "MarkdownFormat.js" as MarkdownFormat
import "NoteLinks.js" as NoteLinks
import "PopupAnchor.js" as PopupAnchor
import "WheelScroll.js" as WheelScroll
import "WritableGuard.js" as WritableGuard

// A single Quill note in its own small Quickshell process. The library's
// Ctrl+Return launches this through scripts/quill-window with QUILL_NOTE_ID and
// QUILL_DATA_DIR in the environment.
ShellRoot {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string noteId: Quickshell.env("QUILL_NOTE_ID") || ""
  readonly property string noteTitle: Quickshell.env("QUILL_NOTE_TITLE") || "Note"
  readonly property string dataRoot: Quickshell.env("QUILL_DATA_DIR") || (home + "/.local/share/quill")
  readonly property string storePath: Quickshell.env("QUILL_STORE_PATH")
    || (home + "/.config/omarchy/plugins/matt.quill/scripts/quill-store")
  // Save-triggered Joplin sync. A QUILL_JOPLIN_SYNC_PATH override opts in
  // explicitly (tests); otherwise the installed tool is used in production.
  readonly property string joplinSyncPath: {
    var override = Quickshell.env("QUILL_JOPLIN_SYNC_PATH") || ""
    if (override.length > 0) return override
    if (Quickshell.env("QUILL_JOPLIN_AUTOSYNC") === "0") return ""
    if (Quickshell.env("QUILL_E2E") === "1") return ""
    return home + "/.local/bin/quill-joplin-sync"
  }
  // Writable only when scripts/quill-window passes the per-launch production
  // opt-in, and never when a test suite has marked the process with QUILL_E2E=1.
  property bool allowRealData: Quickshell.env("QUILL_ALLOW_REAL_DATA") === "1"
    && Quickshell.env("QUILL_E2E") !== "1"
  readonly property bool writesAllowed: WritableGuard.writesAllowed(
    dataRoot, allowRealData, home)

  property bool loading: true
  property bool loaded: false
  property bool tooLarge: false
  // The note file disappeared from notes/ (trashed or deleted elsewhere). The
  // buffer is kept for reference but editing stops, so a save cannot recreate
  // a file the index no longer knows about.
  property bool noteMissing: false
  property bool dirty: false
  property bool saving: false
  property bool suppressDirty: false
  property bool quitAfterSave: false
  property bool savedOnce: false
  property int saveSeq: 0
  property string loadOutput: ""
  property string previewMarkdown: ""
  property int previewLineOffset: 0
  property string statusText: "Loading note…"
  // The detached window can show the editor, the preview, or both. Reading a
  // note and writing one are different jobs, and a narrow window only has
  // room for one of them.
  property string mode: "split"

  // External-editor support, mirroring Library.qml for a single note.
  property bool diskChangePending: false
  property string diskChangeText: ""
  property bool pendingEditorOpen: false
  property string inFlightSaveText: ""
  // Last content known to be on disk, used to recognise our own saves and
  // stale change notifications.
  property string savedText: ""
  // Disk mtime of the buffer, handed to `write --if-mtime` so this window
  // cannot overwrite a newer save from the library or another window.
  property double loadedModified: 0
  // One-shot: the next save skips that guard (Keep mine).
  property bool ignoreStaleWrite: false
  readonly property string watchPath: (root.loaded && !root.tooLarge && root.noteId !== "")
    ? root.dataRoot + "/notes/" + root.noteId : ""

  // Crash-draft recovery, mirroring Library.qml for a single note.
  property bool draftPending: false
  property string draftText: ""
  property int draftModified: 0

  Component.onCompleted: {
    // The per-launch production opt-in is part of allowRealData's binding
    // above, so a harness cannot inherit it accidentally.
    loadNote()
  }

  function alpha(colorValue, opacity) {
    return Qt.rgba(colorValue.r, colorValue.g, colorValue.b, opacity)
  }

  // Local Markdown links are absolute paths; Qt.openUrlExternally needs a URL.
  // Anything that already has a scheme is passed through unchanged.
  function externalLinkUrl(link) {
    var value = String(link === undefined || link === null ? "" : link).trim()
    if (value === "") return ""
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return value
    if (value.slice(0, 2) === "~/") value = root.home + value.slice(1)
    if (value.charAt(0) === "/") return "file://" + value
    return value
  }

  // quill-window lives next to the store script, so a redirected install still
  // launches the matching window.
  readonly property string windowPath: {
    var path = String(root.storePath || "")
    var slash = path.lastIndexOf("/")
    return (slash > 0 ? path.slice(0, slash + 1) : "") + "quill-window"
  }

  // A detached window owns one note, so a link to another note opens it in a
  // second window rather than discarding this note's unsaved edits.
  function openLinkedNote(id) {
    var target = String(id || "").trim()
    if (target === "") return
    if (target === root.noteId) {
      root.statusText = "This note"
      return
    }
    Quickshell.execDetached([root.windowPath, target, "Note", root.dataRoot])
    root.statusText = "Opened in a new window"
  }

  // quill:// links and Markdown links to a note file stay inside Quill;
  // everything else goes to the OS opener. See NoteLinks.js.
  function openLink(link) {
    var target = NoteLinks.classify(link, root.noteId, root.dataRoot)
    if (target.kind === "note") {
      root.openLinkedNote(target.value)
      return
    }
    if (target.kind === "missing") {
      root.statusText = "No note matches “" + target.value + "”"
      return
    }
    if (target.kind === "tag") {
      root.statusText = "Tag “#" + target.value + "” — open the library to browse it"
      return
    }
    if (target.kind !== "external") return
    var url = root.externalLinkUrl(target.value)
    if (url !== "") Qt.openUrlExternally(url)
  }

  function setMode(next) {
    var value = String(next || "")
    if (value !== "edit" && value !== "split" && value !== "preview") return
    if (root.mode === value) return
    root.mode = value
  }

  // The watched file is gone: edited or deleted elsewhere, or moved to Trash
  // by the library. Keep the text on screen, stop the watcher and the saves.
  function markMissing() {
    if (root.noteId === "" || root.noteMissing) return
    root.noteMissing = true
    root.loaded = false
    root.saving = false
    root.dirty = false
    root.diskChangePending = false
    root.diskChangeText = ""
    root.draftPending = false
    root.statusText = "This note is no longer in notes/ — it may have been trashed"
    saveTimer.stop()
    draftTimer.stop()
  }

  function loadNote() {
    if (!noteId) {
      tooLarge = true
      loading = false
      loaded = false
      statusText = "No note id was passed to this window"
      return
    }
    loading = true
    root.loadOutput = ""
    root.previewMarkdown = ""
    root.previewLineOffset = 0
    loadProcess.command = [storePath, "read", noteId]
    loadProcess.running = true
  }

  function applyLoaded(exitCode, outputText, errorText) {
    loading = false
    if (exitCode !== 0) {
      var message = String(errorText || "").trim()
      if (/note not found/i.test(message)) {
        // Trashed (or deleted) before this window read it. Nothing to edit.
        root.noteMissing = true
        root.loaded = false
        root.dirty = false
        root.statusText = "This note is no longer in notes/ — it may have been trashed"
        return
      }
      tooLarge = true
      loaded = false
      statusText = message || "Could not read this note"
      return
    }
    var result = {}
    try {
      result = JSON.parse(outputText || "{}")
    } catch (error) {
      tooLarge = true
      statusText = "Could not read this note"
      return
    }
    suppressDirty = true
    root.noteMissing = false
    tooLarge = !!result.tooLarge
    editor.text = tooLarge ? "" : String(result.content || "")
    editor.resetFormatHistory()
    editor.cursorPosition = 0
    suppressDirty = false
    loaded = !tooLarge
    dirty = false
    savedText = tooLarge ? "" : String(result.content || "")
    loadedModified = Number(result.modified || 0)
    diskChangePending = false
    diskChangeText = ""
    pendingEditorOpen = false
    inFlightSaveText = ""
    statusText = tooLarge ? "This note is too large to edit safely" : "Saved"
    if (result.draft && root.writesAllowed) {
      draftPending = true
      draftText = String(result.draft.content || "")
      draftModified = Number(result.draft.modified || 0)
      statusText = "Draft found"
    } else {
      draftPending = false
      draftText = ""
      draftModified = 0
    }
    if (loaded) {
      requestPreview()
      if (!draftPending) Qt.callLater(function() { editor.forceActiveFocus() })
    }
  }

  function markDirty() {
    if (suppressDirty || loading || !loaded || tooLarge || draftPending) return
    dirty = true
    statusText = "Unsaved"
    saveTimer.restart()
    draftTimer.restart()
  }

  // ------------------------------------------------------------------ drafts
  function draftPath() {
    return root.dataRoot + "/notes/" + root.noteId + ".draft"
  }

  function writeDraft() {
    if (!root.writesAllowed || !root.loaded || root.tooLarge || !root.dirty) return
    if (root.draftPending || root.noteId === "") return
    draftWriter.enqueue(root.draftPath(), String(editor.text))
  }

  function recoverDraft() {
    if (!root.draftPending || root.noteId === "") return
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
    root.dirty = true
    root.statusText = "Draft recovered"
    // Save now through the normal path: the store then removes the equal
    // adjacent draft (or keeps a newer one if one appeared meanwhile).
    saveTimer.stop()
    root.save()
  }

  function discardDraft() {
    if (!root.draftPending || root.noteId === "") return
    if (!root.writesAllowed) {
      root.statusText = WritableGuard.refusalMessage()
      return
    }
    root.statusText = "Discarding draft…"
    discardProcess.command = [root.storePath, "draft", "discard", root.noteId]
    discardProcess.running = true
  }

  // ------------------------------------------------------- external editor
  function openInEditor() {
    if (root.noteId === "") {
      root.statusText = "No note is open"
      return
    }
    if (!root.writesAllowed) {
      root.statusText = WritableGuard.refusalMessage()
      return
    }
    if (root.loading) {
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
    if (root.tooLarge) {
      root.launchExternalEditor()
      return
    }
    if (root.dirty || root.saving) {
      root.pendingEditorOpen = true
      if (root.dirty) root.save()
      return
    }
    root.launchExternalEditor()
  }

  function launchExternalEditor() {
    if (root.noteId === "") return
    var path = root.dataRoot + "/notes/" + root.noteId
    Quickshell.execDetached(["omarchy-launch-editor", path])
    root.statusText = "Opened in external editor"
  }

  // watchChanges reports the change but does not re-read, so reload and sort
  // the fresh text out here. Own saves and stale notifications are ignored.
  function handleExternalContent(content) {
    var value = String(content === undefined || content === null ? "" : content)
    if (noteWatch.path !== root.watchPath) return
    if (!root.loaded || root.loading || root.tooLarge
      || root.draftPending || root.noteId === "") return
    if (value === String(editor.text)) {
      // Our own save (or an identical external write) has landed. A conflict
      // captured for an older disk state is stale now.
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
    if (value === root.savedText) {
      root.diskChangePending = false
      root.diskChangeText = ""
      return
    }
    if (root.dirty || root.saving) {
      root.diskChangePending = true
      root.diskChangeText = value
      root.statusText = "Note changed on disk"
      return
    }
    root.applyExternalContent(value)
  }

  function applyExternalContent(content) {
    if (!root.loaded || root.loading || root.tooLarge || root.noteId === "") return
    var value = String(content === undefined || content === null ? "" : content)
    var caret = editor.cursorPosition
    var scrollY = editorScroll.contentY
    root.suppressDirty = true
    editor.text = value
    editor.resetFormatHistory()
    editor.cursorPosition = Math.min(caret, value.length)
    root.suppressDirty = false
    root.savedText = value
    root.dirty = false
    root.diskChangePending = false
    root.diskChangeText = ""
    root.statusText = "Reloaded from disk"
    saveTimer.stop()
    draftTimer.stop()
    draftWriter.drop(root.draftPath())
    root.requestPreview()
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

  function keepDiskChange() {
    if (!root.diskChangePending) return
    root.savedText = root.diskChangeText
    root.diskChangePending = false
    root.diskChangeText = ""
    root.statusText = "Keeping your version"
    // The disk copy lost: write ours over it without the guard that would
    // refuse for the same reason.
    root.ignoreStaleWrite = true
    if (root.dirty) saveTimer.restart()
  }

  function save() {
    saveTimer.stop()
    if (root.diskChangePending) {
      root.statusText = "Note changed on disk — choose Reload or Keep mine"
      return
    }
    if (!loaded || tooLarge || !dirty || saving) return
    if (!root.writesAllowed) {
      saving = false
      dirty = true
      quitAfterSave = false
      statusText = WritableGuard.refusalMessage()
      return
    }
    saving = true
    saveSeq += 1
    statusText = "Saving…"
    // quill-store deletes .quill-save-* buffers after reading them.
    var path = dataRoot + "/.quill-save-detached-" + saveSeq + "-" + Date.now() + ".md"
    var view = saveFileComponent.createObject(root, { path: path })
    if (!view) {
      saving = false
      pendingEditorOpen = false
      statusText = "Could not prepare a save"
      return
    }
    view.targetText = editor.text
    root.inFlightSaveText = String(editor.text)
    view.setText(editor.text)
  }

  function bufferSaved(view) {
    var contentPath = view.path
    var savedText = view.targetText
    view.destroy()
    var args = [storePath, "write", noteId, "--content-file", contentPath]
    if (!root.ignoreStaleWrite && root.loadedModified > 0) {
      args.push("--if-mtime", String(Math.round(root.loadedModified)))
    }
    root.ignoreStaleWrite = false
    writeProcess.command = args
    writeProcess.savedText = savedText
    writeProcess.running = true
  }

  function bufferFailed(view) {
    view.destroy()
    saving = false
    dirty = true
    inFlightSaveText = ""
    pendingEditorOpen = false
    statusText = "Could not write the note"
    quitAfterSave = false
  }

  function afterWrite(exitCode, errorText) {
    saving = false
    if (inFlightSaveText === writeProcess.savedText) inFlightSaveText = ""
    if (exitCode !== 0) {
      var message = String(errorText || "").trim() || "Save failed"
      var code = ""
      try {
        var failure = JSON.parse(message)
        if (failure && failure.error) {
          code = String(failure.code || "")
          message = String(failure.error)
        }
      } catch (parseError) { /* plain text */ }
      dirty = true
      pendingEditorOpen = false
      quitAfterSave = false
      if (code === "stale") {
        // Another window saved first. Do not retry on the timer: ask, exactly
        // as a watcher conflict does.
        diskChangePending = true
        diskChangeText = ""
        statusText = "Note changed on disk — choose Reload or Keep mine"
        return
      }
      statusText = message
      saveTimer.restart()
      return
    }
    try {
      var saved = JSON.parse(String(writeOut.text || "{}"))
      if (saved && saved.modified) loadedModified = Number(saved.modified)
    } catch (parseError) { /* the note is on disk; the mtime is just unknown */ }
    savedOnce = true
    savedText = String(writeProcess.savedText)
    notifyJoplinSync()
    if (editor.text === writeProcess.savedText) {
      draftTimer.stop()
      draftWriter.drop(root.draftPath())
      dirty = false
      statusText = "Saved " + Qt.formatTime(new Date(), "HH:mm")
      requestPreview()
    } else {
      dirty = true
      statusText = "Unsaved"
      saveTimer.restart()
    }
    if (quitAfterSave) {
      Qt.quit()
      return
    }
    if (pendingEditorOpen && !dirty) {
      pendingEditorOpen = false
      launchExternalEditor()
    }
  }

  function requestPreview() {
    if (!loaded || tooLarge) return
    previewProcess.command = [storePath, "preview", noteId]
    previewProcess.running = true
  }

  // Debounced: several autosaves in a row produce one --notify call.
  function notifyJoplinSync() {
    if (!writesAllowed || joplinSyncPath === "") return
    joplinNotifyTimer.restart()
  }

  // Replace one line in place so the caret/selection is preserved as far as
  // possible and the usual dirty/autosave path runs.
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
    if (!loaded || tooLarge) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = ImageSizing.setWidth(lines[index], width)
    if (updated === null) return
    replaceEditorLine(index, updated)
  }

  function clearImageSize(line) {
    if (!loaded || tooLarge) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = ImageSizing.clearSize(lines[index])
    if (updated === null) return
    replaceEditorLine(index, updated)
  }

  function toggleTaskAt(line) {
    if (!loaded || tooLarge) return
    var index = Math.round(Number(line))
    var lines = String(editor.text).split("\n")
    if (!isFinite(index) || index < 0 || index >= lines.length) return
    var updated = MarkdownFormat.toggleTaskLine(lines[index])
    if (updated === null || updated === lines[index]) return
    replaceEditorLine(index, updated)
  }

  function closeWindow() {
    saveTimer.stop()
    if (!loaded || tooLarge || !dirty) {
      // A pending draft stays on disk for the next open.
      Qt.quit()
      return
    }
    draftTimer.stop()
    root.writeDraft()
    quitAfterSave = true
    save()
    // A failed save must not leave an invisible process behind.
    closeFallback.restart()
  }

  Timer { id: saveTimer; interval: 450; onTriggered: root.save() }
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
  Timer {
    id: closeFallback
    interval: 2500
    onTriggered: { if (!root.saving) Qt.quit() }
  }

  DraftWriter {
    id: draftWriter
    objectName: "draftWriter"
    onFailed: function(path, error) {
      if (root.dirty && !root.draftPending) root.statusText = "Could not save draft"
    }
  }

  Timer { id: draftTimer; interval: 150; onTriggered: root.writeDraft() }

  Process {
    id: loadProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadOutput = String(text || "") }
    stderr: StdioCollector { id: loadError; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyLoaded(exitCode, root.loadOutput, String(loadError.text || ""))
    }
  }

  // Watches the open note for writes made by an external editor, Git,
  // Syncthing or the library window. See handleExternalContent().
  FileView {
    id: noteWatch
    path: root.watchPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handleExternalContent(String(text()))
    onLoadFailed: function(error) {
      // The file vanished between the watch event and the read.
      if (root.loaded) root.markMissing()
    }
  }

  Component {
    id: saveFileComponent
    FileView {
      property string targetText: ""
      atomicWrites: true
      blockAllReads: true
      printErrors: false
      onSaved: root.bufferSaved(this)
      onSaveFailed: root.bufferFailed(this)
    }
  }

  Process {
    id: writeProcess
    property string savedText: ""
    stdout: StdioCollector { id: writeOut; waitForEnd: true }
    stderr: StdioCollector { id: writeError; waitForEnd: true }
    onExited: function(exitCode) {
      root.afterWrite(exitCode, String(writeError.text || ""))
    }
  }

  Process {
    id: discardProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: discardError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.draftPending = false
        root.draftText = ""
        root.draftModified = 0
        root.statusText = "Draft discarded"
      } else {
        var text = String(discardError.text || "").trim()
        try {
          var payload = JSON.parse(text)
          if (payload && payload.error) text = String(payload.error)
        } catch (error) { /* plain text error */ }
        root.statusText = "Could not discard draft" + (text !== "" ? ": " + text : "")
      }
    }
  }

  Process {
    id: previewProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || "{}"))
          root.previewMarkdown = result.tooLarge ? "" : String(result.markdown || "")
          root.previewLineOffset = result.tooLarge ? 0 : Number(result.lineOffset || 0)
        } catch (error) {
          root.previewMarkdown = ""
          root.previewLineOffset = 0
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Fire-and-forget queue notification; failures stay out of the status bar.
  Process {
    id: joplinNotifyProcess
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // A mode chip, copied from the library's header so the same three choices
  // look the same in both windows.
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

  FloatingWindow {
    id: window
    visible: true
    title: "Quill — " + root.noteTitle
    color: Commons.Color.background
    implicitWidth: Style.space(1080)
    implicitHeight: Style.space(720)
    minimumSize: Qt.size(Style.space(640), Style.space(460))
    onVisibleChanged: if (!visible) root.closeWindow()

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(8)

      Row {
        width: parent.width
        height: Style.space(48)
        spacing: Style.space(10)

        Column {
          width: parent.width - headerActions.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)
          Text {
            width: parent.width
            text: root.noteTitle
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: "Markdown note  ·  Ctrl+S saves  ·  Esc closes"
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
          }

          Text {
            id: status
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText
            textFormat: Text.PlainText
            color: root.saving || root.dirty
              ? Commons.Color.accent
              : Util.alpha(Commons.Color.foreground, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            objectName: "externalEditorButton"
            visible: root.noteId !== ""
            width: Style.space(24)
            height: Style.space(24)
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
            visible: root.noteId !== ""
            width: Style.space(23)
            height: Style.space(23)
            text: ""
            iconText: "\uf1da"
            iconSize: Style.font.bodySmall
            tooltipText: "Version history"
            horizontalPadding: 0
            verticalPadding: 0
            onClicked: {
              // A dirty buffer is saved first; restore is only enabled once the
              // write lands, and the dialog explains the wait.
              if (root.dirty && root.writesAllowed) root.save()
              // Qt drops a popup's parent on close, so re-attach it to the
              // overlay or the second open paints nothing.
              PopupAnchor.anchor(versionHistory, Overlay.overlay)
              versionHistory.openFor(root.noteId, root.noteTitle)
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Commons.Color.foreground, 0.14)
      }

      FormatBar {
        id: formatBar
        width: parent.width
        visible: !root.tooLarge && root.mode !== "preview"
        available: root.loaded && !root.tooLarge && !root.draftPending
        canUndo: editor ? editor.canUndo : false
        canRedo: editor ? editor.canRedo : false
        linkValue: editor ? editor.currentLinkURL() : ""
        onAction: function(name, value) {
          if (!editor) return
          if (name === "attach") editor.openAttachPicker()
          else if (name === "draw") editor.openDrawCanvas()
          else editor.applyFormat(name, value)
        }
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

      Row {
        width: parent.width
        height: parent.height - y
        spacing: Style.space(8)

        BorderSurface {
          id: editorPane
          visible: root.mode !== "preview"
          width: root.mode === "split" ? Math.floor((parent.width - parent.spacing) * 0.55) : parent.width
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.022)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          Flickable {
            id: editorScroll
            anchors.fill: parent
            anchors.margins: Style.space(8)
            clip: true
            contentWidth: width
            contentHeight: editor.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            function ensureVisible(rect) {
              if (contentY >= rect.y) contentY = rect.y
              else if (contentY + height <= rect.y + rect.height) contentY = rect.y + rect.height - height
            }

            // Qt's built-in wheel step is fixed, which is slow in a long note
            // and ignores how fast the wheel is spun. Scale each notch by how
            // quickly the notches arrive: a hard spin covers ground, a single
            // deliberate roll stays precise.
            property var wheelState: WheelScroll.create()

            WheelHandler {
              onWheel: function(event) {
                var step = WheelScroll.step(editorScroll.wheelState,
                  event.angleDelta.y, event.pixelDelta.y, Date.now())
                if (step === 0) return
                editorScroll.contentY = Math.max(0, Math.min(
                  editorScroll.contentHeight - editorScroll.height,
                  editorScroll.contentY - step))
                event.accepted = true
              }
            }

            MarkdownEditor {
              id: editor
              objectName: "markdownEditor"
              width: editorScroll.width
              height: Math.max(editorScroll.height, implicitHeight)
              storePath: root.storePath
              documentKey: String(root.noteId || "")
              enabled: root.loaded && !root.tooLarge && !root.draftPending && !root.noteMissing
              selectByMouse: true
              wrapMode: TextEdit.Wrap
              onCursorRectangleChanged: editorScroll.ensureVisible(cursorRectangle)
              foregroundColor: Commons.Color.foreground
              accentColor: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              topPadding: Style.space(8)
              bottomPadding: Style.space(24)
              placeholderText: root.loading
                ? "Loading note…"
                : root.noteMissing
                  ? "This note is no longer in notes/."
                  : root.tooLarge
                    ? "This note is too large to edit safely in Quill."
                    : "Start writing Markdown…"
              placeholderTextColor: Util.alpha(Commons.Color.foreground, 0.28)
              onTextChanged: root.markDirty()
              onLinkRequested: formatBar.openLinkPopover()
              onNoteLinkRequested: formatBar.openNoteLink()
              onFormatRejected: function(message) { root.statusText = message }
              onImagePasted: function(path) { root.statusText = "Image added" }
              onPasteFailed: function(message) { root.statusText = message }
              onAttachmentAdded: function(path) { root.statusText = "File attached" }
              onAttachFailed: function(message) { root.statusText = message }
            }
          }
        }

        BorderSurface {
          id: previewPane
          visible: root.mode !== "edit"
          width: root.mode === "split" ? parent.width - editorPane.width - parent.spacing : parent.width
          height: parent.height
          color: Util.alpha(Commons.Color.foreground, 0.014)
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          PreviewPane {
            anchors.fill: parent
            anchors.margins: Style.space(4)
            markdown: root.previewMarkdown
            loading: root.loading
            dirty: root.dirty
            hasNote: root.loaded
            tooLarge: root.tooLarge
            editable: root.loaded && !root.tooLarge && !root.draftPending
            tableEditing: false
            lineOffset: root.previewLineOffset
            onLinkActivated: function(link) { root.openLink(link) }
            onImageResized: function(line, width) { root.setImageWidth(line, width) }
            onImageReset: function(line) { root.clearImageSize(line) }
            onTaskToggled: function(line) { root.toggleTaskAt(line) }
          }
        }
      }

      VersionHistory {
        id: versionHistory
        storePath: root.storePath
        canRestore: root.loaded && !root.dirty && !root.saving && root.writesAllowed
        onRestored: function(id) {
          root.loadNote()
          root.statusText = "Restored version"
        }
      }
    }

    Shortcut { sequence: "Ctrl+S"; onActivated: root.save() }
    Shortcut { sequence: "Ctrl+Shift+O"; onActivated: root.openInEditor() }
    Shortcut {
      sequence: "Escape"
      enabled: !versionHistory.opened
      onActivated: window.visible = false
    }
  }
}
