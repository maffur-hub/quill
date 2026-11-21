import QtQuick

// Shift+Tab arrives from xkb as ISO_Left_Tab, which Qt maps to Key_Backtab,
// not Shift+Key_Tab. The Tab branch only tested Qt.Key_Tab, so the outdent
// path could not be reached from the keyboard. This case pins the predicate
// the key handler asks, then drives indentSelection/outdentSelection directly
// on list text: the harness cannot synthesise key events, so the behaviour
// rows prove the indenting itself (and pass before the predicate exists).
Item {
  id: test

  property var harness: null
  property var editor: null

  function fail(message) {
    harness.check("the editor keys case completed", false, message)
    harness.done()
  }

  // On the pristine editor the predicate does not exist at all; report that as
  // a value so every stub row still prints its own failure instead of the
  // first call aborting the case.
  function outdentAnswer(key, modifiers) {
    if (!editor || typeof editor.isOutdentEvent !== "function") return "missing"
    try {
      return editor.isOutdentEvent({ key: key, modifiers: modifiers }) === true
    } catch (error) {
      return "threw: " + error
    }
  }

  function checkOutdent(name, key, modifiers, expected) {
    var answer = outdentAnswer(key, modifiers)
    harness.check(name, answer === expected,
      "got " + answer + ", expected " + expected)
  }

  function selectAll() {
    editor.select(0, editor.text.length)
  }

  function start(h) {
    harness = h
    var component = Qt.createComponent(Qt.resolvedUrl("../../MarkdownEditor.qml"))
    if (component.status !== Component.Ready) {
      fail("component is not ready: " + component.errorString())
      return
    }
    editor = component.createObject(test, {
      width: 700,
      height: 500,
      text: "- alpha\n- beta",
      spellcheckEnabled: false
    })
    if (!editor) {
      fail("the editor could not be created")
      return
    }
    tick.start()
  }

  function verify() {
    checkOutdent("Key_Backtab alone is an outdent", Qt.Key_Backtab, Qt.NoModifier, true)
    checkOutdent("Key_Backtab with Shift is an outdent", Qt.Key_Backtab, Qt.ShiftModifier, true)
    checkOutdent("Shift+Tab is an outdent", Qt.Key_Tab, Qt.ShiftModifier, true)
    checkOutdent("a plain Tab is not an outdent", Qt.Key_Tab, Qt.NoModifier, false)
    checkOutdent("a letter key is not an outdent", Qt.Key_A, Qt.NoModifier, false)
    checkOutdent("Ctrl+Tab is not an outdent", Qt.Key_Tab, Qt.ControlModifier, false)

    // Behaviour of the two commands the branch calls, on seeded list text.
    editor.text = "- alpha\n- beta"
    selectAll()
    editor.indentSelection()
    harness.check("indentSelection indents every selected line",
      editor.text === "  - alpha\n  - beta", JSON.stringify(editor.text))

    selectAll()
    editor.outdentSelection()
    harness.check("outdentSelection removes the indent again",
      editor.text === "- alpha\n- beta", JSON.stringify(editor.text))

    editor.text = "\t- alpha"
    selectAll()
    editor.outdentSelection()
    harness.check("outdentSelection removes a tab indent",
      editor.text === "- alpha", JSON.stringify(editor.text))

    tick.stop()
    harness.done()
  }

  Timer {
    id: tick
    interval: 1000
    running: false
    onTriggered: test.verify()
  }
}
