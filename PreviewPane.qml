import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "FileUrls.js" as FileUrls
import "ImageSizing.js" as ImageSizing
import "TableEngine.js" as TableEngine
import "MathSyntax.js" as MathSyntax
import "MathText.js" as MathText
import "MarkdownFormat.js" as MarkdownFormat
import "PreviewBlocks.js" as PreviewBlocks
import "PreviewSync.js" as PreviewSync
import "CodeHighlight.js" as CodeHighlight
import "MarkdownExtras.js" as MarkdownExtras

// Rendered Markdown preview. Qt's GitHub-dialect Markdown renderer handles
// the text; Quill rewrites wiki links and inline tags into quill:// links in
// the backend first.
//
// Qt's Text.MarkdownText does not draw images or real tables, so the preview
// is split into blocks: contiguous text lines go to a read-only TextEdit so
// they can be selected and copied, image-only lines become Image blocks, and
// GFM tables become interactive table blocks, and fenced code, definition
// lists and the footnote section each get a block of their own so they render
// without Qt's MarkdownText (which has no highlighting, <dl> or footnotes).
// Headings, wiki links, tags and link activation still go through Qt's
// Markdown renderer.
//
// Display maths ($$…$$ / \[…\]) becomes its own centred Image block.
// A text block that contains inline maths, Quill formatting or links switches
// to RichText with MathText.js's HTML, because MarkdownText pins images to the
// text baseline and makes inline formulas float upwards, and TextEdit has no
// link colour of its own.
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
  // Plain text copied from the current preview selection.
  signal selectionCopied(string text)

  // Rendered prose and task labels are read-only TextEdits so they can be
  // selected with the mouse. Qt 6's plain Text item has no selection API.
  property string previewSelection: ""
  property string lastCopiedText: ""
  // The block that owns previewSelection, so moving to another block can
  // clear the old highlight without late selectedTextChanged signals
  // resurrecting stale text.
  property var selectionOwner: null
  // Overridable in offscreen probes; production writes to the Wayland
  // clipboard without a shell.
  property var clipboardWriter: function(text) {
    Quickshell.execDetached(["wl-copy", "--", String(text)])
  }

  // True only while focus is inside this preview. The library and detached
  // window share one PreviewPane each, so Ctrl+C reaches the editor untouched
  // whenever the editor owns focus.
  readonly property bool hasPreviewFocus: {
    var win = Window.window
    var item = win ? win.activeFocusItem : null
    while (item) {
      if (item === root) return true
      item = item.parent
    }
    return false
  }

  readonly property var blockDeps: ({
    image: ImageSizing,
    table: TableEngine,
    math: MathSyntax,
    format: MarkdownFormat,
    extras: MarkdownExtras
  })
  readonly property var blocks: PreviewBlocks.build(markdown, root.blockDeps)

  // Footnote lines are parsed once per markdown change: the block builder
  // hides the definitions, the inline converter needs the reference numbers,
  // and both must agree on which lines are definitions. Parsing failures fall
  // back to "no footnotes" rather than blanking the whole preview.
  readonly property var noteLines: String(markdown || "").split("\n")
  readonly property var footnoteState: {
    try {
      if (typeof MarkdownExtras.parseFootnotes !== "function") {
        return { definitions: [], skip: [] }
      }
      var parsed = MarkdownExtras.parseFootnotes(root.noteLines)
      return parsed || { definitions: [], skip: [] }
    } catch (error) {
      return { definitions: [], skip: [] }
    }
  }
  readonly property var footnoteNumbers: {
    try {
      if (typeof MarkdownExtras.footnoteNumbers !== "function") return ({})
      var counted = MarkdownExtras.footnoteNumbers(root.noteLines,
        root.footnoteState.definitions, root.footnoteState.skip)
      return counted && counted.numbers ? counted.numbers : ({})
    } catch (error) {
      return ({})
    }
  }

  // The footnotes block tracks its own y so a #fn- link can scroll the pane
  // to it; -1 means the note has no footnotes section.
  property real footnotesY: -1

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

  // A selectable block reports its selection here. Empty text for the owning
  // block means the highlight was cleared; a non-empty value from a new block
  // drops the previous block's highlight first.
  function trackSelection(source, text) {
    var value = String(text === undefined || text === null ? "" : text)
    if (value.length === 0) {
      if (selectionOwner === source) {
        selectionOwner = null
        previewSelection = ""
      }
      return
    }
    if (selectionOwner !== source) {
      var previous = selectionOwner
      selectionOwner = null
      if (previous && typeof previous.deselect === "function") previous.deselect()
    }
    selectionOwner = source
    previewSelection = value
  }

  function clearPreviewSelection() {
    var previous = selectionOwner
    selectionOwner = null
    previewSelection = ""
    if (previous && typeof previous.deselect === "function") previous.deselect()
  }

  function copySelection() {
    var value = String(previewSelection || "")
    if (value.length === 0) return false
    clipboardWriter(value)
    lastCopiedText = value
    selectionCopied(value)
    return true
  }

  // TextEdit paints anchors with its own default blue, so link-bearing blocks
  // go through the HTML converter and get the theme accent inline.
  function hasMarkdownLink(value) {
    return PreviewBlocks.hasMarkdownLink(value)
  }

  function previewHtml(value) {
    // The options are what make RichText blocks agree with the block builder:
    // fenced code inside a quote gets the same highlighter, and [^label] gets
    // the number assigned from first reference in the note.
    var html = MathText.toHtml(String(value === undefined || value === null ? "" : value),
      root.mathResolver, MathSyntax, {
        highlight: CodeHighlight,
        palette: root.codePalette,
        footnotes: { numbers: root.footnoteNumbers }
      })
    return html.replace(/<a href="/g, '<a style="color:' + String(Commons.Color.accent) + '" href="')
  }

  // Qt RichText is unreliable with QML colour objects and with #aarrggbb:
  // a theme colour can arrive with an alpha channel that the highlighter
  // copies verbatim into an inline style. Flattening to #rrggbb keeps the
  // palette opaque and lets the frame's own background show through.
  function hexColour(colour) {
    function channel(value) {
      var amount = Number(value)
      if (!isFinite(amount)) amount = 0
      var byte = Math.round(Math.max(0, Math.min(1, amount)) * 255)
      var hex = byte.toString(16)
      return hex.length === 1 ? "0" + hex : hex
    }
    return "#" + channel(colour.r) + channel(colour.g) + channel(colour.b)
  }

  // Code colours are derived from the theme rather than hard-coded, so a
  // light or dark theme both keep contrast. Blending toward the background
  // dims a full accent/foreground down the way comments and punctuation
  // should read, without needing a second theme colour for every class.
  function blendColour(colour, amount) {
    var mix = Math.max(0, Math.min(1, Number(amount)))
    if (!isFinite(mix)) mix = 0
    var background = Commons.Color.background
    return root.hexColour(Qt.rgba(
      colour.r + (background.r - colour.r) * mix,
      colour.g + (background.g - colour.g) * mix,
      colour.b + (background.b - colour.b) * mix,
      1))
  }

  readonly property var codePalette: ({
    comment: root.blendColour(Commons.Color.foreground, 0.55),
    keyword: root.hexColour(Commons.Color.accent),
    string: root.hexColour(Commons.Color.urgent),
    number: root.hexColour(Commons.Color.foreground),
    literal: root.hexColour(Commons.Color.foreground),
    function: root.hexColour(Commons.Color.foreground),
    type: root.blendColour(Commons.Color.accent, 0.35),
    tag: root.hexColour(Commons.Color.accent),
    attribute: root.blendColour(Commons.Color.foreground, 0.2),
    punctuation: root.blendColour(Commons.Color.foreground, 0.45),
    // Qt RichText gives <kbd> no default look, so MathText draws a key cap.
    // Deriving both colours from the theme keeps the chip legible on dark and
    // light backgrounds; 0.86 leaves a faint but visible fill.
    kbdBackground: root.blendColour(Commons.Color.foreground, 0.86),
    kbdText: root.hexColour(Commons.Color.foreground)
  })

  // Footnote references are anchors inside a RichText block, which only knows
  // the (block-relative) content position, so the pane scrolls to the block's
  // y instead. Clamped so the section can end flush with the bottom edge.
  function scrollToFootnotes() {
    if (root.footnotesY < 0) return
    var maxY = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(maxY, root.footnotesY))
  }

  // Every selectable block routes link clicks here. A click can leave a word
  // selected without emitting selectedTextChanged, so the source is cleared
  // first; footnote anchors are internal jumps, everything else is a library
  // link and must never reach the library as a bare "#fn-" URL.
  function handleLink(link, source) {
    if (source && typeof source.deselect === "function") source.deselect()
    root.trackSelection(source, "")
    if (String(link).indexOf("#fn-") === 0) {
      root.scrollToFootnotes()
      return
    }
    root.linkActivated(link)
  }

  readonly property real tableRowHeight: Style.space(28)
  readonly property real tableScrollBarHeight: Style.space(6)
  // Reserved strip between the table viewport and the frame border.
  readonly property real tableScrollBarSpace: Style.space(7)

  // Linked scrolling with the editor in split mode. The library reads the
  // ratio, or drives it through scrollToRatio(); the signal lets it react to a
  // wheel/drag in the preview without listening to an internal id.
  signal scrolled()
  readonly property real scrollMax: Math.max(0, flick.contentHeight - flick.height)
  readonly property real scrollRatio: scrollMax > 0 ? flick.contentY / scrollMax : 0

  function scrollToRatio(value) {
    var ratio = Math.max(0, Math.min(1, Number(value) || 0))
    if (scrollMax <= 0) return
    flick.contentY = ratio * scrollMax
  }

  // Linked scrolling by source line. Each block records the lines it renders
  // and the Repeater exposes its items, so a line can be turned into a pixel
  // offset and back. The list rebuilds whenever a block's layout changes.
  readonly property var lineAnchors: {
    var output = []
    var count = Math.min(root.blocks.length, blockRepeater.count)
    for (var i = 0; i < count; i++) {
      var block = root.blocks[i]
      var item = blockRepeater.itemAt(i)
      if (!item) continue
      var start = Number(block.startLine !== undefined ? block.startLine : block.line)
      var end = Number(block.endLine !== undefined ? block.endLine : start)
      if (!isFinite(start) || start < 0) continue
      if (!isFinite(end) || end < start) end = start
      output.push({
        line: start + root.lineOffset,
        endLine: end + root.lineOffset,
        y: item.y,
        height: item.height
      })
    }
    return output
  }

  // The source line at the top of the viewport.
  readonly property real topLine: PreviewSync.lineForY(root.lineAnchors, flick.contentY)

  function scrollToLine(line) {
    flick.contentY = Math.max(0, Math.min(root.scrollMax,
      PreviewSync.yForLine(root.lineAnchors, Number(line) || 0)))
  }

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
    // The delegates are rebuilt for the new body; a selection from the old
    // render must never be copyable, and its highlight should disappear too.
    root.clearPreviewSelection()
    root.taskOverrides = ({})
    root.footnotesY = -1
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

  // MathService scans text and maths blocks, but definition-list terms and
  // footnote definitions are prose too. Flatten those into text-shaped entries
  // once per block rebuild so prefetch (and its theme reset) sees every
  // formula without teaching MathService about new block kinds.
  function mathPrefetchBlocks() {
    var output = []
    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i]
      if (!block) continue
      if (block.kind === "deflist" && block.block && block.block.groups) {
        var groups = block.block.groups
        for (var g = 0; g < groups.length; g++) {
          var text = [String(groups[g].term || "")]
          var definitions = groups[g].definitions || []
          for (var d = 0; d < definitions.length; d++) {
            text.push(String(definitions[d] || ""))
          }
          output.push({ kind: "text", text: text.join("\n") })
        }
      } else if (block.kind === "footnotes") {
        var items = block.items || []
        for (var n = 0; n < items.length; n++) {
          output.push({ kind: "text", text: String(items[n].text || "") })
        }
      } else {
        output.push(block)
      }
    }
    return output
  }

  MathService {
    id: mathService
  }

  onBlocksChanged: mathService.prefetch(root.mathPrefetchBlocks())
  Component.onCompleted: mathService.prefetch(root.mathPrefetchBlocks())

  Flickable {
    id: flick
    objectName: "previewFlick"
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
    onContentYChanged: root.scrolled()

    Column {
      id: column
      width: flick.width
      spacing: Style.space(10)

      Repeater {
        id: blockRepeater
        model: root.blocks

        delegate: Item {
          id: blockItem
          width: flick.width
          height: blockItem.isTable ? tableFrame.height
            : blockItem.isImage ? imageFrame.height
            : blockItem.isMath ? mathFrame.height
            : blockItem.isTasks ? tasksColumn.implicitHeight
            : blockItem.isCode ? codeFrame.height
            : blockItem.isDeflist ? deflistColumn.implicitHeight
            : blockItem.isFootnotes ? footnotesColumn.implicitHeight
            : textBlock.implicitHeight

          readonly property bool isImage: modelData.kind === "image"
          readonly property bool isTable: modelData.kind === "table"
          readonly property bool isMath: modelData.kind === "math"
          readonly property bool isTasks: modelData.kind === "tasks"
          readonly property bool isCode: modelData.kind === "code"
          readonly property bool isDeflist: modelData.kind === "deflist"
          readonly property bool isFootnotes: modelData.kind === "footnotes"
          readonly property bool isText: !isImage && !isTable && !isMath && !isTasks
            && !isCode && !isDeflist && !isFootnotes

          // The footnote section is the scroll target for #fn- links. Its y is
          // in flick content coordinates, which is what contentY expects. The
          // initial y is laid out by the Column without emitting yChanged, so
          // completion also records it; later reflows still arrive here.
          onYChanged: if (blockItem.isFootnotes) root.footnotesY = blockItem.y
          Component.onCompleted: if (blockItem.isFootnotes) root.footnotesY = blockItem.y
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
          // Footnote references need RichText too, or [^note] prints literally.
          readonly property bool richText: isText
            && (MathSyntax.hasInlineMath(String(modelData.text || ""))
              || MathText.hasFormatting(String(modelData.text || ""))
              || root.hasMarkdownLink(String(modelData.text || ""))
              || MarkdownExtras.hasFootnoteRefs(String(modelData.text || "")))

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

          // TextEdit has no lineHeight property; QTextDocument's default
          // leading replaces the 1.15 spacing the old Text block used.
          TextEdit {
            id: textBlock
            objectName: "previewText"
            visible: blockItem.isText
            width: blockItem.width
            text: {
              if (!blockItem.isText) return ""
              if (!blockItem.richText) return String(modelData.text || "")
              // Read revision so the HTML rebuilds when an SVG lands.
              var revision = mathService.revision
              return root.previewHtml(String(modelData.text || ""))
            }
            textFormat: blockItem.richText ? TextEdit.RichText : TextEdit.MarkdownText
            wrapMode: TextEdit.Wrap
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            textMargin: 0
            readOnly: true
            selectByMouse: true
            activeFocusOnPress: true
            persistentSelection: false
            cursorVisible: false
            selectionColor: Util.alpha(Commons.Color.accent, 0.42)
            selectedTextColor: Commons.Color.foreground
            onSelectedTextChanged: root.trackSelection(textBlock, textBlock.selectedText)
            onLinkActivated: function(link) { root.handleLink(link, textBlock) }
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
                readonly property string labelText: blockItem.isTasks
                  ? String(modelData.content || "") : ""
                readonly property bool labelRich: root.hasMarkdownLink(labelText)

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

                TextEdit {
                  id: taskLabel
                  objectName: "previewTaskLabel"
                  x: taskRow.indent + taskRow.boxSize + Style.space(8)
                  width: Math.max(0, taskRow.width - x)
                  text: taskRow.labelRich
                    ? root.previewHtml(taskRow.labelText) : taskRow.labelText
                  textFormat: taskRow.labelRich
                    ? TextEdit.RichText : TextEdit.MarkdownText
                  wrapMode: TextEdit.Wrap
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  textMargin: 0
                  readOnly: true
                  selectByMouse: true
                  activeFocusOnPress: true
                  persistentSelection: false
                  cursorVisible: false
                  selectionColor: Util.alpha(Commons.Color.accent, 0.42)
                  selectedTextColor: Commons.Color.foreground
                  onSelectedTextChanged: root.trackSelection(taskLabel, taskLabel.selectedText)
                  onLinkActivated: function(link) { root.handleLink(link, taskLabel) }
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

          // ------------------------------------------------------- code
          // Fenced code is never Markdown: it keeps its whitespace and gets
          // the theme-derived highlighter colours, so it needs its own frame
          // with a dim surface instead of a prose block.
          Rectangle {
            id: codeFrame
            objectName: "previewCode"
            visible: blockItem.isCode
            width: blockItem.isCode ? blockItem.width : 0
            height: blockItem.isCode ? codeBlock.implicitHeight + 2 : 0
            radius: Style.cornerRadius
            color: Util.alpha(Commons.Color.foreground, 0.035)
            border.width: 1
            border.color: Util.alpha(Commons.Color.foreground, 0.10)
            clip: true

            TextEdit {
              id: codeBlock
              objectName: "previewCodeText"
              x: 1
              y: 1
              width: Math.max(0, codeFrame.width - 2)
              text: blockItem.isCode
                ? "<pre style=\"margin:0\">" + CodeHighlight.toHtml(
                    String(modelData.code || ""), String(modelData.language || ""),
                    root.codePalette) + "</pre>"
                : ""
              textFormat: TextEdit.RichText
              wrapMode: TextEdit.Wrap
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textMargin: Style.space(8)
              readOnly: true
              selectByMouse: true
              activeFocusOnPress: true
              persistentSelection: false
              cursorVisible: false
              selectionColor: Util.alpha(Commons.Color.accent, 0.42)
              selectedTextColor: Commons.Color.foreground
              onSelectedTextChanged: root.trackSelection(codeBlock, codeBlock.selectedText)
              onLinkActivated: function(link) { root.handleLink(link, codeBlock) }
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
                  ? FileUrls.fileUrl(String(blockItem.mathResult.path || "")) : ""
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

          // ------------------------------------------------------- deflist
          // Qt's RichText engine flattens <dl>/<dt>/<dd> into one line, so
          // Pandoc-style pairs are laid out here: a bold term and indented
          // definitions, both selectable and link-aware.
          Column {
            id: deflistColumn
            objectName: "previewDeflist"
            visible: blockItem.isDeflist
            width: blockItem.isDeflist ? blockItem.width : 0
            spacing: Style.space(6)

            Repeater {
              model: blockItem.isDeflist ? modelData.block.groups : []

              delegate: Item {
                id: deflistGroup
                width: deflistColumn.width
                height: deflistGroupColumn.implicitHeight

                // A restrained rule ties a term to its definitions without
                // competing with the text; the 16px indent carries the
                // hierarchy on its own if a theme draws it too softly.
                Rectangle {
                  x: Style.space(6)
                  y: 0
                  width: 1
                  height: deflistGroup.height
                  color: Util.alpha(Commons.Color.foreground, 0.16)
                }

                Column {
                  id: deflistGroupColumn
                  x: Style.space(12)
                  width: Math.max(0, deflistGroup.width - Style.space(12))
                  spacing: Style.space(2)

                  TextEdit {
                    id: deflistTerm
                    objectName: "previewDeflistTerm"
                    width: deflistGroupColumn.width
                    text: root.previewHtml(String(modelData.term || ""))
                    textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    textMargin: 0
                    readOnly: true
                    selectByMouse: true
                    activeFocusOnPress: true
                    persistentSelection: false
                    cursorVisible: false
                    selectionColor: Util.alpha(Commons.Color.accent, 0.42)
                    selectedTextColor: Commons.Color.foreground
                    onSelectedTextChanged: root.trackSelection(deflistTerm, deflistTerm.selectedText)
                    onLinkActivated: function(link) { root.handleLink(link, deflistTerm) }
                  }

                  Repeater {
                    model: modelData.definitions

                    delegate: TextEdit {
                      id: deflistText
                      objectName: "previewDeflistText"
                      x: Style.space(16)
                      width: Math.max(0, deflistGroupColumn.width - Style.space(16))
                      text: root.previewHtml(String(modelData || ""))
                      textFormat: TextEdit.RichText
                      wrapMode: TextEdit.Wrap
                      color: Util.alpha(Commons.Color.foreground, 0.86)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      textMargin: 0
                      readOnly: true
                      selectByMouse: true
                      activeFocusOnPress: true
                      persistentSelection: false
                      cursorVisible: false
                      selectionColor: Util.alpha(Commons.Color.accent, 0.42)
                      selectedTextColor: Commons.Color.foreground
                      onSelectedTextChanged: root.trackSelection(deflistText, deflistText.selectedText)
                      onLinkActivated: function(link) { root.handleLink(link, deflistText) }
                    }
                  }
                }
              }
            }
          }

          // ---------------------------------------------------- footnotes
          // The section is one block at the end of the note, matching the
          // source order the block builder keeps. Qt RichText's <hr> spacing
          // is unreliable, so the boundary is a drawn hairline and the
          // converter emits entries only.
          Column {
            id: footnotesColumn
            objectName: "previewFootnotes"
            visible: blockItem.isFootnotes
            width: blockItem.isFootnotes ? blockItem.width : 0
            spacing: Style.space(6)

            Rectangle {
              width: footnotesColumn.width
              height: 1
              color: Util.alpha(Commons.Color.foreground, 0.12)
            }

            TextEdit {
              id: footnoteText
              objectName: "previewFootnoteText"
              width: footnotesColumn.width
              text: blockItem.isFootnotes
                ? MarkdownExtras.footnoteSectionHtml(modelData.items, function(value) {
                    return root.previewHtml(String(value || ""))
                  })
                : ""
              textFormat: TextEdit.RichText
              wrapMode: TextEdit.Wrap
              color: Util.alpha(Commons.Color.foreground, 0.72)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textMargin: 0
              readOnly: true
              selectByMouse: true
              activeFocusOnPress: true
              persistentSelection: false
              cursorVisible: false
              selectionColor: Util.alpha(Commons.Color.accent, 0.42)
              selectedTextColor: Commons.Color.foreground
              onSelectedTextChanged: root.trackSelection(footnoteText, footnoteText.selectedText)
              onLinkActivated: function(link) { root.handleLink(link, footnoteText) }
            }
          }
        }
      }
    }
  }

  // Only active while a preview block owns focus, so the editor keeps its own
  // Ctrl+C copy when the caret is there.
  Shortcut {
    objectName: "previewCopyShortcut"
    sequence: "Ctrl+C"
    enabled: root.hasPreviewFocus && root.previewSelection.length > 0
    onActivated: root.copySelection()
  }

  function openImage(source) {
    if (String(source || "").length === 0) return
    Qt.openUrlExternally(FileUrls.fileUrl(String(source)))
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
