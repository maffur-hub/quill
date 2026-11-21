import QtQuick
import Quickshell
import Quickshell.Io

// A save that starts while another save of ours is still in flight must still
// name the mtime the in-flight write produced, or an external edit that lands
// between the two writes is silently overwritten. The store here is a shim
// wrapper: the first `write` puts its bytes on disk at once but holds its
// response for two seconds, which is exactly the window a real slow save
// leaves open. The second save is enqueued inside that window, the note file
// changes from outside, and the queued save must be refused as stale.
//
// Runs inside scripts/qmltest's offscreen harness with a temp data root. The
// shim sits beside the data root, next to a bridge stub that starts and dies
// at once: the Library disables the bridge after three such sessions (its own
// fallback path, see handleDaemonExit) and runs every job through the per-call
// spawned path with this shim as the store. A missing binary is not enough
// here: Quickshell never reports an exit for a command it could not spawn, so
// the bridge would stay "starting" forever.
Item {
  id: test

  property var harness: null
  property var library: null
  property var editor: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  // The real store, used only for reading the note back.
  property string storePath: harness ? String(harness.storePath) : ""
  readonly property string noteFile: dataRoot + "/notes/" + noteId

  // A directory beside `data/`, never inside the repo.
  readonly property string shimDir: {
    var cut = dataRoot.lastIndexOf("/")
    return (cut > 0 ? dataRoot.slice(0, cut) : dataRoot) + "/shim"
  }
  readonly property string shimPath: shimDir + "/store"
  readonly property string shimMark: shimDir + "/.first-write-done"
  readonly property string daemonStub: shimDir + "/quill-daemon"

  readonly property string firstText: "# Save harness\n\nfirst in-flight body\n"
  readonly property string queuedText: "# Save harness\n\nqueued second body\n"
  readonly property string externalText: "# Save harness\n\nexternal editor won this round\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false
  property bool shimReady: false
  property bool shimFailed: false
  property bool externalWritten: false
  property bool externalFailed: false
  property int flushTick: 0
  property int settleTick: -1
  property string diskText: ""
  property var afterRead: null

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

  // The first `write` runs the real store immediately (its bytes land on disk)
  // but its response is held for two seconds, so a second save queues behind
  // it and an external edit can land between the two writes. stdout, stderr
  // and the exit code are replayed faithfully: the spawned runner parses
  // stdout on success and the store's error JSON on stderr.
  function writeShim() {
    var script = "#!/usr/bin/env bash\n"
      + "# Wraps the real store: the first `write` runs immediately (its bytes land\n"
      + "# on disk) but its RESPONSE is held ~2s, so a second save queues behind it\n"
      + "# and an external edit can land between the two writes.\n"
      + "set -u\n"
      + "REAL=" + test.quoted(test.storePath) + "\n"
      + "MARK=" + test.quoted(test.shimMark) + "\n"
      + "if [[ \"${1:-}\" == \"write\" && ! -e \"$MARK\" ]]; then\n"
      + "  : > \"$MARK\"\n"
      + "  OUT=$(\"$REAL\" \"$@\" 2>\"$MARK.err\"); CODE=$?\n"
      + "  sleep 2\n"
      + "  printf '%s' \"$OUT\"\n"
      + "  cat \"$MARK.err\" >&2\n"
      + "  exit \"$CODE\"\n"
      + "fi\n"
      + "exec \"$REAL\" \"$@\"\n"
    // A bridge stub that starts and exits at once. The Library counts three of
    // those and disables the bridge, which is its own fallback to the spawned
    // runner. A command that cannot start at all would never report an exit,
    // so the first job would sit in "starting" forever.
    var stubScript = "#!/usr/bin/env bash\n"
      + "# Not a real bridge: force the spawned fallback.\n"
      + "exit 1\n"
    shimProcess.command = ["sh", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$3\" > \"$2\" && chmod +x \"$2\""
        + " && printf '%s' \"$5\" > \"$4\" && chmod +x \"$4\"",
      "quill", test.shimDir, test.shimPath, script, test.daemonStub, stubScript]
    shimProcess.running = true
  }

  function fail(message) {
    harness.check("in-flight save harness completed", false, message)
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
      "# Save harness", "", "external editor won this round", test.noteFile]
    writeProcess.running = true
  }

  // Reads go through the real store, bypassing the Library's queue.
  function readDisk(next) {
    afterRead = next
    diskText = ""
    readProcess.command = [test.storePath, "read", test.noteId]
    readProcess.running = true
  }

  function settled() {
    return library.inFlightSaveText === ""
      && String(library.saveState) !== "Saving…"
  }

  function advance() {
    ticks += 1
    if (ticks > 200) return fail("timed out in step " + step)

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
      step = 1
      return
    }

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
      editor.text = test.firstText
      editor.cursorPosition = editor.text.length
      step = 3
      return
    }

    if (step === 3) {
      if (!library.dirty) return
      flushTick = ticks
      library.flushSave()
      step = 4
      return
    }

    if (step === 4) {
      // The shim's two-second hold gives save 1's bytes time to reach the disk
      // while the library still believes a save is running. Confirm both
      // before queueing its sibling: if the first save already finished there
      // is no in-flight window and the case must fail loudly instead of
      // passing on the wrong scenario.
      if (ticks - flushTick < 8) return
      readDisk(function() {
        if (test.diskText !== test.firstText) {
          if (String(test.library.inFlightSaveText) !== test.firstText) {
            test.fail("the first save finished before its queued sibling; "
              + "the guard gate never dropped (state="
              + String(test.library.saveState) + ")")
            return
          }
          // The write has not landed yet. Keep polling inside the hold.
          test.step = 4
          return
        }
        test.harness.check("the first save is still in flight when the next save starts",
          String(test.library.inFlightSaveText) === test.firstText,
          "inFlight=" + String(test.library.inFlightSaveText)
            + " state=" + String(test.library.saveState))
        test.editor.text = test.queuedText
        test.step = 5
      })
      step = 40
      return
    }

    if (step === 5) {
      if (!library.dirty) return
      library.flushSave()
      step = 6
      return
    }

    if (step === 6) {
      // The in-flight marker is overwritten by the queued save: this is the
      // state that makes the gate drop the guard for it.
      harness.check("the queued save replaces the in-flight marker",
        String(library.inFlightSaveText) === test.queuedText,
        "inFlight=" + String(library.inFlightSaveText))
      test.writeExternal()
      step = 7
      return
    }

    if (step === 7) {
      if (!externalWritten) {
        if (externalFailed) return fail("the external write failed")
        return
      }
      // Save 1's held response arrives, then the queue runs the queued save.
      if (!test.settled()) {
        settleTick = -1
        return
      }
      if (settleTick < 0) settleTick = ticks
      if (ticks - settleTick < 4) return
      console.log("settle: diskState=" + String(library.saveState)
        + " dirty=" + library.dirty
        + " pending=" + library.diskChangePending
        + " inFlight=" + JSON.stringify(String(library.inFlightSaveText)))
      readDisk(function() {
        test.harness.check("an external edit between two queued saves is not overwritten",
          test.diskText === test.externalText, JSON.stringify(test.diskText))
        test.harness.check("the refused queued save raises the reload-or-keep banner",
          test.library.diskChangePending === true && test.library.dirty === true
            && String(test.library.saveState).indexOf("Saved") !== 0,
          "pending=" + test.library.diskChangePending
            + " dirty=" + test.library.dirty
            + " state=" + String(test.library.saveState))
        var keep = test.findByName(test.library, "externalKeepButton")
        if (!keep || !keep.visible) {
          test.harness.check("the change banner offers Keep mine", false,
            keep ? "not visible" : "missing")
          test.harness.done()
          return
        }
        test.harness.check("the change banner offers Keep mine", true)
        keep.clicked()
        test.step = 8
      })
      step = 70
      return
    }

    if (step === 8) {
      if (library.diskChangePending || library.dirty) return
      if (String(library.saveState).indexOf("Saved") !== 0) return
      if (!test.settled()) return
      readDisk(function() {
        test.harness.check("\"Keep mine\" writes the queued version over the external text",
          test.diskText === test.queuedText, JSON.stringify(test.diskText))
        test.harness.check("the conflict clears once our version is on disk",
          test.library.diskChangePending === false && test.library.dirty === false
            && String(test.library.saveState).indexOf("Saved") === 0,
          String(test.library.saveState))
        test.harness.done()
      })
      step = 80
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
