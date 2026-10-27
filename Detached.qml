import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ImageSizing.js" as ImageSizing
import "MarkdownFormat.js" as MarkdownFormat
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
      tooLarge = true
      loaded = false
      statusText = String(errorText || "").trim() || "Could not read this note"
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
    tooLarge = !!result.tooLarge
    editor.text = tooLarge ? "" : String(result.content || "")
    editor.cursorPosition = 0
    suppressDirty = false
    loaded = !tooLarge
    dirty = false
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

  function save() {
    saveTimer.stop()
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
      statusText = "Could not prepare a save"
      return
    }
    view.targetText = editor.text
    view.setText(editor.text)
  }

  function bufferSaved(view) {
    var contentPath = view.path
    var savedText = view.targetText
    view.destroy()
    writeProcess.command = [storePath, "write", noteId, "--content-file", contentPath]
    writeProcess.savedText = savedText
    writeProcess.running = true
  }

  function bufferFailed(view) {
    view.destroy()
    saving = false
    dirty = true
    statusText = "Could not write the note"
    quitAfterSave = false
  }

  function afterWrite(exitCode, errorText) {
    saving = false
    if (exitCode !== 0) {
      dirty = true
      statusText = String(errorText || "").trim() || "Save failed"
      quitAfterSave = false
      saveTimer.restart()
      return
    }
    savedOnce = true
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
    if (quitAfterSave) Qt.quit()
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
    stdout: StdioCollector { waitForEnd: true }
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
          width: parent.width - status.width - parent.spacing
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
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Commons.Color.foreground, 0.14)
      }

      DraftBanner {
        width: parent.width
        visible: root.draftPending
        draftModified: root.draftModified
        onRecoverRequested: root.recoverDraft()
        onDiscardRequested: root.discardDraft()
      }

      Row {
        width: parent.width
        height: parent.height - y
        spacing: Style.space(8)

        BorderSurface {
          width: Math.floor((parent.width - parent.spacing) * 0.55)
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

            MarkdownEditor {
              id: editor
              width: editorScroll.width
              height: Math.max(editorScroll.height, implicitHeight)
              storePath: root.storePath
              enabled: root.loaded && !root.tooLarge && !root.draftPending
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
                : root.tooLarge
                  ? "This note is too large to edit safely in Quill."
                  : "Start writing Markdown…"
              placeholderTextColor: Util.alpha(Commons.Color.foreground, 0.28)
              onTextChanged: root.markDirty()
              onImagePasted: function(path) { root.statusText = "Image added" }
              onPasteFailed: function(message) { root.statusText = message }
            }
          }
        }

        BorderSurface {
          width: parent.width - x
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
            onLinkActivated: function(link) { Qt.openUrlExternally(link) }
            onImageResized: function(line, width) { root.setImageWidth(line, width) }
            onImageReset: function(line) { root.clearImageSize(line) }
            onTaskToggled: function(line) { root.toggleTaskAt(line) }
          }
        }
      }
    }

    Shortcut { sequence: "Ctrl+S"; onActivated: root.save() }
    Shortcut { sequence: "Escape"; onActivated: window.visible = false }
  }
}
