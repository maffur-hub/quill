import QtQuick
import Quickshell
import Quickshell.Io

// Contracts 3 and 4 for the detached window, which cannot be observed from
// inside the process because the close path itself calls Qt.quit():
//   3. closing the window (closeWindow) flushes a pending edit before quitting,
//      even when the 450 ms autosave debounce has not fired yet;
//   4. pressing Escape (window.visible = false -> closeWindow) does the same.
// Contract 5 (a stale component set is never loaded) is checked by
// scripts/qmltest's check_window_stage.
//
// Each sub-case writes a throwaway Quickshell stage, runs tests/qml/detached-driver.qml
// in a child `quickshell -p <stage>`, waits for it to exit, then reads the real
// store to see whether the edit survived. A hung child is killed by `timeout`,
// and a surviving quickshell is reported with its pid.
//
// A ShellRoot's window and editor are not reachable from outside through QML's
// object tree (its `children` is a QQmlListProperty the JS engine cannot walk,
// and ids are not exported). The staged copy of Detached.qml is therefore the
// real file plus one property, `testWindow: window`, so the driver can hide the
// window exactly as the Escape shortcut does. Everything else under test is
// the unmodified component, and the copy is generated from the plugin on every
// run, so a change to Detached.qml is always exercised.
Item {
  id: test

  property var harness: null
  property int step: 0
  property int ticks: 0
  property string childMode: ""
  property string childText: ""
  property string childErr: ""
  property string childOut: ""
  property bool childFailed: false
  property string diskText: ""
  property var afterRead: null

  property string noteId: Quickshell.env("QUILL_TEST_NOTE_ID") || ""
  property string dataRoot: harness ? String(harness.dataRoot) : ""
  property string storePath: harness ? String(harness.storePath) : ""
  property string shellRoot: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
  property string pluginDir: {
    var url = String(Qt.resolvedUrl("../../Detached.qml"))
    var slash = url.lastIndexOf("/")
    if (slash <= 0) return ""
    return decodeURIComponent(url.substring(7, slash))
  }
  property string driverPath: pluginDir + "/tests/qml/detached-driver.qml"
  property string stageDir: dataRoot + "/detached-child"

  function start(h) {
    harness = h
    if (!h || noteId === "" || dataRoot === "" || storePath === "") {
      h.check("harness has a note and a data root", false, "missing env")
      h.done()
      return
    }
    if (pluginDir === "") {
      h.check("the plugin path can be resolved", false, "no Detached.qml")
      h.done()
      return
    }
    // Escape first: it is the least destructive path, so a failure there is
    // reported before the close sub-case has a chance to hang.
    runChild("escape", "escaped edit")
    setStep(2)
    tick.start()
  }

  function setStep(value) {
    step = value
    ticks = 0
  }

  function fail(message) {
    tick.stop()
    harness.check("detached close harness completed", false, message)
    harness.done()
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function buildScript(mode, text) {
    var stage = [
      "set -u",
      "stage=" + shellQuote(stageDir),
      'rm -rf "$stage"',
      'mkdir -p "$stage/imports"',
      "ln -s " + shellQuote(shellRoot) + ' "$stage/imports/qs"',
      // Stage the plugin the way scripts/quill-window does (the copy loop plus
      // the shared links), then add the one test seam the Escape path needs:
      // Detached.qml's FloatingWindow id is not reachable from outside, so the
      // staged copy exposes it as testWindow. Everything else is the real file.
      "cp " + shellQuote(pluginDir) + "/*.qml " + shellQuote(pluginDir) + "/*.js \"$stage/\"",
      'rm -f "$stage/Detached.qml"',
      "sed '0,/^  id: root$/s//  id: root\\n  property var testWindow: window/' "
        + shellQuote(pluginDir + "/Detached.qml") + ' > "$stage/DetachedUnderTest.qml"',
      "ln -s " + shellQuote(shellRoot + "/Commons") + ' "$stage/Commons"',
      "ln -s " + shellQuote(shellRoot + "/Ui") + ' "$stage/Ui"',
      "ln -s " + shellQuote(pluginDir + "/scripts") + ' "$stage/scripts"',
      "ln -s " + shellQuote(pluginDir + "/vendor") + ' "$stage/vendor"',
      "cat > \"$stage/shell.qml\" <<'QML'",
      "import QtQuick",
      "import Quickshell",
      "",
      "ShellRoot {",
      "  Loader {",
      "    anchors.fill: parent",
      "    source: \"file://" + driverPath + "\"",
      "    onStatusChanged: {",
      "      if (status === Loader.Error) {",
      "        console.log(\"driver failed to load\")",
      "        Qt.exit(10)",
      "      }",
      "    }",
      "  }",
      "}",
      "QML"
    ].join("\n")
    // The environment assignments must share one command line with the
    // launch, so they are joined with spaces rather than newlines.
    var env = [
      "QUILL_NOTE_ID=" + shellQuote(noteId),
      "QUILL_DATA_DIR=" + shellQuote(dataRoot),
      "QUILL_TEST_DATA=" + shellQuote(dataRoot),
      "QUILL_STORE_PATH=" + shellQuote(storePath),
      "QUILL_E2E=1",
      'QML_IMPORT_PATH="$stage/imports"',
      "QT_QPA_PLATFORM=offscreen",
      "DRIVER_TEXT=" + shellQuote(text),
      "DRIVER_MODE=" + shellQuote(mode),
      'DRIVER_COMPONENT="$stage/DetachedUnderTest.qml"'
    ].join(" ")
    var tail = [
      'timeout 25 quickshell -n -p "$stage"',
      "code=$?",
      "sleep 0.2",
      // pgrep -f "$stage" would also match this script, whose argv contains
      // the stage path. Match the exact launch instead: the script only holds
      // the literal "$stage", never the resolved path on that line.
      'survivors=$(pgrep -f -- "quickshell -n -p $stage" || true)',
      '[ -z "$survivors" ] || echo "survivors: $survivors" >&2',
      'rm -rf "$stage"',
      'exit $code'
    ].join("\n")
    // The assignments must prefix the launch command on the same line: on a
    // line of their own they are shell variables, not exported to the child.
    return stage + "\n" + env + " " + tail + "\n"
  }

  function runChild(mode, text) {
    childMode = mode
    childText = text
    childErr = ""
    childOut = ""
    childFailed = false
    childProcess.command = ["sh", "-c", buildScript(mode, text)]
    childProcess.running = true
  }

  function label(mode) {
    return mode === "escape" ? "Escape" : "closing the window"
  }

  function readDisk(next) {
    afterRead = next
    diskText = ""
    readProcess.command = [storePath, "read", noteId]
    readProcess.running = true
  }

  function childExited(code) {
    childErr = trim(childProcess.errText)
    childOut = trim(childProcess.outText)
    var name = label(childMode)
    var detail = "exit " + code
    if (childErr !== "") detail += " / stderr: " + tail(childErr)
    // A driver that fails before the event loop starts cannot Qt.exit(), so
    // its reason is only on stdout when `timeout` finally kills it.
    if (code !== 0 && childOut !== "") detail += " / stdout: " + tail(childOut)
    harness.check(name + " exits the window cleanly", code === 0, detail)
    harness.check(name + " leaves no quickshell process behind",
      childErr.indexOf("survivors:") < 0,
      childErr.indexOf("survivors:") < 0 ? "" : tail(childErr))
    childFailed = code !== 0
    var expectedMode = childMode
    var expectedText = childText
    readDisk(function() {
      harness.check(name + " flushes the edit before the debounce",
        test.diskText.indexOf(expectedText) >= 0, JSON.stringify(test.diskText))
      if (test.childFailed) {
        tick.stop()
        test.harness.done()
        return
      }
      if (expectedMode === "escape") {
        test.runChild("close", "closed edit")
        test.setStep(4)
      } else {
        tick.stop()
        test.harness.done()
      }
    })
    setStep(childMode === "escape" ? 3 : 5)
  }

  function trim(value) {
    return String(value === undefined || value === null ? "" : value).trim()
  }

  function tail(value) {
    var text = trim(value).replace(/\n/g, " | ")
    return text.length > 600 ? text.substring(text.length - 600) : text
  }

  function advance() {
    ticks += 1
    if (ticks > 230) {
      return fail("timed out waiting for the " + label(childMode) + " child (step " + step + ")")
    }
    // Steps 2/4 and 3/5 wait for the child and the disk read; onExited and the
    // read callback drive the machine from here.
  }

  Timer {
    id: tick
    interval: 120
    repeat: true
    onTriggered: test.advance()
  }

  Process {
    id: childProcess
    property string outText: ""
    property string errText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: childProcess.outText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: childProcess.errText = String(text || "")
    }
    onExited: function(exitCode) { test.childExited(exitCode) }
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
