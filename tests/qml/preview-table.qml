import QtQuick

// A preview table cell with inline Markdown must render through the rich-text
// path, while a plain cell stays plain. Runs offscreen inside scripts/qmltest;
// the pane only builds, it is never shown or clicked.
Item {
  id: test

  property var harness: null
  property var preview: null
  property int step: 0
  property int ticks: 0

  readonly property string tableText: "| A | B |\n| --- | --- |\n| **bold** | plain |"

  function collectByName(item, name, found) {
    if (!item) return found
    if (item.objectName === name) found.push(item)
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
    for (i = 0; i < kids.length; i++) test.collectByName(kids[i], name, found)
    return found
  }

  function fail(message) {
    harness.check("the preview table case completed", false, message)
    harness.done()
  }

  function start(h) {
    harness = h
    var component = Qt.createComponent(Qt.resolvedUrl("../../PreviewPane.qml"))
    if (component.status !== Component.Ready) {
      h.check("the preview pane can be created", false, "component is not ready")
      h.done()
      return
    }
    preview = component.createObject(test, {
      markdown: test.tableText,
      width: 640,
      height: 320
    })
    if (!preview) {
      h.check("the preview pane can be created", false)
      h.done()
      return
    }
    step = 1
    tick.start()
  }

  function advance() {
    ticks += 1
    if (ticks > 40) {
      fail("timed out in step " + step)
      return
    }
    if (step !== 1) return

    var cells = collectByName(preview, "previewTableCellText", [])
    // Two header cells plus two body cells; wait for the delegates to build.
    if (cells.length < 4) return

    var rich = null
    var plain = null
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].textFormat === Text.RichText) rich = cells[i]
      else if (cells[i].text === "plain") plain = cells[i]
    }
    harness.check("a cell with inline Markdown renders as rich text",
      !!rich, "no rich cell among " + cells.length)
    harness.check("a plain cell stays plain text",
      !!plain, "no plain cell among " + cells.length)
    if (rich) {
      harness.check("the rich cell carries the rendered markup",
        String(rich.text).indexOf("font-weight") >= 0
          || String(rich.text).indexOf("<b") >= 0, rich.text)
    }

    tick.stop()
    harness.done()
  }

  Timer {
    id: tick
    interval: 50
    repeat: true
    running: false
    onTriggered: test.advance()
  }
}
