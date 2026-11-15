import QtQuick
import Quickshell
import Quickshell.Io

// Drives the real Library through the save path: load a note, edit it, save it,
// then check that a save based on older text is refused and that "Keep mine"
// writes ours. Runs inside scripts/qmltest's offscreen harness with a temp data
// root, so a regression fails the suite instead of shipping.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""

  readonly property string editedText: "# Save harness\n\nedited by the library\n"
  readonly property string mineText: "# Save harness\n\nmine, after the conflict\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false
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
      width: 1000,
      height: 700
    })
    if (!library) {
      h.check("the library can be created", false)
      h.done()
      return
    }
    step = 1
    tick.start()
  }

  function fail(message) {
    harness.check("save harness completed", false, message)
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
      // The library loads its settings and note list asynchronously, and
      // selecting an id before its row exists clears the editor without a
      // retry. Wait for both, nudging the list once if it never arrives.
      if (!library.settingsLoaded) return
      if (!test.hasNote()) {
        if (!test.refreshed && ticks > 20) {
          test.refreshed = true
          library.refreshAll()
        }
        return
      }
      library.selectNote(test.noteId)
      step = 2
      return
    }

    if (step === 2) {
      if (!library.loaded || String(library.selectedId) !== noteId) return
      editor = findByName(library, "markdownEditor")
      if (!editor) return fail("the editor is not in the library")
      editor.text = editedText
      editor.cursorPosition = editor.text.length
      step = 3
      return
    }

    if (step === 3) {
      if (!library.dirty) return
      library.flushSave()
      step = 4
      return
    }

    if (step === 4) {
      if (String(library.saveState).indexOf("Saved") !== 0 || library.dirty) return
      readDisk(function() {
        harness.check("a save from the library reaches the disk",
          test.diskText === test.editedText,
          JSON.stringify(test.diskText))
        harness.check("the save leaves the note clean",
          !test.library.dirty && String(test.library.saveState).indexOf("Saved") === 0,
          String(test.library.saveState))
        // Pretend this window is working from text that predates the file.
        test.library.loadedModified = 1
        test.editor.text = test.mineText
        test.step = 5
      })
      step = 6
      return
    }

    if (step === 5) {
      if (!library.dirty) return
      library.flushSave(true)
      step = 7
      return
    }

    if (step === 7) {
      if (!library.diskChangePending) return
      readDisk(function() {
        harness.check("a save based on older text is refused",
          test.diskText === test.editedText,
          JSON.stringify(test.diskText))
        harness.check("the refusal is reported as a conflict",
          String(test.library.lastErrorCode) === "stale"
            && /changed on disk/i.test(String(test.library.statusText)),
          String(test.library.lastErrorCode) + " / " + String(test.library.statusText))
        test.library.keepDiskChange()
        test.step = 8
      })
      step = 9
      return
    }

    if (step === 8) {
      if (library.dirty && String(library.saveState) === "Saving…") return
      if (library.dirty) return
      readDisk(function() {
        harness.check("\"Keep mine\" writes this window's version",
          test.diskText === test.mineText,
          JSON.stringify(test.diskText))
        test.harness.done()
      })
      step = 10
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
