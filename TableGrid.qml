import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TableEngine.js" as TableEngine

// Spreadsheet editor for one GFM table in the library. The parent owns the
// note text and saving: this component parses a snapshot of the table range,
// edits a pure TableEngine model, and emits commitRequested(newLines) only
// after verifying the source lines still match the snapshot. The note never
// changes behind the user's back.
Item {
  id: root

  property string sourceText: ""
  property int startLine: -1
  property int endLine: -1
  property bool editable: true

  // The model is always a fresh object from TableEngine (never mutated).
  property var model: ({ header: [], aligns: [], delimiters: [], rows: [] })
  property var computed: []
  property var colWidths: []
  // Lines this component believes are currently on disk/in the editor for
  // this table. Writes are refused when the source no longer matches.
  property var lastSnapshot: []
  property var pendingOldLines: []
  // True only for an unrecoverable state. Recoverable note/grid divergence is
  // tracked with externalChange so the grid stays editable.
  property bool conflict: false
  // The note's table no longer matches this grid. The banner offers "Use note"
  // and "Overwrite" instead of wedging every edit behind a hard conflict.
  property bool externalChange: false
  // Set by Library.applyTableWrite so flushWrite knows whether the committed
  // signal really spliced the new lines into the note.
  property bool commitSucceeded: false
  // Suppresses the source watcher while this grid is writing into the note.
  property bool writing: false
  property string notice: ""
  property bool loadedTable: false
  property int selectedRow: 0
  property int selectedCol: 0
  property int modelVersion: 0
  property var undoStack: []
  property var redoStack: []
  property bool editUndoPushed: false

  signal closed()
  // newLines is the complete replacement for this table (header + delimiter +
  // rows). startLine/endLine on this component identify the target range.
  signal commitRequested(var newLines)
  signal statusMessage(string message)

  readonly property int rowCount: model.rows ? model.rows.length : 0
  readonly property int columnCount: model.header ? model.header.length : 0
  readonly property real rowHeight: Style.space(30)
  readonly property real headerHeight: Style.space(24)
  readonly property real rowNumberWidth: Style.space(36)
  readonly property real totalWidth: sumWidths(colWidths)
  readonly property bool hasSelection: loadedTable && rowCount > 0
    && selectedRow >= 0 && selectedRow < rowCount && selectedCol >= 0
    && selectedCol < columnCount
  // Updated when the banner is raised, so the buttons reflect what can still
  // be done. Kept as plain properties to avoid reparsing the whole note on
  // every keystroke.
  property bool canReloadFromNote: false
  property bool canOverwriteNote: false

  FontMetrics {
    id: metrics
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Timer {
    id: writeTimer
    interval: 400
    onTriggered: root.flushWrite()
  }

  // Source edits are reconciled after a short pause: long enough that the
  // caret moving through the note does not reparse on every keystroke, short
  // enough that the grid catches up while the user is still looking at it.
  Timer {
    id: sourceTimer
    interval: 120
    onTriggered: root.reconcileSource()
  }

  onSourceTextChanged: {
    if (!loadedTable || writing || !visible) return
    sourceTimer.restart()
  }

  onVisibleChanged: {
    if (!visible) sourceTimer.stop()
  }

  Shortcut {
    sequence: "Ctrl+Z"
    context: Qt.WindowShortcut
    enabled: root.visible && root.loadedTable
    onActivated: root.undo()
  }
  Shortcut {
    sequence: "Ctrl+Shift+Z"
    context: Qt.WindowShortcut
    enabled: root.visible && root.loadedTable
    onActivated: root.redo()
  }

  // ---------------------------------------------------------------- helpers

  function stripCR(value) {
    var text = String(value === undefined || value === null ? "" : value)
    return text.charAt(text.length - 1) === "\r" ? text.slice(0, -1) : text
  }

  function sourceLines() {
    var raw = String(sourceText === undefined || sourceText === null ? "" : sourceText).split("\n")
    var lines = []
    for (var i = 0; i < raw.length; i++) lines.push(stripCR(raw[i]))
    return lines
  }

  // CR-stripped source lines for a table range, always a fresh array.
  function sliceAt(start, count) {
    var lines = sourceLines()
    var from = Math.max(0, Math.floor(Number(start)))
    return lines.slice(from, from + Math.max(0, Math.floor(Number(count))))
  }

  function tableAtLine(line) {
    var tables = TableEngine.findTables(sourceLines())
    for (var i = 0; i < tables.length; i++) {
      if (tables[i].startLine === line) return tables[i]
    }
    return null
  }

  // The canonical text for the snapshot, so a table written without the
  // usual spaces around pipes is not mistaken for an unsaved grid edit.
  function snapshotCanonicalLines() {
    var tables = TableEngine.findTables(lastSnapshot)
    if (tables.length === 1 && tables[0].startLine === 0
      && tables[0].endLine === lastSnapshot.length - 1) {
      return TableEngine.serializeTable(tables[0])
    }
    return lastSnapshot
  }

  function gridDirty() {
    return !TableEngine.sameLines(TableEngine.serializeTable(model),
      snapshotCanonicalLines())
  }

  // Best table to reload from: the one still at our line, otherwise the only
  // table whose text matches our snapshot (it moved), otherwise the only table
  // with the same number of columns. Ambiguous cases deliberately return null.
  function bestNoteTable() {
    var lines = sourceLines()
    var tables = TableEngine.findTables(lines)
    var atLine = null
    for (var i = 0; i < tables.length; i++) {
      if (tables[i].startLine === startLine) atLine = tables[i]
    }
    if (atLine) return atLine
    var matches = snapshotMatches(tables, lines)
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) return null
    var sameColumns = []
    for (var j = 0; j < tables.length; j++) {
      if (tables[j].header.length === columnCount) sameColumns.push(tables[j])
    }
    return sameColumns.length === 1 ? sameColumns[0] : null
  }

  function snapshotMatches(tables, lines) {
    var matches = []
    for (var i = 0; i < tables.length; i++) {
      var region = lines.slice(tables[i].startLine, tables[i].endLine + 1)
      if (TableEngine.sameLines(region, lastSnapshot)) matches.push(tables[i])
    }
    return matches
  }

  function refreshBannerActions() {
    canReloadFromNote = loadedTable && bestNoteTable() !== null
    canOverwriteNote = loadedTable && tableAtLine(startLine) !== null
  }

  function sumWidths(widths) {
    var total = 0
    for (var i = 0; i < widths.length; i++) total += widths[i]
    return total
  }

  function cellRaw(row, column) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) return ""
    var line = model.rows[row]
    if (!line || line[column] === undefined || line[column] === null) return ""
    return String(line[column])
  }

  function cellDisplay(row, column) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) return ""
    var line = computed[row]
    if (!line || !line[column]) return ""
    return String(line[column].display)
  }

  function cellError(row, column) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) return ""
    var line = computed[row]
    if (!line || !line[column]) return ""
    return line[column].error ? String(line[column].error) : ""
  }

  function cellIsNumeric(row, column) {
    if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) return false
    var line = computed[row]
    if (!line || !line[column]) return false
    return typeof line[column].value === "number"
  }

  function cellIsFormula(row, column) {
    return String(cellRaw(row, column)).charAt(0) === "="
  }

  function cellAlignment(row, column) {
    var align = model.aligns && model.aligns[column] ? model.aligns[column] : "left"
    if (cellIsNumeric(row, column)) return "right"
    return align
  }

  function horizontalFor(align) {
    if (align === "right") return TextInput.AlignRight
    if (align === "center") return TextInput.AlignHCenter
    return TextInput.AlignLeft
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  // ------------------------------------------------------------ model state

  function recompute() {
    computed = TableEngine.computeTable(model)
    var widths = []
    var columns = columnCount
    var average = metrics.averageCharacterWidth
    if (!average || average <= 0) average = 6.5
    for (var c = 0; c < columns; c++) {
      var longest = String(model.header[c] || "").length
      for (var r = 0; r < computed.length; r++) {
        var cell = computed[r][c]
        longest = Math.max(longest, String(cell ? cell.display : "").length)
      }
      var width = Math.ceil(longest * average * 1.1) + Style.space(22)
      widths.push(clamp(width, Style.space(90), Style.space(320)))
    }
    colWidths = widths
    modelVersion += 1
  }

  function applyModel(next, keepSelection) {
    var row = selectedRow
    var column = selectedCol
    model = TableEngine.cloneModel(next)
    if (keepSelection !== false) {
      selectedRow = rowCount > 0 ? clamp(row, 0, rowCount - 1) : -1
      selectedCol = columnCount > 0 ? clamp(column, 0, columnCount - 1) : -1
    }
    recompute()
  }

  function snapshotState() {
    return {
      model: TableEngine.cloneModel(model),
      row: selectedRow,
      column: selectedCol
    }
  }

  function pushUndo() {
    var stack = undoStack.concat([snapshotState()])
    if (stack.length > 50) stack = stack.slice(stack.length - 50)
    undoStack = stack
    redoStack = []
    editUndoPushed = true
  }

  function restoreSnapshot(snapshot) {
    if (!snapshot) return
    model = TableEngine.cloneModel(snapshot.model)
    selectedRow = rowCount > 0 ? clamp(snapshot.row, 0, rowCount - 1) : -1
    selectedCol = columnCount > 0 ? clamp(snapshot.column, 0, columnCount - 1) : -1
    recompute()
    editUndoPushed = false
    Qt.callLater(function() {
      if (root.hasSelection) root.focusCell(root.selectedRow, root.selectedCol, true)
    })
  }

  function undo() {
    if (undoStack.length === 0) return
    var snapshot = undoStack[undoStack.length - 1]
    undoStack = undoStack.slice(0, -1)
    redoStack = redoStack.concat([snapshotState()])
    restoreSnapshot(snapshot)
    flushWrite()
  }

  function redo() {
    if (redoStack.length === 0) return
    var snapshot = redoStack[redoStack.length - 1]
    redoStack = redoStack.slice(0, -1)
    undoStack = undoStack.concat([snapshotState()])
    restoreSnapshot(snapshot)
    flushWrite()
  }

  function openRange(start, end) {
    var lines = sourceLines()
    var from = Math.max(0, Math.floor(Number(start)))
    var to = Math.floor(Number(end))
    if (!isFinite(from) || !isFinite(to) || from >= lines.length) {
      loadedTable = false
      model = { header: [], aligns: [], delimiters: [], rows: [] }
      computed = []
      colWidths = []
      externalChange = false
      notice = "No table at this line"
      return
    }
    to = Math.min(lines.length - 1, Math.max(from, to))
    var slice = lines.slice(from, to + 1)
    var tables = TableEngine.findTables(slice)
    var table = tables.length > 0 ? tables[0] : null
    if (!table || table.startLine !== 0) {
      loadedTable = false
      model = { header: [], aligns: [], delimiters: [], rows: [] }
      computed = []
      colWidths = []
      externalChange = false
      notice = "No table at this line"
      statusMessage(notice)
      return
    }

    startLine = from
    endLine = from + table.endLine
    lastSnapshot = slice.slice(0, table.endLine + 1)
    model = {
      header: table.header.slice(0),
      aligns: table.aligns.slice(0),
      delimiters: table.delimiters ? table.delimiters.slice(0) : [],
      rows: table.rows
    }
    undoStack = []
    redoStack = []
    conflict = false
    externalChange = false
    notice = ""
    editUndoPushed = false
    loadedTable = true
    selectedRow = rowCount > 0 ? 0 : -1
    selectedCol = columnCount > 0 ? 0 : -1
    recompute()
    Qt.callLater(function() {
      root.forceActiveFocus()
      if (root.hasSelection) root.focusCell(0, 0, true)
    })
  }

  // --------------------------------------------------------------- geometry

  function cellAt(row, column) {
    var rowItem = rowRepeater.itemAt(row)
    if (!rowItem) return null
    return rowItem.cellAt(column)
  }

  function renderedText(row, column) {
    var item = cellAt(row, column)
    return item ? item.textValue() : ""
  }

  function focusCell(row, column, selectAll) {
    var input = cellAt(row, column)
    if (!input) return
    input.focusInput()
    if (selectAll) input.selectAllCells()
  }

  function ensureVisible(row, column) {
    if (row < 0 || column < 0) return
    var x = 0
    for (var i = 0; i < column && i < colWidths.length; i++) x += colWidths[i]
    var width = colWidths[column] || Style.space(90)
    if (x < cellsFlick.contentX) cellsFlick.contentX = x
    else if (x + width > cellsFlick.contentX + cellsFlick.width) {
      cellsFlick.contentX = x + width - cellsFlick.width
    }
    var y = row * rowHeight
    if (y < cellsFlick.contentY) cellsFlick.contentY = y
    else if (y + rowHeight > cellsFlick.contentY + cellsFlick.height) {
      cellsFlick.contentY = y + rowHeight - cellsFlick.height
    }
  }

  function selectCell(row, column, focus) {
    if (!loadedTable) return
    if (rowCount === 0 || columnCount === 0) {
      selectedRow = -1
      selectedCol = -1
      return
    }
    var changed = selectedRow !== row || selectedCol !== column
    selectedRow = clamp(row, 0, rowCount - 1)
    selectedCol = clamp(column, 0, columnCount - 1)
    if (changed) editUndoPushed = false
    if (focus) focusCell(selectedRow, selectedCol, true)
    ensureVisible(selectedRow, selectedCol)
  }

  function moveBy(deltaRow, deltaColumn) {
    if (!hasSelection) return
    commitCell(selectedRow, selectedCol)
    selectCell(selectedRow + deltaRow, selectedCol + deltaColumn, true)
  }

  function moveTab(backwards) {
    if (!hasSelection) return
    commitCell(selectedRow, selectedCol)
    var total = rowCount * columnCount
    if (total <= 0) return
    var position = selectedRow * columnCount + selectedCol + (backwards ? -1 : 1)
    if (position < 0) position = total - 1
    if (position >= total) position = 0
    selectCell(Math.floor(position / columnCount), position % columnCount, true)
  }

  // ----------------------------------------------------------- cell editing

  function cellEdited(row, column, text) {
    if (!loadedTable || conflict) return
    if (!editUndoPushed) pushUndo()
    model = TableEngine.setCell(model, row, column, text)
    recompute()
    writeTimer.restart()
  }

  function setCellRaw(row, column, raw, pushHistory) {
    if (!loadedTable || conflict) return
    if (pushHistory !== false && !editUndoPushed) pushUndo()
    model = TableEngine.setCell(model, row, column, String(raw === undefined || raw === null ? "" : raw))
    recompute()
    editUndoPushed = true
  }

  function selectedRaw() {
    return cellRaw(selectedRow, selectedCol)
  }

  function setSelectedRaw(raw) {
    if (!hasSelection) return
    setCellRaw(selectedRow, selectedCol, raw, true)
    writeTimer.restart()
  }

  function commitCell(row, column) {
    if (!loadedTable) return
    writeTimer.stop()
    flushWrite()
  }

  function commitNow() {
    return flushWrite()
  }

  function selectRowColumn(row, column) {
    commitCell(selectedRow, selectedCol)
    selectCell(row, column, true)
  }

  // --------------------------------------------------------- write-back

  // Recoverable by design: the grid keeps accepting edits and the banner
  // offers "Use note" / "Overwrite". Only truly unrecoverable states should
  // ever set `conflict`.
  function reportConflict(message) {
    conflict = false
    externalChange = true
    notice = message
    refreshBannerActions()
    statusMessage(message)
  }

  function adoptTable(table, lines) {
    var source = lines || sourceLines()
    startLine = table.startLine
    endLine = table.endLine
    lastSnapshot = source.slice(table.startLine, table.endLine + 1)
    applyModel(table, true)
    // The note's version is the new baseline; old grid history would restore
    // cells that are no longer anchored to it.
    undoStack = []
    redoStack = []
    editUndoPushed = false
    conflict = false
    externalChange = false
    notice = ""
  }

  // Compare the grid with the current note and either follow a moved/changed
  // table, adopt a clean note version, or raise the non-wedging banner.
  // Returns true only when the grid's snapshot is safe to write.
  function reconcileSource() {
    if (!loadedTable) return false
    if (startLine < 0 || lastSnapshot.length === 0) return false

    var lines = sourceLines()
    var current = lines.slice(startLine, startLine + lastSnapshot.length)
    if (current.length === lastSnapshot.length
      && TableEngine.sameLines(current, lastSnapshot)) {
      // The note agrees again (an undo, or this grid's own write).
      if (externalChange || notice !== "") {
        externalChange = false
        notice = ""
      }
      return true
    }

    var tables = TableEngine.findTables(lines)
    var matches = snapshotMatches(tables, lines)
    if (matches.length === 1) {
      // Only the line number moved: keep the model, and therefore any unsaved
      // edits, so they can be written at the new position.
      startLine = matches[0].startLine
      endLine = matches[0].endLine
      externalChange = false
      notice = gridDirty() ? "Table moved in the note — your edits are kept" : ""
      return true
    }

    var atLine = null
    for (var i = 0; i < tables.length; i++) {
      if (tables[i].startLine === startLine) { atLine = tables[i]; break }
    }
    if (atLine) {
      if (!gridDirty()) {
        adoptTable(atLine, lines)
        notice = "Reloaded from the note"
        return true
      }
      reportConflict("Table changed in the note — choose Use note or Overwrite")
      return false
    }

    if (matches.length > 1) {
      reportConflict("Table moved in the note — two identical tables, close and reopen the grid")
      return false
    }

    reportConflict("Table no longer found in the note — close the grid or undo the note change")
    return false
  }

  function reloadFromNote() {
    if (!loadedTable) return false
    var found = bestNoteTable()
    if (!found) {
      reportConflict("Table no longer found in the note — close the grid or undo the note change")
      return false
    }
    openRange(found.startLine, found.endLine)
    externalChange = false
    notice = ""
    statusMessage("Reloaded table from the note")
    focusGridAfterAction()
    return true
  }

  function overwriteNote() {
    if (!loadedTable) return false
    var table = tableAtLine(startLine)
    if (!table) {
      reportConflict("Table no longer found in the note — cannot overwrite")
      return false
    }
    startLine = table.startLine
    endLine = table.endLine
    lastSnapshot = sliceAt(startLine, endLine - startLine + 1)
    conflict = false
    externalChange = false
    notice = ""
    var written = flushWrite()
    statusMessage(written ? "Table overwrote the note version"
      : (notice !== "" ? notice : "Table not written"))
    focusGridAfterAction()
    return written
  }

  function focusGridAfterAction() {
    Qt.callLater(function() {
      if (!root.visible || !root.loadedTable) return
      root.forceActiveFocus()
      if (root.hasSelection) root.focusCell(root.selectedRow, root.selectedCol, false)
    })
  }

  function flushWrite() {
    writeTimer.stop()
    if (!loadedTable) return false
    if (conflict) return false
    if (startLine < 0 || lastSnapshot.length === 0) return false
    if (!reconcileSource()) return false

    var lines = sourceLines()
    var current = lines.slice(startLine, startLine + lastSnapshot.length)
    if (current.length !== lastSnapshot.length
      || !TableEngine.sameLines(current, lastSnapshot)) {
      // Reconcile said the region was safe but it changed between the two
      // reads. Refuse rather than splice over the wrong lines.
      reportConflict("Table changed in the note — choose Use note or Overwrite")
      return false
    }

    var next = TableEngine.serializeTable(model)
    if (TableEngine.sameLines(next, lastSnapshot)) {
      editUndoPushed = false
      return true
    }

    var oldLines = lastSnapshot.slice(0)
    pendingOldLines = oldLines
    commitSucceeded = false
    writing = true
    commitRequested(next)
    writing = false
    pendingOldLines = []
    if (!commitSucceeded) return false
    // Only after the splice is real do we accept `next` as the note's text.
    // If Library refused, lastSnapshot still names the table we can retry.
    lastSnapshot = next.slice(0)
    endLine = startLine + next.length - 1
    editUndoPushed = false
    return true
  }

  function requestClose() {
    flushWrite()
    closed()
  }

  function handleEscape() {
    if (hasSelection) {
      commitCell(selectedRow, selectedCol)
      selectedRow = -1
      selectedCol = -1
      root.forceActiveFocus()
      return
    }
    requestClose()
  }

  function cellKey(event, row, column) {
    var key = event.key
    if (key === Qt.Key_Escape) {
      event.accepted = true
      handleEscape()
      return
    }
    if (key === Qt.Key_Up) {
      event.accepted = true
      moveBy(-1, 0)
      return
    }
    if (key === Qt.Key_Down) {
      event.accepted = true
      moveBy(1, 0)
      return
    }
    if (key === Qt.Key_Left) {
      event.accepted = true
      moveBy(0, -1)
      return
    }
    if (key === Qt.Key_Right) {
      event.accepted = true
      moveBy(0, 1)
      return
    }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      event.accepted = true
      moveBy(1, 0)
      return
    }
    if (key === Qt.Key_Tab) {
      event.accepted = true
      moveTab((event.modifiers & Qt.ShiftModifier) !== 0)
      return
    }
    if (key === Qt.Key_Delete) {
      // Delete clears the selected cell when the caret has no selection.
      var input = cellAt(row, column)
      if (input && input.selectionEmpty()) {
        event.accepted = true
        setCellRaw(row, column, "", true)
        flushWrite()
      }
    }
  }

  // ------------------------------------------------------- structural ops

  function actionRow() {
    return rowCount > 0 ? clamp(selectedRow < 0 ? 0 : selectedRow, 0, rowCount - 1) : 0
  }

  function actionColumn() {
    return columnCount > 0 ? clamp(selectedCol < 0 ? 0 : selectedCol, 0, columnCount - 1) : 0
  }

  function addRow(offset) {
    if (!loadedTable || conflict) return
    var at = rowCount === 0 ? 0 : actionRow() + offset
    pushUndo()
    applyModel(TableEngine.insertRow(model, at), false)
    editUndoPushed = false
    selectCell(at, actionColumn(), true)
    flushWrite()
  }

  function removeRow() {
    if (!loadedTable || conflict || rowCount === 0) return
    var at = actionRow()
    pushUndo()
    applyModel(TableEngine.deleteRow(model, at), false)
    editUndoPushed = false
    if (rowCount > 0) selectCell(Math.min(at, rowCount - 1), actionColumn(), true)
    else {
      selectedRow = -1
      selectedCol = actionColSafe()
    }
    flushWrite()
  }

  function actionColSafe() {
    return columnCount > 0 ? actionColumn() : -1
  }

  function addColumn(offset) {
    if (!loadedTable || conflict) return
    var at = columnCount === 0 ? 0 : actionColumn() + offset
    pushUndo()
    applyModel(TableEngine.insertColumn(model, at), false)
    editUndoPushed = false
    selectCell(actionRow(), at, true)
    flushWrite()
  }

  function removeColumn() {
    if (!loadedTable || conflict || columnCount <= 1) return
    var at = actionColumn()
    pushUndo()
    applyModel(TableEngine.deleteColumn(model, at), false)
    editUndoPushed = false
    selectCell(actionRow(), Math.min(at, columnCount - 1), true)
    flushWrite()
  }

  function sortBy(descending) {
    if (!loadedTable || conflict || rowCount < 2) return
    pushUndo()
    applyModel(TableEngine.sortRows(model, actionColumn(), descending ? "desc" : "asc"), true)
    editUndoPushed = false
    flushWrite()
  }

  function alignColumn(align) {
    if (!loadedTable || conflict || columnCount === 0) return
    pushUndo()
    applyModel(TableEngine.setAlign(model, actionColumn(), align), true)
    editUndoPushed = false
    flushWrite()
  }

  // ------------------------------------------------------------------- UI

  Column {
    id: panelColumn
    anchors.fill: parent
    spacing: Style.space(4)

    Item {
      width: parent.width
      height: Style.space(26)

      Text {
        id: tableTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Table · " + root.rowCount + "×" + root.columnCount
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      GridAction {
        id: closeAction
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        label: "✕"
        tip: "Close the table grid (Esc)"
        available: true
        onActivated: root.requestClose()
      }

      Text {
        visible: root.notice !== "" && !root.externalChange
        anchors.left: tableTitle.right
        anchors.leftMargin: Style.space(8)
        anchors.right: closeAction.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.notice
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Recoverable note/grid divergence. This row pushes the table down instead
    // of covering the title or the close button, so the grid stays usable.
    Rectangle {
      id: externalBanner
      visible: root.externalChange
      width: parent.width
      height: visible ? bannerRow.implicitHeight + Style.space(10) : 0
      color: Util.alpha(Commons.Color.urgent, 0.07)
      border.width: 1
      border.color: Util.alpha(Commons.Color.urgent, 0.24)
      radius: Style.cornerRadius

      Row {
        id: bannerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(5)
        height: implicitHeight
        spacing: Style.space(6)

        Text {
          id: bannerText
          width: Math.max(Style.space(80),
            bannerRow.width - bannerActions.width - bannerRow.spacing)
          anchors.verticalCenter: parent.verticalCenter
          text: root.notice
          textFormat: Text.PlainText
          color: Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          id: bannerActions
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          GridAction {
            label: "Use note"
            tip: "Discard grid edits and reload the note's table"
            visible: root.canReloadFromNote
            available: root.canReloadFromNote
            onActivated: root.reloadFromNote()
          }
          GridAction {
            label: "Overwrite"
            tip: "Write the grid's cells over the note's table"
            visible: root.canOverwriteNote
            available: root.canOverwriteNote
            onActivated: root.overwriteNote()
          }
          GridAction {
            label: "Close"
            tip: "Close the grid without writing"
            visible: !root.canReloadFromNote && !root.canOverwriteNote
            available: true
            onActivated: root.requestClose()
          }
        }
      }
    }

    Flow {
      width: parent.width
      height: implicitHeight
      spacing: Style.space(2)

      GridAction {
        label: "Row ↑"
        tip: "Insert a row above the selected row"
        available: root.loadedTable
        onActivated: root.addRow(0)
      }
      GridAction {
        label: "Row ↓"
        tip: "Insert a row below the selected row"
        available: root.loadedTable
        onActivated: root.addRow(1)
      }
      GridAction {
        label: "Del row"
        tip: "Delete the selected row"
        available: root.loadedTable && root.rowCount > 0
        onActivated: root.removeRow()
      }
      GridAction {
        label: "Col ←"
        tip: "Insert a column to the left"
        available: root.loadedTable
        onActivated: root.addColumn(0)
      }
      GridAction {
        label: "Col →"
        tip: "Insert a column to the right"
        available: root.loadedTable
        onActivated: root.addColumn(1)
      }
      GridAction {
        label: "Del col"
        tip: "Delete the selected column"
        available: root.loadedTable && root.columnCount > 1
        onActivated: root.removeColumn()
      }
      GridAction {
        label: "Sort ↑"
        tip: "Sort rows ascending by the selected column (references are not rewritten)"
        available: root.loadedTable && root.rowCount > 1
        onActivated: root.sortBy(false)
      }
      GridAction {
        label: "Sort ↓"
        tip: "Sort rows descending by the selected column (references are not rewritten)"
        available: root.loadedTable && root.rowCount > 1
        onActivated: root.sortBy(true)
      }
      GridAction {
        label: "L"
        tip: "Align the selected column left"
        available: root.loadedTable && root.columnCount > 0
        onActivated: root.alignColumn("left")
      }
      GridAction {
        label: "C"
        tip: "Align the selected column centred"
        available: root.loadedTable && root.columnCount > 0
        onActivated: root.alignColumn("center")
      }
      GridAction {
        label: "R"
        tip: "Align the selected column right"
        available: root.loadedTable && root.columnCount > 0
        onActivated: root.alignColumn("right")
      }
    }

    // --------------------------------------------------------- formula bar
    BorderSurface {
      width: parent.width
      height: Style.space(30)
      color: Util.alpha(Commons.Color.foreground, 0.025)
      borderSpec: Border.flat(Util.alpha(Commons.Color.foreground, 0.12), 1)
      radius: Style.cornerRadius

      Item {
        anchors.fill: parent
        anchors.leftMargin: Style.space(7)
        anchors.rightMargin: Style.space(7)

        Text {
          id: formulaRef
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(34)
          text: root.hasSelection ? TableEngine.indexToRef(root.selectedRow, root.selectedCol) : "—"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          id: formulaValue
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(74)
          horizontalAlignment: Text.AlignRight
          text: root.hasSelection ? root.cellDisplay(root.selectedRow, root.selectedCol) : ""
          textFormat: Text.PlainText
          color: root.cellError(root.selectedRow, root.selectedCol) !== ""
            ? Commons.Color.urgent
            : Util.alpha(Commons.Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        TextInput {
          id: formulaInput
          anchors.left: formulaRef.right
          anchors.leftMargin: Style.space(6)
          anchors.right: formulaValue.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.hasSelection && !root.conflict
          clip: true
          selectByMouse: true
          color: Commons.Color.foreground
          selectionColor: Util.alpha(Commons.Color.accent, 0.35)
          selectedTextColor: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          leftPadding: Style.space(4)
          rightPadding: Style.space(4)

          function syncFromSelection() {
            if (formulaInput.activeFocus) return
            formulaInput.text = root.selectedRaw()
          }

          Component.onCompleted: syncFromSelection()
          Connections {
            target: root
            function onModelVersionChanged() { formulaInput.syncFromSelection() }
            function onSelectedRowChanged() { formulaInput.syncFromSelection() }
            function onSelectedColChanged() { formulaInput.syncFromSelection() }
          }
          onActiveFocusChanged: {
            if (activeFocus) {
              text = root.selectedRaw()
              selectAll()
            } else {
              syncFromSelection()
            }
          }
          onTextEdited: root.setSelectedRaw(text)
          onAccepted: {
            root.commitCell(root.selectedRow, root.selectedCol)
            if (root.rowCount > 0) root.selectCell(Math.min(root.rowCount - 1, root.selectedRow + 1),
              root.selectedCol, true)
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              event.accepted = true
              root.handleEscape()
            }
          }
        }
      }
    }

    // ---------------------------------------------------------------- grid
    Item {
      id: gridArea
      width: parent.width
      height: Math.max(0, panelColumn.height - y)
      clip: true

      Rectangle {
        id: corner
        x: 0
        y: 0
        width: root.rowNumberWidth
        height: root.headerHeight
        color: Util.alpha(Commons.Color.foreground, 0.055)
        border.width: 1
        border.color: Util.alpha(Commons.Color.foreground, 0.12)

        Text {
          anchors.centerIn: parent
          text: "#"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Item {
        id: headerClip
        x: root.rowNumberWidth
        y: 0
        width: Math.max(0, gridArea.width - root.rowNumberWidth)
        height: root.headerHeight
        clip: true

        Row {
          x: -cellsFlick.contentX
          height: root.headerHeight

          Repeater {
            model: root.columnCount

            delegate: Item {
              id: headerCell
              property int column: index
              width: root.colWidths.length > column ? root.colWidths[column] : Style.space(90)
              height: root.headerHeight

              Rectangle {
                anchors.fill: parent
                color: root.selectedCol === headerCell.column
                  ? Util.alpha(Commons.Color.accent, 0.13)
                  : Util.alpha(Commons.Color.foreground, 0.055)
                border.width: 1
                border.color: Util.alpha(Commons.Color.foreground, 0.12)
              }

              Text {
                anchors.centerIn: parent
                text: TableEngine.columnLabel(headerCell.column)
                textFormat: Text.PlainText
                color: root.selectedCol === headerCell.column
                  ? Commons.Color.accent
                  : Util.alpha(Commons.Color.foreground, 0.72)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.selectedCol === headerCell.column
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.commitCell(root.selectedRow, root.selectedCol)
                  root.selectCell(root.rowCount > 0 ? Math.max(0, root.selectedRow) : 0,
                    headerCell.column, root.rowCount > 0)
                }
              }
            }
          }
        }
      }

      Item {
        id: numbersClip
        x: 0
        y: root.headerHeight
        width: root.rowNumberWidth
        height: Math.max(0, gridArea.height - root.headerHeight)
        clip: true

        Column {
          y: -cellsFlick.contentY

          Repeater {
            model: root.rowCount

            delegate: Item {
              id: numberCell
              width: root.rowNumberWidth
              height: root.rowHeight

              Rectangle {
                anchors.fill: parent
                color: root.selectedRow === index
                  ? Util.alpha(Commons.Color.accent, 0.13)
                  : Util.alpha(Commons.Color.foreground, 0.035)
                border.width: 1
                border.color: Util.alpha(Commons.Color.foreground, 0.12)
              }

              Text {
                anchors.centerIn: parent
                text: String(index + 1)
                textFormat: Text.PlainText
                color: root.selectedRow === index
                  ? Commons.Color.accent
                  : Util.alpha(Commons.Color.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.selectedRow === index
              }
            }
          }
        }
      }

      Flickable {
        id: cellsFlick
        x: root.rowNumberWidth
        y: root.headerHeight
        width: Math.max(0, gridArea.width - root.rowNumberWidth)
        height: Math.max(0, gridArea.height - root.headerHeight)
        clip: true
        contentWidth: Math.max(width, root.totalWidth)
        contentHeight: Math.max(height, root.rowCount * root.rowHeight)
        flickableDirection: Flickable.HorizontalAndVerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        WheelHandler {
          onWheel: function(event) {
            if ((event.modifiers & Qt.ShiftModifier) !== 0 && event.angleDelta.y !== 0) {
              cellsFlick.contentX = Math.max(0, Math.min(
                cellsFlick.contentWidth - cellsFlick.width,
                cellsFlick.contentX - event.angleDelta.y))
              event.accepted = true
            }
          }
        }

        Column {
          id: rowsColumn
          width: Math.max(cellsFlick.width, root.totalWidth)

          Repeater {
            id: rowRepeater
            model: root.rowCount

            delegate: Item {
              id: rowDelegate
              property int rowIndex: index
              width: rowsColumn.width
              height: root.rowHeight

              function cellAt(column) {
                return cellRepeater.itemAt(column)
              }

              Row {
                anchors.fill: parent

                Repeater {
                  id: cellRepeater
                  model: root.columnCount

                  delegate: Item {
                    id: cellItem
                    property int columnIndex: index
                    width: root.colWidths.length > columnIndex ? root.colWidths[columnIndex] : Style.space(90)
                    height: rowDelegate.height
                    readonly property bool selected: root.selectedRow === rowDelegate.rowIndex
                      && root.selectedCol === columnIndex

                    function focusInput() { cellInput.forceActiveFocus() }
                    function selectAllCells() { cellInput.selectAll() }
                    function selectionEmpty() { return cellInput.selectedText === "" }
                    function textValue() { return cellInput.text }

                    Rectangle {
                      anchors.fill: parent
                      color: cellItem.selected
                        ? Util.alpha(Commons.Color.accent, 0.11)
                        : root.cellError(rowDelegate.rowIndex, cellItem.columnIndex) !== ""
                          ? Util.alpha(Commons.Color.urgent, 0.06)
                          : root.cellIsFormula(rowDelegate.rowIndex, cellItem.columnIndex)
                            ? Util.alpha(Commons.Color.accent, 0.035)
                            : rowDelegate.rowIndex % 2 === 1
                              ? Util.alpha(Commons.Color.foreground, 0.022)
                              : "transparent"
                      border.width: cellItem.selected ? 1 : 1
                      border.color: cellItem.selected
                        ? Commons.Color.accent
                        : Util.alpha(Commons.Color.foreground, 0.11)
                    }

                    TextInput {
                      id: cellInput
                      anchors.fill: parent
                      anchors.margins: 1
                      leftPadding: Style.space(6)
                      rightPadding: Style.space(6)
                      verticalAlignment: TextInput.AlignVCenter
                      horizontalAlignment: root.horizontalFor(
                        root.cellAlignment(rowDelegate.rowIndex, cellItem.columnIndex))
                      clip: true
                      selectByMouse: true
                      activeFocusOnPress: true
                      color: root.cellError(rowDelegate.rowIndex, cellItem.columnIndex) !== ""
                        ? Commons.Color.urgent
                        : Util.alpha(Commons.Color.foreground, 0.92)
                      selectionColor: Util.alpha(Commons.Color.accent, 0.35)
                      selectedTextColor: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall

                      function syncFromModel() {
                        if (cellInput.activeFocus) return
                        cellInput.text = root.cellDisplay(rowDelegate.rowIndex, cellItem.columnIndex)
                      }

                      function beginEdit() {
                        cellInput.text = root.cellRaw(rowDelegate.rowIndex, cellItem.columnIndex)
                        cellInput.selectAll()
                        root.selectCell(rowDelegate.rowIndex, cellItem.columnIndex, false)
                      }

                      Component.onCompleted: {
                        if (cellInput.activeFocus) beginEdit()
                        else syncFromModel()
                      }
                      Connections {
                        target: root
                        function onModelVersionChanged() { cellInput.syncFromModel() }
                      }
                      onActiveFocusChanged: {
                        if (activeFocus) {
                          beginEdit()
                        } else {
                          root.commitCell(rowDelegate.rowIndex, cellItem.columnIndex)
                          syncFromModel()
                        }
                      }
                      onTextEdited: root.cellEdited(rowDelegate.rowIndex, cellItem.columnIndex, text)
                      Keys.onShortcutOverride: function(event) {
                        // Keep Tab out of the focus chain so it can move cells.
                        if (event.key === Qt.Key_Tab) event.accepted = true
                      }
                      Keys.onPressed: function(event) {
                        root.cellKey(event, rowDelegate.rowIndex, cellItem.columnIndex)
                      }
                      onAccepted: root.moveBy(1, 0)
                    }
                  }
                }
              }
            }
          }
        }
      }

      Text {
        visible: root.loadedTable && root.rowCount === 0
        anchors.centerIn: parent
        text: "No rows yet — use Row ↓ to add one"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.38)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: !root.loadedTable
        anchors.centerIn: parent
        text: root.notice !== "" ? root.notice : "No table at this line"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  component GridAction: Item {
    id: action
    property string label: ""
    property string tip: ""
    property bool available: true
    signal activated()

    width: actionLabel.implicitWidth + Style.space(12)
    height: Style.space(22)
    opacity: available ? 1 : 0.38

    Rectangle {
      anchors.fill: parent
      radius: Style.space(3)
      color: actionMouse.containsMouse && action.available
        ? Util.alpha(Commons.Color.foreground, 0.09)
        : "transparent"
      border.width: 1
      border.color: actionMouse.containsMouse && action.available
        ? Util.alpha(Commons.Color.foreground, 0.16)
        : "transparent"
    }

    Text {
      id: actionLabel
      anchors.centerIn: parent
      text: action.label
      textFormat: Text.PlainText
      color: Util.alpha(Commons.Color.foreground, 0.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: action.available
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }

    ToolTip.visible: actionMouse.containsMouse && action.tip !== ""
    ToolTip.text: action.tip
    ToolTip.delay: 450
  }
}
