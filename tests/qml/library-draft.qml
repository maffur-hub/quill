import QtQuick
import Quickshell
import Quickshell.Io

// Drives the real Library through crash-draft recovery: a draft left beside a
// note must be offered as a banner, and pressing Recover must put it in the
// buffer and write it through the ordinary save path, which removes the draft.
// The draft is staged before the library is created, so the first read of the
// note already carries it. Runs inside scripts/qmltest's offscreen harness
// with a temp data root, so a regression fails the suite instead of shipping.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""

  readonly property string draftText: "# Save harness\n\ndraft recovered text\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false
  property bool writeStarted: false
  property bool draftWritten: false
  property bool writeFailed: false
  property bool recoveredInBuffer: false
  property bool probeDone: false
  property bool draftExists: true
  property string diskText: ""
  property var afterRead: null

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    tick.start()
  }

  function fail(message) {
    harness.check("draft harness completed", false, message)
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

  // The draft sits beside the note and is named after the note file, exactly
  // where the store looks for one (`<note>.md.draft`).
  function draftFile() {
    return test.dataRoot + "/notes/" + test.noteId + ".draft"
  }

  // Staged with a shell write before the library exists: the very first read
  // of the note must already see a differing draft.
  function stageDraft() {
    writeStarted = true
    writeProcess.command = ["sh", "-c",
      "printf '%s\\n' \"$1\" \"$2\" \"$3\" > \"$4\"", "quill",
      "# Save harness", "", "draft recovered text", test.draftFile()]
    writeProcess.running = true
  }

  function buildLibrary() {
    var component = Qt.createComponent(Qt.resolvedUrl("../../Library.qml"))
    if (component.status === Component.Error) {
      return fail("the library could not be created: " + component.errorString())
    }
    if (component.status !== Component.Ready) {
      return fail("the library can be created, but component loading is async")
    }
    library = component.createObject(test, {
      dataRoot: test.dataRoot,
      storePath: test.storePath,
      joplinSyncPath: "",
      width: 1200,
      height: 700
    })
    if (!library) return fail("the library could not be created")
    step = 1
  }

  function probeDraft() {
    probeProcess.command = ["sh", "-c",
      "test -f \"$1\" && echo yes || echo no", "quill", test.draftFile()]
    probeProcess.running = true
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

    if (step === 0) {
      if (!writeStarted) test.stageDraft()
      if (writeFailed) return fail("the draft could not be staged")
      if (!draftWritten) return
      test.buildLibrary()
      return
    }

    if (step === 1) {
      // The library loads its settings and note list asynchronously, and it
      // selects the first note by itself. Wait for the list, then make sure
      // the seeded note is the one being read.
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
      if (!library.draftPending) return
      editor = findByName(library, "markdownEditor")
      if (!editor) return fail("the editor is not in the library")
      var banner = findByName(library, "draftBanner")
      harness.check("a staged draft opens with the recovery banner",
        !!banner && banner.visible && String(library.saveState) === "Draft found",
        "visible=" + (banner ? banner.visible : "missing") + " state=" + String(library.saveState))
      harness.check("the draft text is offered without touching the note",
        String(library.draftText) === test.draftText,
        JSON.stringify(String(library.draftText)))
      harness.check("the editor is read-only while the draft is pending",
        editor.readOnly === true && editor.enabled === false,
        "readOnly=" + (!!editor.readOnly) + " enabled=" + (!!editor.enabled))
      var recover = findByName(library, "draftRecoverButton")
      if (!recover) return fail("the draft banner has no Recover button")
      // The pressed signal, not a direct recoverDraft() call: this is the
      // banner's own wiring.
      recover.clicked()
      step = 3
      return
    }

    if (step === 3) {
      if (!recoveredInBuffer) {
        if (String(editor.text).indexOf("draft recovered text") < 0) return
        recoveredInBuffer = true
        harness.check("Recover puts the draft text in the buffer",
          String(editor.text) === test.draftText, JSON.stringify(String(editor.text)))
      }
      // recoverDraft() marks the buffer dirty and saves immediately, so wait
      // for that write to settle rather than for a dirty state that may be
      // gone within the same tick.
      if (String(library.saveState).indexOf("Saved") !== 0 || library.dirty) return
      harness.check("Recover saves through the normal write path",
        library.dirty === false && String(library.saveState).indexOf("Saved") === 0,
        String(library.saveState))
      readDisk(function() {
        harness.check("the saved note carries the draft text",
          test.diskText === test.draftText, JSON.stringify(test.diskText))
        test.probeDraft()
        test.step = 40
      })
      step = 41
      return
    }

    if (step === 40) {
      if (!probeDone) return
      harness.check("the recovered draft file is gone",
        draftExists === false, "exists=" + draftExists)
      harness.done()
      step = 42
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
      if (exitCode !== 0) test.writeFailed = true
      else test.draftWritten = true
    }
  }

  Process {
    id: probeProcess
    property string outText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: probeProcess.outText = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      test.draftExists = String(probeProcess.outText).trim() === "yes"
      test.probeDone = true
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
