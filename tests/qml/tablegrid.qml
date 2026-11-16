import QtQuick

// Drives TableGrid's range selection directly: open a small table, extend and
// collapse the range, clear it, and undo. Runs inside scripts/qmltest's
// offscreen harness; the grid never writes because no commit handler is
// connected, so the note data root is irrelevant to this case.
Item {
  id: test

  property var harness: null
  property var grid: null
  property bool gridFailed: false
  property int step: 0
  property int ticks: 0
  property int settleUntil: 0

  readonly property string tableText: "| A | B | C |\n| --- | --- | --- |\n"
    + "| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n| a3 | b3 | c3 |\n| a4 | b4 | c4 |"

  function detail(value) {
    return JSON.stringify(value)
  }

  function fail(message) {
    harness.check("the table grid case completed", false, message)
    harness.done()
  }

  function start(h) {
    harness = h
    if (gridFailed) {
      fail("the table grid did not load")
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

    if (step === 1) {
      if (!grid) return
      grid.width = 900
      grid.height = 500
      grid.sourceText = tableText
      grid.openRange(0, 6)
      // Give the repeaters a few ticks to build the delegates the grid
      // focuses, even though the range maths itself is synchronous.
      settleUntil = ticks + 3
      step = 2
      return
    }

    if (step === 2) {
      if (ticks < settleUntil) return
      harness.check("the table grid loads the source table",
        grid.loadedTable === true, detail(grid.loadedTable))
      harness.check("the table has four body rows", grid.rowCount === 4, detail(grid.rowCount))
      harness.check("the table has three columns", grid.columnCount === 3, detail(grid.columnCount))

      grid.extendTo(1, 1)
      harness.check("extendTo makes a range", grid.hasRange === true, detail(grid.hasRange))
      harness.check("the range starts at the anchor",
        grid.rangeTop === 0 && grid.rangeLeft === 0,
        detail([grid.rangeTop, grid.rangeLeft]))
      harness.check("the range reaches the active cell",
        grid.rangeBottom === 1 && grid.rangeRight === 1,
        detail([grid.rangeBottom, grid.rangeRight]))

      // Focus a cell the way a range extension does: extendTo moves the active
      // cell and beginEdit selects the whole value. Offscreen windows never
      // become active, so forceActiveFocus cannot reach activeFocus here;
      // apply the same whole-cell selection directly.
      grid.extendTo(0, 1)
      var extendedCell = grid.cellAt(0, 1)
      if (extendedCell) extendedCell.selectAllCells()
      harness.check("a newly focused cell extends either way",
        extendedCell && extendedCell.cursorAtStart() && extendedCell.cursorAtEnd(),
        extendedCell ? detail([extendedCell.cursorAtStart(), extendedCell.cursorAtEnd()])
          : "no cell delegate")
      step = 3
      return
    }

    if (step === 3) {
      grid.extendTo(0, 0)
      harness.check("a range back on its anchor is no range", grid.hasRange === false,
        detail([grid.anchorRow, grid.anchorCol, grid.selectedRow, grid.selectedCol]))

      grid.extendTo(2, 2)
      harness.check("the range regrows from the anchor",
        grid.hasRange === true && grid.rangeBottom === 2 && grid.rangeRight === 2,
        detail([grid.rangeTop, grid.rangeLeft, grid.rangeBottom, grid.rangeRight]))
      harness.check("selectionTsv copies the selected block as raw TSV",
        grid.selectionTsv() === "a1\tb1\tc1\na2\tb2\tc2\na3\tb3\tc3",
        detail(grid.selectionTsv()))

      grid.clearRange()
      harness.check("clearRange clears the first cell", grid.cellRaw(0, 0) === "",
        detail(grid.cellRaw(0, 0)))
      harness.check("clearRange clears the middle cell", grid.cellRaw(1, 1) === "",
        detail(grid.cellRaw(1, 1)))
      harness.check("clearRange clears the last cell", grid.cellRaw(2, 2) === "",
        detail(grid.cellRaw(2, 2)))
      harness.check("clearRange leaves cells outside the range",
        grid.cellRaw(3, 0) === "a4" && grid.cellRaw(3, 1) === "b4"
          && grid.cellRaw(3, 2) === "c4",
        detail([grid.cellRaw(3, 0), grid.cellRaw(3, 1), grid.cellRaw(3, 2)]))

      grid.undo()
      harness.check("undo restores the cleared cell", grid.cellRaw(2, 2) === "c3",
        detail(grid.cellRaw(2, 2)))

      step = 4
      tick.stop()
      harness.done()
    }
  }

  Timer {
    id: tick
    interval: 120
    repeat: true
    onTriggered: test.advance()
  }

  Loader {
    id: gridLoader
    source: "file:///home/matt/.config/omarchy/plugins/matt.quill/TableGrid.qml"
    onStatusChanged: {
      if (status === Loader.Error) {
        test.gridFailed = true
        if (test.harness) {
          test.harness.check("the table grid loads", false, "QML error")
          test.harness.done()
        }
      } else if (status === Loader.Ready) {
        test.grid = item
      }
    }
  }
}
