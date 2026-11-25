import QtQuick
import Quickshell

// Out-of-process driver for the close/Escape contracts. scripts/qmltest's
// detached-close case writes a child stage whose ShellRoot loads this file,
// then runs `quickshell -n -p <stage>`. This driver opens Detached.qml, edits
// the buffer and invokes the real exit path:
//   DRIVER_MODE=close   -> win.closeWindow()       (the title-bar close)
//   DRIVER_MODE=escape  -> the FloatingWindow hidden, which is what the Escape
//                          shortcut does (onVisibleChanged -> closeWindow)
// The escape path needs a handle on the FloatingWindow, which QML does not
// expose from outside a ShellRoot, so DRIVER_COMPONENT points at a staged copy
// of Detached.qml whose only difference is a `testWindow: window` property.
// It deliberately never quits itself: if the component's own quit path does
// not end the process, the parent's timeout catches it. Every failure exits a
// distinct non-zero code with a reason on stdout, which the parent reports.
Item {
  id: driver

  property var component: null
  property var win: null
  property int ticks: 0
  property bool typed: false

  readonly property string mode: Quickshell.env("DRIVER_MODE") || ""
  readonly property string text: Quickshell.env("DRIVER_TEXT") || ""
  // The child stage hosts an instrumented copy of Detached.qml: identical to
  // the real file plus one property exposing the FloatingWindow id, because a
  // ShellRoot's windows are not reachable through QML's object tree from
  // outside. DRIVER_COMPONENT points at that copy.
  readonly property string componentPath: Quickshell.env("DRIVER_COMPONENT") || ""

  function fail(code, reason) {
    console.log("driver: " + reason)
    Qt.exit(code)
  }

  // Detached is a ShellRoot: its declared children live in a QQmlListProperty
  // the JS engine cannot walk, and QML ids are not exported, so the editor is
  // unreachable. replaceEditorLine() is the component's own in-place edit
  // path: it rewrites the editor text through remove/insert, which fires the
  // real onTextChanged -> markDirty, exactly like typing.
  function editLine(index, value) {
    return win ? win.replaceEditorLine(index, value) : false
  }

  function advance() {
    ticks += 1
    // 20 s self-timeout, comfortably under the parent's 25 s `timeout`.
    if (ticks > 160) return fail(3, "the detached window never became editable")

    if (component && component.status === Component.Error) {
      return fail(4, component.errorString())
    }
    if (!component || component.status !== Component.Ready) return
    if (!win) {
      win = component.createObject(driver, {})
      if (!win) return fail(5, "could not create the detached window")
      return
    }
    if (!win.loaded) {
      if (win.tooLarge || win.noteMissing) {
        return fail(6, "the note was refused: " + String(win.statusText))
      }
      return
    }
    if (!typed) {
      // The seeded note is "# Save harness\n\noriginal body\n".
      if (!editLine(2, text)) return fail(7, "the window refused the edit")
      typed = true
      return
    }
    if (!win.dirty) return fail(8, "the edit did not mark the window dirty")

    tick.stop()
    if (mode === "close") {
      win.closeWindow()
    } else if (mode === "escape") {
      if (!win.testWindow) return fail(14, "no testWindow seam in the staged component")
      // Exactly what Detached.qml's Escape shortcut does: hide the window,
      // whose onVisibleChanged handler calls root.closeWindow().
      win.testWindow.visible = false
    } else {
      return fail(9, "unknown DRIVER_MODE: " + mode)
    }
  }

  Component.onCompleted: {
    if (text === "") return fail(11, "no DRIVER_TEXT")
    if (mode !== "close" && mode !== "escape") return fail(12, "bad DRIVER_MODE: " + mode)
    if (componentPath === "") return fail(13, "no DRIVER_COMPONENT")
    component = Qt.createComponent("file://" + componentPath)
    tick.start()
  }

  Timer {
    id: tick
    interval: 120
    repeat: true
    onTriggered: driver.advance()
  }
}
