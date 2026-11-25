import QtQuick
import Quickshell
import Quickshell.Io

// Contracts this file proves for the detached window's save path:
//   1. an edit marks the window dirty and the 450 ms autosave debounce writes
//      it to the store without any explicit save;
//   2. Ctrl+S (bound to root.save()) writes at once and does not wedge the
//      next save.
// The edit goes through Detached.qml's own replaceEditorLine(), the in-place
// path the editor's commands use: it rewrites the buffer and fires the real
// onTextChanged -> markDirty chain. (The editor object itself is not reachable
// from outside: Detached is a ShellRoot whose `children` is a QQmlListProperty
// the JS engine cannot walk, and ids are not exported as properties.)
// The two contracts that cannot be observed in-process — closing the window
// and pressing Escape both flush before the process quits — live in
// detached-close.qml, because the close path ends the process. Contract 5 (a
// stale component set is never loaded) is checked by scripts/qmltest's
// check_window_stage.
//
// Runs inside scripts/qmltest's offscreen harness against a temp data root.
Item {
  id: test

  property var harness: null
  property var win: null
  property int step: 0
  property int ticks: 0
  property string diskText: ""
  property var afterRead: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    createWindow()
    setStep(1)
    tick.start()
  }

  function setStep(value) {
    step = value
    ticks = 0
  }

  function fail(message) {
    tick.stop()
    harness.check("detached save harness completed", false, message)
    harness.done()
  }

  function createWindow() {
    var component = Qt.createComponent(Qt.resolvedUrl("../../Detached.qml"))
    if (component.status === Component.Error) {
      return fail("the detached window does not load: " + component.errorString())
    }
    if (component.status !== Component.Ready) {
      return fail("the detached component loaded asynchronously")
    }
    win = component.createObject(test, {})
    if (!win) return fail("the detached window could not be created")
  }

  // Detached is a ShellRoot: its declared children live in a
  // QQmlListProperty that the JS engine cannot walk (`children.length` throws
  // "List doesn't define a Count function"), and QML ids are not exported as
  // properties, so the editor object is unreachable from outside. Drive the
  // edit through the component's own in-place path instead:
  // replaceEditorLine() rewrites the editor through remove/insert, which fires
  // the real onTextChanged -> markDirty debounce, exactly like typing.
  function editLine(index, text) {
    return win ? win.replaceEditorLine(index, text) : false
  }

  function readDisk(next) {
    afterRead = next
    diskText = ""
    readProcess.command = [storePath, "read", noteId]
    readProcess.running = true
  }

  function advance() {
    ticks += 1
    if (ticks > 100) return fail("timed out in step " + step + " (" + String(win ? win.statusText : "") + ")")

    if (step === 1) {
      if (!win.loaded) {
        if (win.tooLarge) return fail("the window refused the seeded note: " + String(win.statusText))
        return
      }
      harness.check("the detached window loads the seeded note",
        win.loaded && !win.tooLarge && !win.dirty, String(win.statusText))
      // The seeded note is "# Save harness\n\noriginal body\n".
      var changed = editLine(2, "edited one")
      harness.check("editing rewrites the buffer", changed === true)
      harness.check("editing marks the detached window dirty", win.dirty === true,
        "dirty=" + win.dirty)
      setStep(2)
      return
    }

    if (step === 2) {
      // The 450 ms autosave timer restarts on the edit; wait for the store
      // write it triggers to clear dirty.
      if (win.dirty) return
      harness.check("the autosave debounce fires and clears dirty", win.dirty === false,
        String(win.statusText))
      readDisk(function() {
        harness.check("autosave writes the edit to disk",
          test.diskText.indexOf("edited one") >= 0, JSON.stringify(test.diskText))
        test.win.destroy()
        test.win = null
        test.createWindow()
        test.setStep(4)
      })
      setStep(3)
      return
    }

    if (step === 3) return // waiting for the disk read

    if (step === 4) {
      if (!win.loaded) {
        if (win.tooLarge) return fail("the second window refused the seeded note")
        return
      }
      if (!editLine(2, "edited two")) return fail("the second window refused the edit")
      // The Ctrl+S shortcut is bound to exactly this call; do it before the
      // 450 ms timer has any chance to fire.
      win.save()
      harness.check("Ctrl+S starts a save immediately",
        win.saveSeq === 1 && win.saving === true,
        "saveSeq=" + win.saveSeq + " saving=" + win.saving)
      setStep(5)
      return
    }

    if (step === 5) {
      if (win.dirty) return
      readDisk(function() {
        harness.check("the immediate save reaches the disk",
          test.diskText.indexOf("edited two") >= 0, JSON.stringify(test.diskText))
        if (!test.editLine(2, "edited three")) return test.fail("the buffer refused the second edit")
        test.win.save()
        test.setStep(7)
      })
      setStep(6)
      return
    }

    if (step === 6) return // waiting for the disk read

    if (step === 7) {
      if (win.dirty) return
      readDisk(function() {
        harness.check("a save does not wedge the next immediate save",
          test.win.saveSeq >= 2 && test.win.saving === false,
          "saveSeq=" + test.win.saveSeq + " saving=" + test.win.saving)
        harness.check("the second immediate save reaches the disk",
          test.diskText.indexOf("edited three") >= 0, JSON.stringify(test.diskText))
        test.win.destroy()
        test.win = null
        tick.stop()
        test.harness.done()
      })
      setStep(8)
      return
    }

    if (step === 8) return // waiting for the disk read
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
