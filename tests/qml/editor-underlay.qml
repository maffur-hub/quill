import QtQuick
import qs.Commons

// A click in a long note lands on the line above the one the user aimed at,
// and by more lines the further down the note it is. The syntax-highlight
// underlay painted every line a pixel above where the TextEdit advanced it,
// because it rounded the font height where TextEdit ceils it.
//
// The check compares the painted line geometry with the caret geometry, and
// with the font's own metrics, rather than a pixel constant: the drift is a
// per-line difference between two live calculations, so a hard-coded number
// would only prove the test machine's font size.
Item {
  id: test

  property var harness: null
  property var editor: null
  property var underlay: null
  property var starts: []
  property string sample: ""

  readonly property int lineCount: 60

  FontMetrics {
    id: fontMetrics
    // Before the editor exists the fallback keeps the size rule readable; the
    // assertion runs only after the editor is live.
    font: test.editor
      ? test.editor.font
      : Qt.font({ family: Style.font.family, pixelSize: Style.font.body })
  }

  Component {
    id: probeMetrics
    FontMetrics {}
  }

  // The editor normally draws at Style.font.body, but the drift only shows at
  // sizes whose font height does not round up to its own ceiling: where the
  // two agree, this case would pass with the rounding bug still in place. Walk
  // the app's own size tokens and use the first that tells them apart, so the
  // check keeps its teeth whatever family the harness resolves.
  function driftPixelSize() {
    var sizes = [Style.font.body, Style.font.bodySmall, Style.font.caption,
      Style.font.subtitle, Style.font.title, Style.font.heading]
    for (var i = 0; i < sizes.length; i++) {
      var probe = probeMetrics.createObject(test)
      if (!probe) continue
      probe.font = Qt.font({
        family: Style.font.family,
        pixelSize: sizes[i]
      })
      var differs = Math.ceil(probe.height) !== Math.round(probe.height)
      probe.destroy()
      if (differs) return sizes[i]
    }
    return Style.font.body
  }

  function collectByName(item, name, found, seen) {
    if (!item) return found
    if (!seen) seen = []
    // The walk reaches the same node through both `data` and `children`;
    // skipping what it has already seen keeps the walk linear.
    if (seen.indexOf(item) >= 0) return found
    seen.push(item)
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
    for (i = 0; i < kids.length; i++)
      test.collectByName(kids[i], name, found, seen)
    return found
  }

  function firstByName(name) {
    var found = collectByName(editor ? editor : test, name, [])
    return found.length > 0 ? found[0] : null
  }

  // Sixty short lines, one painted line each, with a heading near the top, a
  // second heading further down and an emoji surrounded by ordinary text. The
  // emoji-only line is deliberately absent: TextEdit shrinks that line to the
  // emoji font's metrics, which a single underlay height cannot follow.
  function buildSample() {
    var lines = []
    for (var i = 0; i < lineCount; i++) {
      if (i === 0) lines.push("# Heading one")
      else if (i === 12) lines.push("## Heading two")
      else if (i === 30) lines.push("A line with an emoji 😀 in it")
      else lines.push("source line " + i + " stays short")
    }
    var offset = 0
    for (var line = 0; line < lines.length; line++) {
      starts.push(offset)
      offset += lines[line].length + 1
    }
    return lines.join("\n")
  }

  function finish() {
    tick.stop()
    harness.done()
  }

  function fail(message) {
    harness.check("the editor underlay case completed", false, message)
    finish()
  }

  function start(h) {
    harness = h
    sample = buildSample()
    var component = Qt.createComponent(Qt.resolvedUrl("../../MarkdownEditor.qml"))
    if (component.status !== Component.Ready) {
      fail("component is not ready: " + component.errorString())
      return
    }
    editor = component.createObject(test, {
      width: 700,
      height: 900,
      text: sample,
      leftPadding: 10,
      rightPadding: 10,
      topPadding: 8,
      bottomPadding: 24,
      spellcheckEnabled: false
    })
    if (!editor) {
      fail("the editor could not be created")
      return
    }
    // The app's own typography: the library binds these properties on the
    // editor, so the case exercises the family the user actually reads.
    editor.font.family = Style.font.family
    editor.font.pixelSize = driftPixelSize()
    tick.start()
  }

  function verify() {
    underlay = firstByName("quillUnderlay")
    if (!underlay) {
      fail("no underlay in the editor's background")
      return
    }
    var lineHeight = underlay.lineHeight

    // The painted top of each line against the caret's top for the same
    // offset. Pre-fix the difference equals the line index: 40 px by line 40.
    var firstBad = -1
    var firstDelta = 0
    var worst = 0
    for (var i = 0; i < lineCount; i++) {
      var expected = editor.topPadding + i * lineHeight
      var delta = Math.abs(editor.positionToRectangle(starts[i]).y - expected)
      if (delta > worst) worst = delta
      if (delta >= 0.5 && firstBad < 0) {
        firstBad = i
        firstDelta = delta
      }
    }
    harness.check("every underlay line sits on the caret's line",
      firstBad < 0,
      firstBad < 0 ? "" : "line " + firstBad + " is " + firstDelta
        + "px off, worst " + worst + "px")

    harness.check("the underlay advances by the ceiling of the font height",
      lineHeight === Math.ceil(fontMetrics.height),
      "line height " + lineHeight + " vs font height " + fontMetrics.height)

    // The user's gesture: the middle of the forty-first line.
    var y = editor.topPadding + 40 * lineHeight + Math.floor(lineHeight / 2)
    var position = editor.positionAt(30, y)
    harness.check("a click inside line 40 lands on line 40",
      position >= starts[40] && position <= starts[41] + 1,
      "position " + position + " outside " + starts[40] + ".." + (starts[41] + 1))

    finish()
  }

  Timer {
    id: tick
    interval: 1000
    running: false
    onTriggered: test.verify()
  }
}
