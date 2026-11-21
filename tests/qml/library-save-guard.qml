import QtQuick
import Quickshell
import Quickshell.Io

// The ordinary save path must name the mtime it was based on on the command
// line, or an external edit that lands while our save is being prepared is
// silently overwritten. The check is on the argv itself, not just the result:
// a guard that survives serialisation only as a truncated 32-bit value is
// dropped by the `> 0` gate and the write lands unguarded.
//
// Runs inside scripts/qmltest's offscreen harness with a temp data root. The
// store here is a shim wrapper: every invocation's argv is logged, and a
// `write` is held for two seconds before the real store runs, which is exactly
// the window an external edit needs. A bridge stub that starts and dies at
// once makes the Library disable its bridge after three sessions (see
// handleDaemonExit) and run every job through the per-call spawned path with
// this shim. A missing binary is not enough: Quickshell never reports an exit
// for a command it could not spawn.
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
  readonly property string shimPath: shimDir + "/quill-store"
  readonly property string argvLog: shimDir + "/argv.log"
  readonly property string daemonStub: shimDir + "/quill-daemon"

  readonly property string ourText: "# Save guard\n\nour text before the clash\n"
  readonly property string externalText: "# Save guard\n\nexternal editor won this round\n"

  property int step: 0
  property int ticks: 0
  property bool refreshed: false
  property bool shimReady: false
  property bool shimFailed: false
  property bool externalWritten: false
  property bool externalFailed: false
  property int flushTick: 0
  property int settleTick: -1
  property int keepSettleTick: -1
  property string diskText: ""
  property double diskModified: 0
  property double expectedModified: 0
  property string argvText: ""
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

  // Every invocation's argv is appended to the log as one line. A `write` is
  // held for two seconds before the real store runs, so an external edit can
  // land between the save being prepared and the store's actual write. stdout,
  // stderr and the exit code all still come from the real store.
  function writeShim() {
    var script = "#!/usr/bin/env bash\n"
      + "# Wraps the real store: log the argv, hold a write for two seconds.\n"
      + "set -u\n"
      + "REAL=" + test.quoted(test.storePath) + "\n"
      + "LOG=" + test.quoted(test.argvLog) + "\n"
      + "printf '%s\\n' \"$*\" >> \"$LOG\"\n"
      + "if [[ \"${1:-}\" == \"write\" ]]; then sleep 2; fi\n"
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
    harness.check("save guard harness completed", false, message)
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
      "# Save guard", "", "external editor won this round", test.noteFile]
    writeProcess.running = true
  }

  // Reads go through the real store, bypassing the Library's queue.
  function readDisk(next) {
    afterRead = next
    diskText = ""
    diskModified = 0
    readProcess.command = [test.storePath, "read", test.noteId]
    readProcess.running = true
  }

  // The shim's log, read back through cat so the check sees the bytes the
  // store was actually invoked with.
  function readArgv() {
    if (logProcess.running) return
    argvText = ""
    logProcess.command = ["sh", "-c", "cat \"$1\" 2>/dev/null || true",
      "quill", test.argvLog]
    logProcess.running = true
  }

  // The line the spawned runner issued for this note's write, or "".
  function writeLine() {
    var lines = String(test.argvText).split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("write " + test.noteId + " ") === 0) return lines[i]
    }
    return ""
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
      // The real mtime the next save must name. Read through the real store so
      // the expectation does not depend on anything the Library computed.
      readDisk(function() {
        if (test.diskModified <= 0) {
          test.fail("the real store returned no mtime")
          return
        }
        test.expectedModified = Number(test.diskModified)
        test.editor.text = test.ourText
        test.editor.cursorPosition = test.editor.text.length
        test.step = 3
      })
      step = 20
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
      // The save must actually be running, or the case would be testing a
      // different scenario. inFlightSaveText is set when the buffer file is
      // written, before the store is spawned.
      if (String(library.inFlightSaveText) !== ourText) {
        if (ticks - flushTick > 6) {
          return fail("the save never started; the clash window never opened (state="
            + String(library.saveState) + ")")
        }
        return
      }
      if (ticks - flushTick < 2) return
      // Wait until the store has really been invoked: its argv line is logged
      // before the two-second hold, so the external edit below definitely
      // lands between the save being prepared and the store's write.
      if (writeLine() === "") {
        readArgv()
        return
      }
      if (String(library.inFlightSaveText) !== ourText) {
        return fail("the save finished before the external edit could land")
      }
      test.writeExternal()
      step = 5
      return
    }

    if (step === 5) {
      if (!externalWritten) {
        if (externalFailed) return fail("the external write failed")
        return
      }
      // The shim's two-second hold, then the watcher's 250 ms debounce.
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
      readArgv()
      step = 6
      return
    }

    if (step === 6) {
      var line = writeLine()
      if (line === "") {
        if (logProcess.running) return
        return fail("the store was never invoked with a write for this note")
      }
      // CHECK A: the argv itself names the version, at full precision.
      console.log("write argv: " + line)
      harness.check("the save's argv names the mtime it was based on",
        line.indexOf("--if-mtime") !== -1
          && line.indexOf(String(Math.round(expectedModified))) !== -1,
        JSON.stringify(line))
      readDisk(function() {
        // CHECK B: the stale write was refused, so the external text is intact.
        test.harness.check("the external edit is not overwritten",
          test.diskText === test.externalText, JSON.stringify(test.diskText))
        // CHECK C: the refusal surfaces the reload-or-keep conflict.
        test.harness.check("the refused save raises the reload-or-keep conflict",
          test.library.diskChangePending === true && test.library.dirty === true
            && String(test.library.saveState) === "Conflict",
          "pending=" + test.library.diskChangePending
            + " dirty=" + test.library.dirty
            + " state=" + String(test.library.saveState))
        if (!test.library.diskChangePending) {
          // No banner to press: the earlier checks already carry the failure.
          console.log("keep leg skipped: no conflict banner")
          test.harness.done()
          return
        }
        var keep = test.findByName(test.library, "externalKeepButton")
        if (!keep || !keep.visible) {
          test.harness.check("the change banner offers Keep mine", false,
            keep ? "not visible" : "missing")
          test.harness.done()
          return
        }
        test.harness.check("the change banner offers Keep mine", true)
        keep.clicked()
        test.step = 7
      })
      step = 60
      return
    }

    if (step === 7) {
      // "Keep mine" is deliberately unguarded, so this write pays the shim's
      // two-second hold too.
      if (library.diskChangePending || library.dirty) {
        keepSettleTick = -1
        return
      }
      if (String(library.saveState).indexOf("Saved") !== 0) return
      if (!test.settled()) {
        keepSettleTick = -1
        return
      }
      if (keepSettleTick < 0) keepSettleTick = ticks
      if (ticks - keepSettleTick < 4) return
      readDisk(function() {
        test.harness.check("\"Keep mine\" writes our version over the external text",
          test.diskText === test.ourText, JSON.stringify(test.diskText))
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
    id: logProcess
    property string outText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: logProcess.outText = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      test.argvText = logProcess.outText
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
      test.diskModified = Number(payload.modified || 0)
      if (test.afterRead) {
        var next = test.afterRead
        test.afterRead = null
        next()
      }
    }
  }
}
