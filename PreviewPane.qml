import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import "ImageSizing.js" as ImageSizing
import "TableEngine.js" as TableEngine
import "MathSyntax.js" as MathSyntax
import "MathText.js" as MathText
import "MarkdownFormat.js" as MarkdownFormat

// Rendered Markdown preview. Qt's GitHub-dialect Markdown renderer handles
// the text; Quill rewrites wiki links and inline tags into quill:// links in
// the backend first.
//
// Qt's Text.MarkdownText does not draw images or real tables, so the preview
// is split into blocks: contiguous text lines go to a MarkdownText Text,
// image-only lines become Image blocks, and GFM tables become interactive
// table blocks. Everything else (headings, wiki links, tags, linkActivated)
// still goes through MarkdownText exactly as before.
//
// Display maths ($$…$$ / \[…\]) becomes its own centred Image block.
// A text block that contains inline maths switches to Text.RichText with
// MathText.js's HTML, because MarkdownText pins images to the text baseline
// and makes inline formulas float upwards.
//
// Image-only lines and tables keep their source line numbers so edits can
// target exactly the block they came from, even when the same content appears
// more than once. Line indices are relative to `markdown`; `lineOffset` maps
// them onto the note file (the backend preview strips frontmatter).
Item {
  id: root

  property string markdown: ""
  property bool loading: false
  property bool dirty: false
  property bool hasNote: false
  property bool tooLarge: false
  // Handles and resize gestures only appear when the caller can save an edit.
  property bool editable: false
  // The detached window renders tables but sends edits back to the library.
  property bool tableEditing: true
  property int lineOffset: 0

  signal linkActivated(string link)
  // line is an absolute note line: block line + lineOffset.
  signal imageResized(int line, int width)
  signal imageReset(int line)
  signal tableActivated(int startLine, int endLine)
  // line is an absolute note line: task block line + lineOffset.
  signal taskToggled(int line)

  readonly property var blocks: buildBlocks(markdown)

  // Live widths keyed by preview line while dragging or during the wheel
  // debounce. Cleared when a fresh markdown arrives from an autosave.
  property var overrides: ({})
  property bool dragging: false
  property int pendingLine: -1
  property int pendingWidth: -1

  // Optimistic checkbox state keyed by absolute note line. Cleared whenever
  // markdown changes so a stale flip can never outlive a fresh render.
  property var taskOverrides: ({})

  function maxContentWidth() {
    return Math.max(60, Math.floor(flick.width) - 2)
  }

  // Split markdown into text / image / table / maths / task blocks. Display
  // maths is found first so a $$ line is never mistaken for an image or a
  // table. Tables are found by the shared engine, so pipe rows never leak into
  // a MarkdownText block. Task lines are grouped while consecutive and are
  // ignored inside fenced code blocks.
  function buildBlocks(value) {
    var lines = String(value === undefined || value === null ? "" : value).split("\n")
    var fenced = markFences(lines)
    var tables = TableEngine.findTables(lines)
    var tableAt = {}
    for (var t = 0; t < tables.length; t++) tableAt[tables[t].startLine] = tables[t]
    var maths = MathSyntax.findDisplayBlocks(lines)
    var mathAt = {}
    for (var m = 0; m < maths.length; m++) mathAt[maths[m].startLine] = maths[m]

    var result = []
    var buffer = []
    var tasks = []

    function flushText() {
      if (buffer.length === 0) return
      var joined = buffer.join("\n")
      buffer = []
      if (joined.trim() === "") return
      result.push({ kind: "text", text: joined })
    }

    function flushTasks() {
      if (tasks.length === 0) return
      result.push({ kind: "tasks", items: tasks })
      tasks = []
    }

    var i = 0
    while (i < lines.length) {
      var math = mathAt[i]
      if (math) {
        flushText()
        flushTasks()
        result.push({
          kind: "math",
          tex: math.tex,
          startLine: math.startLine,
          endLine: math.endLine
        })
        i = math.endLine + 1
        continue
      }
      var table = tableAt[i]
      if (table) {
        flushText()
        flushTasks()
        result.push({
          kind: "table",
          table: table,
          startLine: table.startLine,
          endLine: table.endLine
        })
        i = table.endLine + 1
        continue
      }
      var image = ImageSizing.splitLine(lines[i])
      if (image) {
        flushText()
        flushTasks()
        result.push({
          kind: "image",
          source: image.source,
          alt: image.alt,
          size: image,
          line: i
        })
        i += 1
        continue
      }
      var task = fenced[i] ? null : MarkdownFormat.parseTaskLine(lines[i])
      if (task) {
        flushText()
        tasks.push({
          checked: task.checked,
          content: task.content,
          indent: task.indent,
          line: i
        })
        i += 1
        continue
      }
      flushTasks()
      buffer.push(lines[i])
      i += 1
    }
    flushText()
    flushTasks()
    return result
  }

  // Mark every line that belongs to a fenced code block, including the
  // opening and closing fences. Tilde and backtick fences only close against a
  // fence of the same character and at least the same length.
  function markFences(lines) {
    var mask = []
    var fence = ""
    for (var i = 0; i < lines.length; i++) {
      var trimmed = String(lines[i] === undefined ? "" : lines[i]).replace(/^[ \t]+/, "")
      var match = /^(`{3,}|~{3,})/.exec(trimmed)
      if (fence === "") {
        mask[i] = !!match
        if (match) fence = match[1]
        continue
      }
      mask[i] = true
      if (match && match[1].charAt(0) === fence.charAt(0)
          && match[1].length >= fence.length) {
        fence = ""
      }
    }
    return mask
  }

  readonly property real tableRowHeight: Style.space(28)
  readonly property real tableScrollBarHeight: Style.space(6)
  // Reserved strip between the table viewport and the frame border.
  readonly property real tableScrollBarSpace: Style.space(7)

  function tableWidthsFor(model, available) {
    if (!model) return []
    var values = TableEngine.computeTable(model)
    var columns = model.header.length
    var widths = []
    var total = 0
    var average = tableMetrics.averageCharacterWidth
    if (!average || average <= 0) average = 7
    for (var c = 0; c < columns; c++) {
      var longest = String(model.header[c] || "").length
      for (var r = 0; r < values.length; r++) {
        var cell = values[r][c]
        longest = Math.max(longest, String(cell ? cell.display : "").length)
      }
      var width = Math.ceil(longest * average * 1.08) + Style.space(20)
      width = Math.max(Style.space(70), Math.min(Style.space(300), width))
      widths.push(width)
      total += width
    }
    var pane = Math.max(Style.space(80), Math.floor(available))
    if (columns > 0 && total < pane) {
      var extra = Math.floor((pane - total) / columns)
      for (var j = 0; j < columns; j++) widths[j] += extra
    }
    return widths
  }

  function tableWidthFor(widths) {
    var total = 0
    for (var i = 0; i < widths.length; i++) total += widths[i]
    return total
  }

  function tableCellText(table, values, row, column) {
    if (!table) return ""
    if (row < 0) return String(table.header[column] || "")
    var line = values[row]
    if (!line || !line[column]) return ""
    return String(line[column].display)
  }

  function tableAlignment(table, column) {
    if (!table || !table.aligns) return "left"
    return table.aligns[column] || "left"
  }

  function horizontalFor(alignment) {
    if (alignment === "right") return Text.AlignRight
    if (alignment === "center") return Text.AlignHCenter
    return Text.AlignLeft
  }

  function setLiveWidth(line, width) {
    var value = Math.round(Number(width))
    if (!isFinite(value)) return
    value = Math.max(60, Math.min(maxContentWidth(), value))
    var next = {}
    for (var key in overrides) next[key] = overrides[key]
    next[line] = value
    overrides = next
    pendingLine = line
    pendingWidth = value
    // A drag commits on release; the wheel uses the idle timer.
    if (!root.dragging) commitTimer.restart()
  }

  function beginDrag(line) {
    dragging = true
    commitTimer.stop()
    pendingLine = line
  }

  function endDrag(line) {
    dragging = false
    if (pendingWidth <= 0) return
    var width = pendingWidth
    pendingWidth = -1
    pendingLine = -1
    commitTimer.stop()
    imageResized(line + root.lineOffset, width)
  }

  function commitLiveWidth() {
    if (pendingWidth <= 0 || pendingLine < 0) return
    var line = pendingLine
    var width = pendingWidth
    pendingLine = -1
    pendingWidth = -1
    imageResized(line + root.lineOffset, width)
  }

  function resetImage(line) {
    commitTimer.stop()
    pendingLine = -1
    pendingWidth = -1
    var next = {}
    for (var key in overrides) next[key] = overrides[key]
    delete next[line]
    overrides = next
    imageReset(line + root.lineOffset)
  }

  Timer {
    id: commitTimer
    interval: 400
    onTriggered: root.commitLiveWidth()
  }

  onMarkdownChanged: {
    root.taskOverrides = ({})
    if (root.dragging) return
    root.overrides = ({})
    root.pendingLine = -1
    root.pendingWidth = -1
    commitTimer.stop()
  }

  FontMetrics {
    id: tableMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // Resolver passed to MathText.toHtml. Null means "not rendered yet", which
  // makes the converter keep the raw $tex$ visible.
  function mathResolver(tex, display) {
    var result = mathService.get(String(tex || ""), display === undefined ? false : display)
    if (!result || !result.ok) return null
    return { ok: true, path: String(result.path || "") }
  }

  MathService {
    id: mathService
  }

  onBlocksChanged: mathService.prefetch(blocks)
  Component.onCompleted: mathService.prefetch(blocks)

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.leftMargin: Style.space(14)
    anchors.rightMargin: Style.space(8)
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    clip: true
    contentWidth: width
    contentHeight: column.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    Column {
      id: column
      width: flick.width
      spacing: Style.space(10)

      Repeater {
        model: root.blocks

        delegate: Item {
          id: blockItem
          width: flick.width
          height: blockItem.isTable ? tableFrame.height
            : blockItem.isImage ? imageFrame.height
            : blockItem.isMath ? mathFrame.height
            : blockItem.isTasks ? tasksColumn.implicitHeight : textBlock.implicitHeight

          readonly property bool isImage: modelData.kind === "image"
          readonly property bool isTable: modelData.kind === "table"
          readonly property bool isMath: modelData.kind === "math"
          readonly property bool isTasks: modelData.kind === "tasks"
          readonly property bool isText: !isImage && !isTable && !isMath && !isTasks
          readonly property bool interactive: root.editable && isImage
          readonly property var size: isImage ? modelData.size : null
          readonly property bool hasSize: !!(blockItem.size && blockItem.size.hasSize)
          readonly property int sourceLine: isImage ? modelData.line : -1
          readonly property var tableData: isTable ? modelData.table : null
          readonly property var tableValues: isTable ? TableEngine.computeTable(modelData.table) : []
          readonly property var tableWidths: isTable ? root.tableWidthsFor(modelData.table, blockItem.width) : []
          readonly property real tableNaturalWidth: isTable ? root.tableWidthFor(blockItem.tableWidths) : 0
          readonly property bool tableOverflow: isTable
            && tableNaturalWidth > blockItem.width + 0.5
          readonly property int tableRowCount: isTable && modelData.table ? modelData.table.rows.length + 1 : 0
          readonly property int tableColumnCount: isTable && modelData.table ? modelData.table.header.length : 0
          readonly property real overrideWidth: isImage && root.overrides[sourceLine] !== undefined
            ? root.overrides[sourceLine] : -1
          readonly property real paneWidth: Math.max(60, Math.floor(flick.width))
          readonly property real maxContentWidth: Math.max(60, paneWidth - 2)
          readonly property real ratio: imageItem.status === Image.Ready
            && imageItem.implicitWidth > 0 && imageItem.implicitHeight > 0
            ? imageItem.implicitWidth / imageItem.implicitHeight : 0
          readonly property var display: {
            if (!isImage) return null
            if (overrideWidth > 0) {
              var w = Math.max(60, Math.min(maxContentWidth, overrideWidth))
              return { mode: "width", width: w, height: ratio > 0 ? w / ratio : 0 }
            }
            return ImageSizing.displayFor(blockItem.size, maxContentWidth, ratio)
          }
          readonly property bool sized: display !== null
          readonly property real imageWidth: {
            if (!sized) return maxContentWidth
            if (display.width > 0) return Math.min(maxContentWidth, display.width)
            // Height-only while the image is still decoding: show a placeholder
            // box until the aspect ratio is known.
            return Math.min(Style.space(240), maxContentWidth)
          }
          readonly property real imageHeight: {
            if (!sized) {
              // Exactly the pre-existing default: natural height capped at 420.
              return imageItem.status === Image.Ready && imageItem.implicitHeight > 0
                ? Math.min(Style.space(420), imageItem.implicitHeight)
                : Style.space(120)
            }
            return display.height > 0 ? display.height : Style.space(120)
          }

          // Text blocks without maths keep MarkdownText; a block with inline
          // maths is rendered as RichText so QML can baseline its SVGs.
          readonly property bool richText: isText
            && (MathSyntax.hasInlineMath(String(modelData.text || ""))
              || MathText.hasFormatting(String(modelData.text || "")))

          readonly property var mathResult: {
            // revision is the dependency: results arriving redraw the block.
            var revision = mathService.revision
            return isMath ? mathService.get(String(modelData.tex || ""), true) : null
          }
          readonly property bool mathReady: !!(mathResult && mathResult.ok)
          readonly property bool mathInvalid: mathReady && !!mathResult.invalid
          readonly property bool mathFailed: !!mathResult && !mathResult.ok
          readonly property real mathScale: mathImage.implicitWidth > 0
            && mathImage.implicitWidth > blockItem.maxContentWidth
            ? blockItem.maxContentWidth / mathImage.implicitWidth : 1
          readonly property real mathWidth: mathImage.status === Image.Ready
            ? Math.max(1, Math.round(mathImage.implicitWidth * mathScale))
            : Math.min(blockItem.maxContentWidth, Style.space(240))
          readonly property real mathHeight: mathImage.status === Image.Ready
            ? Math.max(1, Math.round(mathImage.implicitHeight * mathScale))
            : Style.space(36)

          Text {
            id: textBlock
            visible: blockItem.isText
            width: blockItem.width
            text: {
              if (!blockItem.isText) return ""
              if (!blockItem.richText) return String(modelData.text || "")
              // Read revision so the HTML rebuilds when an SVG lands.
              var revision = mathService.revision
              return MathText.toHtml(String(modelData.text || ""),
                root.mathResolver, MathSyntax)
            }
            textFormat: blockItem.richText ? Text.RichText : Text.MarkdownText
            wrapMode: Text.Wrap
            color: Commons.Color.foreground
            linkColor: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            lineHeight: 1.15
            onLinkActivated: function(link) { root.linkActivated(link) }
          }

          // ------------------------------------------------------- tasks
          // Consecutive task lines share one block. Only the checkbox hit
          // area toggles; the text keeps normal Markdown link handling.
          Column {
            id: tasksColumn
            objectName: "previewTasks"
            visible: blockItem.isTasks
            width: blockItem.isTasks ? blockItem.width : 0
            spacing: Style.space(3)

            Repeater {
              model: blockItem.isTasks ? modelData.items : []

              delegate: Item {
                id: taskRow
                objectName: "previewTaskRow"
                width: tasksColumn.width
                height: Math.max(taskLabel.implicitHeight, Style.space(15))

                readonly property real indent: Math.min(8,
                  Math.floor(Number(modelData.indent) / 2)) * Style.space(10)
                readonly property int noteLine: Number(modelData.line) + root.lineOffset
                readonly property bool checked: {
                  var value = root.taskOverrides[noteLine]
                  return value === undefined ? !!modelData.checked : !!value
                }
                readonly property real boxSize: Style.space(13)
                readonly property real boxY: Math.max(0,
                  (Math.max(boxSize, Math.ceil(Style.font.body * 1.15)) - boxSize) / 2)

                Rectangle {
                  id: taskBox
                  objectName: "previewTaskBox"
                  x: taskRow.indent
                  y: taskRow.boxY
                  width: taskRow.boxSize
                  height: taskRow.boxSize
                  radius: Style.space(3)
                  color: taskRow.checked ? Commons.Color.accent : "transparent"
                  border.width: 1
                  border.color: taskRow.checked
                    ? Commons.Color.accent
                    : Util.alpha(Commons.Color.foreground,
                        root.editable && taskToggle.containsMouse ? 0.75 : 0.4)

                  Text {
                    anchors.centerIn: parent
                    visible: taskRow.checked
                    text: "✓"
                    textFormat: Text.PlainText
                    color: Commons.Color.background
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  id: taskLabel
                  objectName: "previewTaskLabel"
                  x: taskRow.indent + taskRow.boxSize + Style.space(8)
                  width: Math.max(0, taskRow.width - x)
                  text: blockItem.isTasks ? String(modelData.content || "") : ""
                  textFormat: Text.MarkdownText
                  wrapMode: Text.Wrap
                  color: Commons.Color.foreground
                  linkColor: Commons.Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  lineHeight: 1.15
                  onLinkActivated: function(link) { root.linkActivated(link) }
                }

                MouseArea {
                  id: taskToggle
                  objectName: "previewTaskToggle"
                  x: taskRow.indent + (taskRow.boxSize - Style.space(18)) / 2
                  y: taskRow.boxY + (taskRow.boxSize - Style.space(18)) / 2
                  width: Style.space(18)
                  height: Style.space(18)
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  cursorShape: root.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: {
                    if (!root.editable || !blockItem.isTasks) return
                    var next = {}
                    for (var key in root.taskOverrides) next[key] = root.taskOverrides[key]
                    next[taskRow.noteLine] = !taskRow.checked
                    root.taskOverrides = next
                    root.taskToggled(taskRow.noteLine)
                  }
                }
              }
            }
          }

          Rectangle {
            id: imageFrame
            visible: blockItem.isImage
            width: blockItem.isImage
              ? (blockItem.sized ? Math.min(blockItem.paneWidth, blockItem.imageWidth + 2) : blockItem.paneWidth)
              : 0
            height: blockItem.isImage
              ? (blockItem.sized ? blockItem.imageHeight + 2 : blockItem.imageHeight)
              : 0
            radius: Style.cornerRadius
            color: Util.alpha(Commons.Color.foreground, 0.03)
            border.width: 1
            border.color: Util.alpha(Commons.Color.foreground, 0.12)
            clip: true

            Image {
              id: imageItem
              // sourceSize keeps the decoded bitmap at pane width; it is not
              // tied to the drag width, so live resizing never re-decodes.
              x: 1
              y: 1
              width: Math.max(1, imageFrame.width - 2)
              height: blockItem.sized
                ? Math.max(1, imageFrame.height - 2)
                : blockItem.imageHeight
              asynchronous: true
              fillMode: Image.PreserveAspectFit
              source: blockItem.isImage ? String(modelData.source || "") : ""
              sourceSize.width: Math.max(1, Math.round(blockItem.paneWidth - 2))
            }

            Rectangle {
              anchors.fill: parent
              visible: imageItem.status !== Image.Ready
              radius: Style.cornerRadius
              color: Util.alpha(Commons.Color.foreground, 0.04)

              Text {
                anchors.centerIn: parent
                width: Math.max(0, parent.width - Style.space(24))
                horizontalAlignment: Text.AlignHCenter
                text: {
                  var alt = blockItem.isImage ? String(modelData.alt || "") : ""
                  if (alt.length > 0) return alt
                  return imageItem.status === Image.Error ? "Image not found" : "Loading image…"
                }
                color: Util.alpha(Commons.Color.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }

            MouseArea {
              id: frameMouse
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!blockItem.isImage) return
                if (blockItem.interactive) openTimer.restart()
                else root.openImage(String(modelData.source || ""))
              }
              onDoubleClicked: {
                if (!blockItem.interactive || !blockItem.hasSize) return
                openTimer.stop()
                root.resetImage(blockItem.sourceLine)
              }
            }

            WheelHandler {
              enabled: blockItem.interactive
              acceptedModifiers: Qt.ControlModifier
              onWheel: function(event) {
                var step = event.angleDelta.y > 0 ? 20 : event.angleDelta.y < 0 ? -20 : 0
                if (step === 0) return
                var base = blockItem.display && blockItem.display.width > 0
                  ? blockItem.display.width : blockItem.imageWidth
                var next = Math.min(blockItem.maxContentWidth, Math.max(60, base + step))
                if (Math.round(next) === Math.round(base)) return
                root.setLiveWidth(blockItem.sourceLine, next)
                event.accepted = true
              }
            }

            HoverHandler {
              id: imageHover
              enabled: blockItem.interactive
            }

            Timer {
              id: openTimer
              // Longer than the double-click interval so a double-click can
              // reset without the first click opening the image externally.
              interval: 450
              onTriggered: root.openImage(String(modelData.source || ""))
            }

            // Width badge, shown while hovering or resizing.
            Rectangle {
              id: sizeBadge
              visible: blockItem.interactive && (imageHover.hovered || dragArea.pressed)
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.rightMargin: Style.space(20)
              anchors.bottomMargin: Style.space(4)
              height: sizeLabel.implicitHeight + Style.space(4)
              width: sizeLabel.implicitWidth + Style.space(10)
              radius: Style.space(3)
              color: Util.alpha(Commons.Color.background, 0.9)
              border.width: 1
              border.color: Util.alpha(Commons.Color.foreground, 0.16)

              Text {
                id: sizeLabel
                anchors.centerIn: parent
                text: Math.round(blockItem.imageWidth) + " px"
                color: Util.alpha(Commons.Color.foreground, 0.78)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Reset to the default fit width.
            Rectangle {
              id: fitBadge
              visible: blockItem.interactive && blockItem.hasSize
                && (imageHover.hovered || dragArea.pressed)
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              height: fitLabel.implicitHeight + Style.space(4)
              width: fitLabel.implicitWidth + Style.space(10)
              radius: Style.space(3)
              color: Util.alpha(Commons.Color.background, 0.9)
              border.width: 1
              border.color: Util.alpha(Commons.Color.foreground, 0.16)

              Text {
                id: fitLabel
                anchors.centerIn: parent
                text: "Fit"
                color: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.resetImage(blockItem.sourceLine)
              }
            }

            // Bottom-right drag handle. Scene coordinates keep the drag stable
            // while the frame itself grows and shrinks.
            Rectangle {
              id: dragHandle
              visible: blockItem.interactive && (imageHover.hovered || dragArea.pressed)
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              width: Style.space(13)
              height: Style.space(13)
              radius: Style.space(3)
              color: Util.alpha(Commons.Color.accent, dragArea.pressed ? 0.95 : 0.7)
              border.width: 1
              border.color: Util.alpha(Commons.Color.background, 0.55)

              // Two short diagonal ticks, drawn with theme foreground.
              Repeater {
                model: 2
                Rectangle {
                  width: Style.space(5)
                  height: 1
                  color: Util.alpha(Commons.Color.background, 0.85)
                  x: dragHandle.width - Style.space(4) - index * Style.space(3)
                  y: dragHandle.height - Style.space(5) - index * Style.space(3)
                  rotation: -45
                  transformOrigin: Item.Center
                }
              }

              MouseArea {
                id: dragArea
                anchors.fill: parent
                cursorShape: Qt.SizeHorCursor
                preventStealing: true
                property real pressSceneX: 0
                property real pressWidth: 0

                onPressed: function(mouse) {
                  pressSceneX = mouse.scenePosition.x
                  pressWidth = blockItem.imageWidth
                  root.beginDrag(blockItem.sourceLine)
                  root.setLiveWidth(blockItem.sourceLine, pressWidth)
                }
                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  root.setLiveWidth(blockItem.sourceLine,
                    pressWidth + (mouse.scenePosition.x - pressSceneX))
                }
                onReleased: function(mouse) {
                  root.setLiveWidth(blockItem.sourceLine,
                    pressWidth + (mouse.scenePosition.x - pressSceneX))
                  root.endDrag(blockItem.sourceLine)
                }
                onCanceled: root.endDrag(blockItem.sourceLine)
              }
            }
          }

          // ------------------------------------------------------- maths
          // Centred, aspect-preserving display formula. No resize handles:
          // the source Markdown never carries a maths size.
          Item {
            id: mathFrame
            visible: blockItem.isMath
            width: blockItem.isMath ? blockItem.width : 0
            height: blockItem.isMath
              ? (blockItem.mathReady
                  ? blockItem.mathHeight + Style.space(8)
                  : mathFallbackLabel.implicitHeight + Style.space(12))
              : 0

            Rectangle {
              visible: blockItem.isMath && blockItem.mathReady
              width: blockItem.mathWidth
              height: blockItem.mathHeight
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              color: "transparent"
              radius: Style.space(2)
              border.width: blockItem.mathInvalid ? 1 : 0
              border.color: Util.alpha(Commons.Color.urgent, 0.5)

              Image {
                id: mathImage
                anchors.fill: parent
                source: blockItem.mathReady
                  ? "file://" + String(blockItem.mathResult.path || "") : ""
                asynchronous: true
                fillMode: Image.PreserveAspectFit
              }
            }

            // Pending or failed: keep the TeX visible instead of a blank gap.
            Rectangle {
              id: mathFallback
              visible: blockItem.isMath && !blockItem.mathReady
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: mathFallbackLabel.implicitHeight + Style.space(8)
              radius: Style.space(3)
              color: blockItem.mathFailed
                ? Util.alpha(Commons.Color.urgent, 0.06)
                : Util.alpha(Commons.Color.foreground, 0.04)
              border.width: 1
              border.color: blockItem.mathFailed
                ? Util.alpha(Commons.Color.urgent, 0.32)
                : Util.alpha(Commons.Color.foreground, 0.1)

              Text {
                id: mathFallbackLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: blockItem.isMath
                  ? "$$" + String(modelData.tex || "") + "$$" : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: blockItem.mathFailed
                  ? Util.alpha(Commons.Color.urgent, 0.85)
                  : Util.alpha(Commons.Color.foreground, 0.45)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ------------------------------------------------------- table
          Rectangle {
            id: tableFrame
            visible: blockItem.isTable
            width: blockItem.isTable ? blockItem.width : 0
            height: blockItem.isTable
              ? root.tableRowHeight * blockItem.tableRowCount + 2
                + (blockItem.tableOverflow ? root.tableScrollBarSpace : 0)
              : 0
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: Util.alpha(Commons.Color.foreground, 0.12)
            clip: true

            Item {
              id: tableBarSlot
              objectName: "previewTableBarSlot"
              visible: blockItem.tableOverflow
              x: 1
              y: tableFrame.height - height - 1
              width: Math.max(0, tableFrame.width - 2)
              height: root.tableScrollBarHeight
            }

            Flickable {
              id: tableScroll
              anchors.fill: parent
              anchors.margins: 1
              anchors.bottomMargin: 1
                + (blockItem.tableOverflow ? root.tableScrollBarSpace : 0)
              clip: true
              contentWidth: Math.max(width, tableInner.width)
              contentHeight: height
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentWidth > width

              ScrollBar.horizontal: ScrollBar {
                id: previewTableBar
                objectName: "previewTableScrollBar"
                // The bar lives in the reserved strip below the viewport, so it
                // never draws over the last row. Reparenting keeps the
                // Flickable's automatic size/position binding.
                parent: tableBarSlot
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: root.tableScrollBarHeight
                orientation: Qt.Horizontal
                policy: ScrollBar.AsNeeded
                visible: blockItem.tableOverflow
                padding: 0
                focusPolicy: Qt.NoFocus

                contentItem: Rectangle {
                  implicitHeight: Style.space(3)
                  radius: height / 2
                  color: previewTableBar.pressed
                    ? Commons.Color.accent
                    : Util.alpha(Commons.Color.foreground, 0.42)
                  opacity: previewTableBar.pressed || previewTableBar.active ? 1 : 0.72
                }

                background: Rectangle {
                  color: Util.alpha(Commons.Color.foreground, 0.05)
                  radius: height / 2
                }
              }

              WheelHandler {
                onWheel: function(event) {
                  if ((event.modifiers & Qt.ShiftModifier) !== 0 && event.angleDelta.y !== 0) {
                    tableScroll.contentX = Math.max(0, Math.min(
                      tableScroll.contentWidth - tableScroll.width,
                      tableScroll.contentX - event.angleDelta.y))
                    event.accepted = true
                  }
                }
              }

              Column {
                id: tableInner
                width: Math.max(tableScroll.width, blockItem.tableNaturalWidth)
                spacing: 0

                Repeater {
                  model: blockItem.tableRowCount

                  delegate: Item {
                    id: tableRow
                    width: tableInner.width
                    height: root.tableRowHeight
                    readonly property bool headerRow: index === 0
                    readonly property int bodyRow: index - 1

                    Rectangle {
                      anchors.fill: parent
                      color: tableRow.headerRow
                        ? Util.alpha(Commons.Color.foreground, 0.07)
                        : index % 2 === 1
                          ? Util.alpha(Commons.Color.foreground, 0.03)
                          : "transparent"
                    }

                    Row {
                      anchors.fill: parent

                      Repeater {
                        model: blockItem.tableColumnCount

                        delegate: Item {
                          id: tableCell
                          property int column: index
                          width: blockItem.tableWidths.length > column
                            ? blockItem.tableWidths[column] : Style.space(70)
                          height: tableRow.height

                          readonly property var cell: !tableRow.headerRow
                            && blockItem.tableValues[tableRow.bodyRow]
                            ? blockItem.tableValues[tableRow.bodyRow][column] : null
                          readonly property bool cellError: !!cell && cell.error !== null
                          readonly property bool cellFormula: !!cell
                            && String(cell.raw).charAt(0) === "="
                          readonly property bool cellNumeric: !!cell
                            && typeof cell.value === "number"
                          readonly property string align: root.tableAlignment(blockItem.tableData, column)
                          readonly property string value: root.tableCellText(
                            blockItem.tableData, blockItem.tableValues, tableRow.bodyRow, column)

                          Rectangle {
                            anchors.fill: parent
                            color: tableCell.cellFormula
                              ? Util.alpha(Commons.Color.accent, 0.055)
                              : "transparent"
                          }

                          Text {
                            x: Style.space(8) + (tableCell.cellFormula ? Style.space(11) : 0)
                            width: Math.max(0, parent.width - x - Style.space(6))
                            anchors.verticalCenter: parent.verticalCenter
                            text: tableCell.value
                            textFormat: Text.PlainText
                            color: tableCell.cellError
                              ? Commons.Color.urgent
                              : tableRow.headerRow
                                ? Commons.Color.foreground
                                : Util.alpha(Commons.Color.foreground, 0.9)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: tableRow.headerRow
                            horizontalAlignment: tableCell.cellNumeric
                              ? Text.AlignRight
                              : root.horizontalFor(tableCell.align)
                            elide: Text.ElideRight
                            wrapMode: Text.NoWrap
                          }

                          Text {
                            visible: tableCell.cellFormula
                            x: Style.space(3)
                            anchors.verticalCenter: parent.verticalCenter
                            text: "ƒ"
                            textFormat: Text.PlainText
                            color: Util.alpha(Commons.Color.accent, 0.72)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                          }

                          Rectangle {
                            width: 1
                            height: parent.height
                            anchors.right: parent.right
                            color: Util.alpha(Commons.Color.foreground, 0.12)
                          }
                        }
                      }
                    }

                    Rectangle {
                      width: parent.width
                      height: 1
                      anchors.bottom: parent.bottom
                      color: Util.alpha(Commons.Color.foreground, 0.12)
                    }
                  }
                }
              }
            }

            // Clicking anywhere on the table opens the grid. Stop above the
            // reserved scroll-bar strip: this MouseArea is declared last, so
            // without the margin it swallows every press on the bar and opens
            // the grid instead of scrolling.
            MouseArea {
              id: tableMouse
              objectName: "previewTableMouse"
              anchors.fill: parent
              anchors.bottomMargin: 1
                + (blockItem.tableOverflow ? root.tableScrollBarSpace : 0)
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              cursorShape: root.editable && root.tableEditing
                ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                if (!root.editable || !root.tableEditing) return
                root.tableActivated(
                  modelData.startLine + root.lineOffset,
                  modelData.endLine + root.lineOffset)
              }
            }

            Rectangle {
              id: tableBadge
              visible: tableMouse.containsMouse
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              height: tableBadgeLabel.implicitHeight + Style.space(4)
              width: tableBadgeLabel.implicitWidth + Style.space(10)
              radius: Style.space(3)
              color: Util.alpha(Commons.Color.background, 0.92)
              border.width: 1
              border.color: Util.alpha(Commons.Color.foreground, 0.16)
              z: 2

              Text {
                id: tableBadgeLabel
                anchors.centerIn: parent
                text: !root.editable
                  ? "Read-only"
                  : !root.tableEditing
                    ? "Open in the library to edit"
                    : "Grid"
                textFormat: Text.PlainText
                color: root.editable && root.tableEditing
                  ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  function openImage(source) {
    if (String(source || "").length === 0) return
    Qt.openUrlExternally("file://" + String(source))
  }

  Column {
    visible: !root.hasNote || root.tooLarge || (!root.loading && root.markdown === "")
    anchors.centerIn: parent
    width: parent.width - Style.space(40)
    spacing: Style.space(8)

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.tooLarge
        ? "This note is too large to preview"
        : root.loading
          ? "Loading preview…"
          : root.hasNote
            ? "Nothing to preview yet"
            : "Select a note to preview"
      color: Util.alpha(Commons.Color.foreground, 0.48)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
    Text {
      visible: root.hasNote && !root.tooLarge && !root.loading
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "Markdown renders after the note saves"
      color: Util.alpha(Commons.Color.foreground, 0.32)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  Rectangle {
    visible: root.dirty && root.hasNote
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    width: dirtyLabel.implicitWidth + Style.space(12)
    height: dirtyLabel.implicitHeight + Style.space(4)
    radius: Style.cornerRadius
    color: Util.alpha(Commons.Color.background, 0.82)
    border.width: 1
    border.color: Util.alpha(Commons.Color.foreground, 0.12)

    Text {
      id: dirtyLabel
      anchors.centerIn: parent
      text: "unsaved edits"
      color: Util.alpha(Commons.Color.foreground, 0.45)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
