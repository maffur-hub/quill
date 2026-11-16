import QtQuick

// A preview table cell with inline Markdown must render through the rich-text
// path, while a plain cell stays plain. A long cell must wrap and grow its row
// instead of eliding on one line, without changing an ordinary short row's
// height. Runs offscreen inside scripts/qmltest; the pane only builds, it is
// never shown or clicked.
Item {
  id: test

  property var harness: null
  property var preview: null
  property int step: 0
  property int ticks: 0
  property int settleUntil: 0

  readonly property string longText: "the quick brown fox jumps over the lazy dog "
    + "while the patient heron watches from the river bank and the wind moves "
    + "softly through the tall reeds beside the quiet water, again and again "
    + "until the line is long enough to wrap several times inside a narrow column"
  readonly property string tableText: "| A | B |\n| --- | --- |\n"
    + "| **bold** | plain |\n"
    + "| short | x |\n"
    + "| " + longText + " | y |"

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

  // The walk reaches the same delegate through both `data` and `children`,
  // so identities repeat. Keep one of each for counting and measuring.
  function uniqueItems(items) {
    var output = []
    for (var i = 0; i < items.length; i++) {
      if (output.indexOf(items[i]) < 0) output.push(items[i])
    }
    return output
  }

  function rowForCell(rows, cell) {
    for (var i = 0; i < rows.length; i++) {
      if (test.collectByName(rows[i], "previewTableCellText", []).indexOf(cell) >= 0)
        return rows[i]
    }
    return null
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
    if (ticks > 60) {
      fail("timed out in step " + step)
      return
    }
    if (step !== 1 && step !== 2) return

    var cells = uniqueItems(collectByName(preview, "previewTableCellText", []))
    // Two header cells plus six body cells; wait for the delegates to build.
    if (step === 1) {
      if (cells.length < 8) return
      // Text lays out its lines on a later polish, so give the wrap a few ticks.
      settleUntil = ticks + 4
      step = 2
      return
    }
    if (ticks < settleUntil) return

    var rich = null
    var plain = null
    var longCell = null
    var shortCell = null
    var headerCell = null
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].textFormat === Text.RichText) rich = cells[i]
      else if (cells[i].text === "plain") plain = cells[i]
      if (cells[i].text === test.longText) longCell = cells[i]
      if (cells[i].text === "short") shortCell = cells[i]
      if (cells[i].text === "A") headerCell = cells[i]
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

    harness.check("the long cell is present", !!longCell)
    harness.check("the short cell is present", !!shortCell)
    if (longCell) {
      harness.check("a long cell wraps", longCell.wrapMode === Text.Wrap,
        String(longCell.wrapMode))
      harness.check("a long cell is capped at more than one line",
        longCell.maximumLineCount > 1, String(longCell.maximumLineCount))
      harness.check("a long cell actually wraps onto several lines",
        longCell.lineCount > 1, String(longCell.lineCount))
    }
    if (shortCell) {
      harness.check("a short cell stays on one line",
        shortCell.lineCount === 1, String(shortCell.lineCount))
    }

    var rows = uniqueItems(collectByName(preview, "previewTableRow", []))
    var frames = uniqueItems(collectByName(preview, "previewTableFrame", []))
    var frame = frames.length > 0 ? frames[0] : null
    harness.check("the preview table exposes its frame", !!frame)
    if (longCell && shortCell && rows.length >= 3) {
      var longRow = rowForCell(rows, longCell)
      var shortRow = rowForCell(rows, shortCell)
      var headerRow = rowForCell(rows, headerCell)
      harness.check("the wrapped cell's row is taller than the short cell's row",
        !!longRow && !!shortRow && longRow.height > shortRow.height,
        longRow && shortRow
          ? longRow.height + " vs " + shortRow.height : "rows missing")
      harness.check("the wrapped cell's row is taller than the header row",
        !!longRow && !!headerRow && longRow.height > headerRow.height,
        longRow && headerRow
          ? longRow.height + " vs " + headerRow.height : "rows missing")
      if (frame) {
        var rowSum = 0
        for (var r = 0; r < rows.length; r++) rowSum += rows[r].height
        harness.check("the table frame follows the grown rows",
          frame.height >= rowSum, frame.height + " vs row sum " + rowSum)
      }
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
