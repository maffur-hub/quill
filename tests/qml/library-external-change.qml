import QtQuick
import Quickshell
import Quickshell.Io

// Drives the real Library through an external edit: with a dirty buffer, a
// change to the note file from outside must raise the change banner, and the
// autosave and a direct save must both refuse to overwrite the external text
// until "Keep mine" forces our version. The external write goes through the
// file, not the store, so the noteWatch FileView path is the one under test.
// Runs inside scripts/qmltest's offscreen harness with a temp data root.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""
  readonly property string noteFile: dataRoot + "/notes/" + noteId

  readonly property string mineText: "# Save harness\n\nmine, external-change case\n"
  readonly property string externalText: "# Save harness\n\nexternal change on disk\n"

  property int step: 1
  property int ticks: 0
  property bool refreshed: false
  property bool externalWritten: false
  property bool externalFailed: false
  property int conflictTick: 0
  property int flushTick: 0
  property string diskText: ""
  property var afterRead: null

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    var component = Qt.createComponent(Qt.resolvedUrl("../../Library.qml"))
    if (component.status === Component.Error) {
      h.check("the library can be created", false, component.errorString())
      h.done()
      return
    }
    if (component.status !== Component.Ready) {
      h.check("the library can be created", false, "component loading is async")
      h.done()
      return
    }
    library = component.createObject(test, {
      dataRoot: test.dataRoot,
      storePath: test.storePath,
      joplinSyncPath: "",
      width: 1200,
      height: 700
    })
    if (!library) {
      h.check("the library can be created", false)
      h.done()
      return
    }
    tick.start()
  }

  function fail(message) {
    harness.check("external-change harness completed", false, message)
    harness.done()
  }

  // Walk the object tree: popup contents live in `data`/`contentItem`, and
  // Loaders hold their item in `item`.
  function findByName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = []
    var i
    if (item.children) {
      for (i = 0; i < item.children.length; i++) kids.push(item.children[i])
    }
    try {
      if (item.data) {
        for (i = 0; i < item.data.length; i++) kids.push(item.data[i])
      }
    } catch (error) {}
    if (item.contentItem) kids.push(item.contentItem)
    if (item.item) kids.push(item.item)
    for (i = 0; i < kids.length; i++) {
      var hit = test.findByName(kids[i], name)
      if (hit) return hit
    }
    return null
  }

  function hasNote() {
    var list = test.library ? (test.library.notes || []) : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id) === test.noteId) return true
    }
    return false
  }

  // An editor outside Quill: write the file directly, never through the store.
  function writeExternal() {
    writeProcess.command = ["sh", "-c",
      "printf '%s\\n' \"$1\" \"$2\" \"$3\" > \"$4\"", "quill",
      "# Save harness", "", "external change on disk", test.noteFile]
    writeProcess.running = true
  }

  function readDisk(next) {
    afterRead = next
    diskText = ""
    readProcess.command = [test.storePath, "read", test.noteId]
    readProcess.running = true
  }

  function advance() {
    ticks += 1
    if (ticks > 90) return fail("timed out in step " + step)

    if (step === 1) {
      // The library loads its settings and note list asynchronously, and it
      // selects the first note by itself. Wait for both, nudging the list
      // once if it never arrives.
      if (!library.settingsLoaded) return
      if (!test.hasNote()) {
        if (!test.refreshed && ticks > 20) {
          test.refreshed = true
          library.refreshAll()
        }
        return
      }
      if (String(library.selectedId) !== noteId) {
        library.selectNote(test.noteId)
      } else if (!library.loaded && !library.loadingNote) {
        library.loadNote()
      }
      step = 2
      return
    }

    if (step === 2) {
      if (!library.loaded || String(library.selectedId) !== noteId) return
      editor = findByName(library, "markdownEditor")
      if (!editor) return fail("the editor is not in the library")
      editor.text = test.mineText
      editor.cursorPosition = editor.text.length
      step = 3
      return
    }

    if (step === 3) {
      // The buffer must be dirty before the file changes, otherwise the
      // library adopts the external text silently instead of asking.
      if (!library.dirty) return
      if (!externalWritten && !externalFailed) test.writeExternal()
      if (externalFailed) return fail("the external write failed")
      step = 4
      return
    }

    if (step === 4) {
      // The watcher's 250 ms debounce plus the store-notifying reload. The
      // external body differs from the buffer, so the difference is a
      // conflict, not an adoption.
      if (!externalWritten) return
      if (!library.diskChangePending) return
      var banner = findByName(library, "externalChangeBanner")
      harness.check("an external write raises the change banner",
        !!banner && banner.visible === true,
        "pending=" + library.diskChangePending
          + " visible=" + (banner ? banner.visible : "missing"))
      harness.check("the conflict keeps the buffer dirty",
        library.dirty === true, "dirty=" + library.dirty)
      conflictTick = ticks
      step = 5
      return
    }

    if (step === 5) {
      // Give the 600 ms autosave every chance to slip in: it must not.
      if (ticks - conflictTick < 10) return
      readDisk(function() {
        harness.check("the autosave does not overwrite the external text",
          test.diskText === test.externalText, JSON.stringify(test.diskText))
        harness.check("the buffer stays dirty while the change is unresolved",
          test.library.dirty === true && test.library.diskChangePending === true,
          "dirty=" + test.library.dirty + " pending=" + test.library.diskChangePending)
        // No force: the same refusal a toolbar save or the autosave gets.
        test.library.flushSave()
        test.flushTick = test.ticks
        test.step = 6
      })
      step = 50
      return
    }

    if (step === 6) {
      if (ticks - flushTick < 3) return
      harness.check("a direct save is refused while the change is unresolved",
        /changed on disk/i.test(String(library.statusText))
          && library.dirty === true
          && String(library.saveState).indexOf("Saved") !== 0,
        String(library.statusText) + " / " + String(library.saveState))
      readDisk(function() {
        harness.check("the refused save left the external text on disk",
          test.diskText === test.externalText, JSON.stringify(test.diskText))
        var keep = test.findByName(test.library, "externalKeepButton")
        if (!keep) test.fail("the change banner has no Keep button")
        else keep.clicked()
        test.step = 7
      })
      step = 60
      return
    }

    if (step === 7) {
      if (library.diskChangePending || library.dirty) return
      if (String(library.saveState).indexOf("Saved") !== 0) return
      readDisk(function() {
        harness.check("\"Keep mine\" writes our version over the external text",
          test.diskText === test.mineText, JSON.stringify(test.diskText))
        harness.check("the conflict clears once our version is on disk",
          test.library.diskChangePending === false && test.library.dirty === false
            && String(test.library.saveState).indexOf("Saved") === 0,
          String(test.library.saveState))
        test.harness.done()
      })
      step = 70
      return
    }
  }

  Timer {
    id: tick
    interval: 120
    repeat: true
    onTriggered: test.advance()
  }

  Process {
    id: writeProcess
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) test.externalFailed = true
      else test.externalWritten = true
    }
  }

  Process {
    id: readProcess
    property string outText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: readProcess.outText = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var payload = {}
      try {
        payload = JSON.parse(readProcess.outText)
      } catch (error) {
        payload = {}
      }
      if (exitCode !== 0 || payload.content === undefined) {
        test.fail("could not read the note back: " + readProcess.outText)
        return
      }
      test.diskText = String(payload.content)
      if (test.afterRead) {
        var next = test.afterRead
        test.afterRead = null
        next()
      }
    }
  }
}
