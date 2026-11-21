import QtQuick
import Quickshell
import Quickshell.Io

// The backend bridge is an executable beside the store. When it cannot exec at
// all, Quickshell fires neither onStarted nor onExited: it only logs a warning.
// Without a watchdog the first job sits in the pending slot forever, the note
// list never arrives and the window is silently useless. This case stages the
// true missing-binary shape: a store wrapper with no quill-daemon beside it.
//
// The library must give up on the bridge after its three strikes and run every
// command through the per-call spawned runner, which is what the save
// round-trip at the end proves. Runs inside scripts/qmltest's offscreen
// harness with a temp data root.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  // The real store, used only for reading the note back.
  property string storePath: harness ? String(harness.storePath) : ""

  // A directory beside `data/`, never inside the repo. No quill-daemon is ever
  // written here: the missing binary is the failure under test.
  readonly property string shimDir: {
    var cut = dataRoot.lastIndexOf("/")
    return (cut > 0 ? dataRoot.slice(0, cut) : dataRoot) + "/shim"
  }
  readonly property string shimPath: shimDir + "/quill-store"

  readonly property string ourText: "# Save harness\n\nsaved through the spawned fallback\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false
  property bool shimReady: false
  property bool shimFailed: false
  property int createTick: -1
  property int loadedTick: -1
  property int disabledTick: -1
  property string disabledStatus: ""
  property string diskText: ""
  property var afterRead: null

  // Three watchdog strikes (one every 3 s) are the expected worst case before
  // the bridge is disabled, so the failure diagnosis sits well past that and
  // the case's own cap leaves margin under the harness's 45 s hard cap.
  readonly property int wedgeDiagnosisTick: 150
  readonly property int settleCapTick: 220

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    test.writeShim()
    tick.start()
  }

  // Quote a path for the generated script. Paths come from the harness stage,
  // so only a defensive double-quote escape is needed.
  function quoted(value) {
    return "\"" + String(value).replace(/"/g, "\\\"") + "\""
  }

  // A passthrough store wrapper: the Library must find no quill-daemon beside
  // it, and every command that falls back to the spawned runner still reaches
  // the real store with unchanged argv, stdout/stderr and exit code.
  function writeShim() {
    var script = "#!/usr/bin/env bash\n"
      + "# Passthrough: the missing quill-daemon beside this file is the test.\n"
      + "set -u\n"
      + "REAL=" + test.quoted(test.storePath) + "\n"
      + "exec \"$REAL\" \"$@\"\n"
    shimProcess.command = ["sh", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$3\" > \"$2\" && chmod +x \"$2\"",
      "quill", test.shimDir, test.shimPath, script]
    shimProcess.running = true
  }

  function fail(message) {
    harness.check("daemon-missing harness completed", false, message)
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

  // Reads go through the real store, bypassing the Library's queue.
  function readDisk(next) {
    afterRead = next
    diskText = ""
    readProcess.command = [test.storePath, "read", test.noteId]
    readProcess.running = true
  }

  function advance() {
    ticks += 1
    if (ticks > settleCapTick) return fail("timed out in step " + step)

    // The disable transition is observable even while the queue is stuck, so
    // record when it happens and what it says. It can land during any wait.
    if (library && library.daemonDisabled && disabledTick < 0) {
      disabledTick = ticks
      disabledStatus = String(library.statusText)
      console.log("bridge disabled at tick " + disabledTick
        + " (" + (disabledTick - createTick) * 0.12 + " s), status="
        + JSON.stringify(disabledStatus))
    }

    if (step === 0) {
      if (!shimReady) {
        if (shimFailed) return fail("could not stage the shim store")
        return
      }
      var component = Qt.createComponent(Qt.resolvedUrl("../../Library.qml"))
      if (component.status === Component.Error) {
        return fail("the library cannot be created: " + component.errorString())
      }
      if (component.status !== Component.Ready) return
      library = component.createObject(test, {
        dataRoot: test.dataRoot,
        storePath: test.shimPath,
        joplinSyncPath: "",
        width: 1200,
        height: 700
      })
      if (!library) return fail("the library cannot be created")
      createTick = ticks
      step = 1
      return
    }

    if (step === 1) {
      if (!library.settingsLoaded) {
        if (ticks >= wedgeDiagnosisTick) {
          return fail("the library never loaded its settings; the backend queue is wedged"
            + " — no fallback (ticks=" + ticks
            + " daemonDisabled=" + library.daemonDisabled + ")")
        }
        return
      }
      loadedTick = ticks
      console.log("settings loaded at tick " + loadedTick
        + " (" + (loadedTick - createTick) * 0.12 + " s)")
      step = 2
      return
    }

    if (step === 2) {
      if (!test.hasNote()) {
        if (ticks >= wedgeDiagnosisTick) {
          return fail("the library never listed a note; the backend queue is wedged"
            + " — no fallback (ticks=" + ticks
            + " daemonDisabled=" + library.daemonDisabled + ")")
        }
        if (!test.refreshed && ticks > 20) {
          test.refreshed = true
          library.refreshAll()
        }
        return
      }
      library.selectNote(test.noteId)
      step = 3
      return
    }

    if (step === 3) {
      if (!library.loaded || String(library.selectedId) !== noteId) return
      editor = findByName(library, "markdownEditor")
      if (!editor) return fail("the editor is not in the library")
      editor.text = test.ourText
      editor.cursorPosition = editor.text.length
      step = 4
      return
    }

    if (step === 4) {
      if (!library.dirty) return
      library.flushSave()
      step = 5
      return
    }

    if (step === 5) {
      // The spawn-per-call runner has no bridge to wait for, so the save
      // settles as soon as the store process returns.
      if (String(library.inFlightSaveText) !== "") return
      if (String(library.saveState) === "Saving…") return
      readDisk(function() {
        test.harness.check("the missing bridge falls back to the spawned runner",
          test.library.daemonDisabled === true,
          "daemonDisabled=" + test.library.daemonDisabled
            + " disabledTick=" + test.disabledTick)
        test.harness.check("the fallback is surfaced in the status text",
          test.disabledStatus !== "",
          "disabledTick=" + test.disabledTick
            + " status=" + JSON.stringify(test.disabledStatus))
        test.harness.check("a save round-trips through the spawned fallback",
          test.diskText === test.ourText, JSON.stringify(test.diskText))
        test.harness.check("the save leaves the note clean",
          test.library.dirty === false
            && String(test.library.saveState).indexOf("Saved") === 0,
          "dirty=" + test.library.dirty
            + " state=" + String(test.library.saveState))
        test.harness.done()
      })
      step = 60
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
    id: shimProcess
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) test.shimReady = true
      else test.shimFailed = true
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
