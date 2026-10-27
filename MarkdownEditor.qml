import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MarkdownFormat.js" as MarkdownFormat

// Markdown editor with a syntax-highlighted underlay.
//
// The TextArea itself paints transparent glyphs and owns the caret,
// selection, IME and scrolling behaviour. A rich-text Text underneath paints
// the same lines with Markdown styling. Both use fixed line heights so
// wrapped lines stay caret-aligned even when a heading line uses a larger
// font size.
TextArea {
  id: root

  property color foregroundColor: Commons.Color.foreground
  property color accentColor: Commons.Color.accent
  property bool highlightingEnabled: true
  property string storePath: ""

  // Image paste: Ctrl+V asks scripts/quill-paste-image first. A normal text
  // paste happens when the clipboard has no image (or has text as well).
  property bool pastingImage: false
  property string pasteOutput: ""
  property string pasteError: ""

  // Replaces the stock white Qt text menu. Exposed for the e2e harness.
  readonly property var contextMenuRef: editorMenu
  T.ContextMenu.menu: editorMenu

  // A replacement edit becomes one native remove plus one native insert. Keep
  // the operation count so the toolbar's Undo/Redo can replay the whole
  // formatting action as a unit instead of stopping half-way.
  property bool suppressFormatHistory: false
  property int formatUndoSteps: 1
  property int formatRedoSteps: 1
  property bool formatUndoPending: false
  property bool formatRedoPending: false

  readonly property string pasteHelperPath: {
    var cut = storePath.lastIndexOf("/")
    return cut > 0 ? storePath.slice(0, cut) + "/quill-paste-image" : "quill-paste-image"
  }

  signal imagePasted(string path)
  signal pasteFailed(string message)
  signal linkRequested()
  signal noteLinkRequested()
  signal formatRejected(string message)

  readonly property bool richTextVisible: highlightingEnabled && text.length < 200000

  function alpha(colorValue, opacity) {
    if (!colorValue) return Qt.rgba(0, 0, 0, opacity)
    return Qt.rgba(colorValue.r, colorValue.g, colorValue.b, opacity)
  }

  function hexColor(colorValue) {
    function channel(value) {
      var output = Math.round(value * 255).toString(16)
      return output.length < 2 ? "0" + output : output
    }
    return "#" + channel(colorValue.r) + channel(colorValue.g) + channel(colorValue.b)
  }

  function rgbaColor(colorValue, opacity) {
    return "rgba(" + Math.round(colorValue.r * 255) + ","
      + Math.round(colorValue.g * 255) + ","
      + Math.round(colorValue.b * 255) + ","
      + Math.round(opacity * 100) / 100 + ")"
  }

  function escapeHtml(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\"/g, "&quot;")
  }

  function preserveIndent(value) {
    var match = String(value || "").match(/^[ \t]+/)
    if (!match) return value
    return match[0].replace(/\t/g, "    ").replace(/ /g, "&nbsp;") + value.slice(match[0].length)
  }

  // Accept both the rgb() form Joplin stores and older Quill hex spans;
  // Qt RichText renders either, but the underlay re-serialises as hex.
  function safeHtmlColour(value) {
    return MarkdownFormat.colourToHex(value)
  }

  function safeHtmlFontSize(value) {
    var match = String(value || "").trim().match(/^([0-9]+(?:\.[0-9]+)?)(%|em|px|pt)$/i)
    if (!match) return null
    var amount = Number(match[1])
    var unit = match[2].toLowerCase()
    if (!isFinite(amount) || amount <= 0) return null
    if (unit === "em") return amount >= 0.1 && amount <= 10 ? amount + unit : null
    return amount >= 1 && amount <= 400 ? amount + unit : null
  }

  function safeInlineSpanStyle(attributes) {
    var match = String(attributes || "").match(/^\s+style="([^"]*)"\s*$/i)
    if (!match) return null
    var props = []
    var parts = match[1].split(";")
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim()
      if (part === "") continue
      var colon = part.indexOf(":")
      if (colon < 1) return null
      var key = part.slice(0, colon).trim().toLowerCase()
      var value = part.slice(colon + 1).trim()
      if (key === "color") {
        var colour = safeHtmlColour(value)
        if (colour === null) return null
        props.push({ key: "color", value: colour })
      } else if (key === "font-size") {
        var size = safeHtmlFontSize(value)
        if (size === null) return null
        props.push({ key: "font-size", value: size })
      } else {
        return null
      }
    }
    return props.length === 0 ? null : props
  }

  function isInsideBackticks(source, index) {
    var count = 0
    for (var i = 0; i < index; i++) {
      if (source.charAt(i) === "`" && !isEscaped(source, i)) count += 1
    }
    return count % 2 === 1
  }

  function isEscaped(source, index) {
    var count = 0
    for (var i = index - 1; i >= 0 && source.charAt(i) === "\\"; i--) count += 1
    return count % 2 === 1
  }

  // Replace whitelisted inline HTML with private markers. The Markdown
  // tokenizer then works on the surrounding text and the markers are restored
  // as styled HTML (or dimmed tag text) at the end.
  function protectInlineHtml(source, muted, replacements) {
    var text = String(source || "")
    var tags = []
    var stack = []
    var regex = /<(\/?)(u|span|sup|sub)((?:\s+[^>]*)?)>/gi
    var match
    while ((match = regex.exec(text)) !== null) {
      if (isInsideBackticks(text, match.index)) continue
      var closing = match[1] === "/"
      var name = match[2].toLowerCase()
      var attrs = match[3] || ""
      if (!closing && name === "u" && attrs.trim() === "") {
        stack.push({ name: "u", start: match.index, end: regex.lastIndex, tag: match[0],
          open: true })
      } else if (!closing && name === "span") {
        var props = safeInlineSpanStyle(attrs)
        if (props === null) continue
        stack.push({ name: "span", start: match.index, end: regex.lastIndex, tag: match[0],
          props: props, open: true })
      } else if (closing && stack.length > 0 && stack[stack.length - 1].name === name) {
        var opened = stack.pop()
        opened.closing = { start: match.index, end: regex.lastIndex, tag: match[0] }
        tags.push(opened)
      }
    }
    if (tags.length === 0) return text
    var edits = []
    for (var t = 0; t < tags.length; t++) {
      var tag = tags[t]
      var dimOpen = '<span style="color:' + muted + ';">' + escapeHtml(tag.tag) + '</span>'
      var dimClose = '<span style="color:' + muted + ';">' + escapeHtml(tag.closing.tag) + '</span>'
      var openHtml = dimOpen
      var closeHtml = dimClose
      if (tag.name === "u") {
        openHtml += "<u>"
        closeHtml = "</u>" + closeHtml
      } else if (tag.name === "sup" || tag.name === "sub") {
        openHtml += "<" + tag.name + ">"
        closeHtml = "</" + tag.name + ">" + closeHtml
      } else if (tag.name === "span") {
        var colour = null
        for (var p = 0; p < tag.props.length; p++) {
          if (tag.props[p].key === "color") colour = tag.props[p].value
        }
        if (colour !== null) {
          openHtml += '<span style="color:' + colour + ';">'
          closeHtml = "</span>" + closeHtml
        }
      }
      var openMarker = "\uE200" + replacements.length + "\uE201"
      replacements.push(openHtml)
      var closeMarker = "\uE200" + replacements.length + "\uE201"
      replacements.push(closeHtml)
      edits.push({ start: tag.start, end: tag.end, text: openMarker })
      edits.push({ start: tag.closing.start, end: tag.closing.end, text: closeMarker })
    }
    edits.sort(function(a, b) { return b.start - a.start })
    var output = text
    for (var e = 0; e < edits.length; e++) {
      output = output.slice(0, edits[e].start) + edits[e].text + output.slice(edits[e].end)
    }
    return output
  }

  function restoreInlineHtml(value, replacements) {
    return String(value || "").replace(/\uE200([0-9]+)\uE201/g, function(match, index) {
      var entry = replacements[Number(index)]
      return entry === undefined ? "" : entry
    })
  }

  function headingSize(level) {
    // Kept for reference: headings used to be scaled up in the underlay, but a
    // TextArea can only have one font size, so scaled headings never matched
    // the caret or the selection height. Headings now share the body size and
    // are distinguished by weight and colour instead.
    var base = root.font.pixelSize > 0 ? root.font.pixelSize : 14
    return base
  }

  function inlineHtml(value) {
    var source = String(value || "")
    var replacements = []
    var accent = hexColor(accentColor)
    var muted = rgbaColor(foregroundColor, 0.52)
    var foreground = hexColor(foregroundColor)
    source = protectInlineHtml(source, muted, replacements)
    var tagPrefix = "(^|[\\s(\\[{>,;:.!?])"
    var pattern = new RegExp(
      "`[^`\\n]+`"
      + "|\\[\\[[^\\]\\n]+\\]\\]"
      + "|" + tagPrefix + "#[A-Za-z0-9_/-]+"
      + "|\\[[^\\]\\n]+\\]\\([^\\s()\\n]+\\)"
      + "|\\*\\*\\*(?!\\s)[^*\\n]*[^*\\s\\n]\\*\\*\\*"
      + "|___(?!\\s)[^_\\n]*[^_\\s\\n]___"
      + "|\\*\\*(?!\\s)[^*\\n]*[^*\\s\\n]\\*\\*"
      + "|__(?!\\s)[^_\\n]*[^_\\s\\n]__"
      + "|~~(?!\\s)[^~\\n]*[^~\\s\\n]~~"
      + "|==(?!\\s)[^=\\n]*[^=\\s\\n]=="
      + "|\\*(?!\\s)[^*\\n]*[^*\\s\\n]\\*"
      + "|_(?!\\s)[^_\\n]*[^_\\s\\n]_"
      + "|https?:\\/\\/[^\\s<>()]+",
      "g")

    var output = ""
    var cursor = 0
    var match
    while ((match = pattern.exec(source)) !== null) {
      var index = match.index
      var token = match[0]
      if (token.charAt(0) === "_" && index > 0 && /[A-Za-z0-9]/.test(source.charAt(index - 1))) {
        // Intraword underscores (`snake_case_name`) are not emphasis.
        output += escapeHtml(source.slice(cursor, index + 1))
        cursor = index + 1
        continue
      }
      output += escapeHtml(source.slice(cursor, index))
      var first = token.charAt(0)
      var hash = token.indexOf("#")

      if (first === "`") {
        output += "<span style=\"color:" + accent + ";\">" + escapeHtml(token) + "</span>"
      } else if (first === "[") {
        if (token.slice(0, 2) === "[[") {
          output += "<span style=\"color:" + accent + "; text-decoration:underline;\">"
            + escapeHtml(token) + "</span>"
        } else {
          var link = token.match(/^\[([^\]\n]+)\]\(([^\s()\n]+)\)$/)
          if (link) {
            output += "<span style=\"color:" + muted + ";\">[</span>"
              + "<span style=\"color:" + accent + "; text-decoration:underline;\">" + escapeHtml(link[1]) + "</span>"
              + "<span style=\"color:" + muted + ";\">](</span>"
              + "<span style=\"color:" + muted + ";\">" + escapeHtml(link[2]) + "</span>"
              + "<span style=\"color:" + muted + ";\">)</span>"
          } else {
            output += escapeHtml(token)
          }
        }
      } else if (first === "~") {
        output += "<span style=\"color:" + muted + ";\">~~</span><s>"
          + escapeHtml(token.slice(2, -2)) + "</s><span style=\"color:" + muted + ";\">~~</span>"
      } else if (first === "=" && token.slice(0, 2) === "==") {
        output += "<span style=\"color:" + muted + ";\">==</span>"
          + "<span style=\"background-color:#f5e663; color:#1f1f1f;\">"
          + escapeHtml(token.slice(2, -2)) + "</span>"
          + "<span style=\"color:" + muted + ";\">==</span>"
      } else if (first === "*" || first === "_") {
        var markerLength = (token.slice(0, 3) === "***" || token.slice(0, 3) === "___") ? 3
          : (token.slice(0, 2) === "**" || token.slice(0, 2) === "__") ? 2 : 1
        var inner = escapeHtml(token.slice(markerLength, -markerLength))
        var emphasis = markerLength === 3 ? "<b><i>" + inner + "</i></b>"
          : markerLength === 2 ? "<b>" + inner + "</b>" : "<i>" + inner + "</i>"
        output += "<span style=\"color:" + muted + ";\">" + escapeHtml(token.slice(0, markerLength)) + "</span>"
          + emphasis
          + "<span style=\"color:" + muted + ";\">" + escapeHtml(token.slice(-markerLength)) + "</span>"
      } else if (hash >= 0 && hash <= 1 && /^#[A-Za-z0-9_/-]+$/.test(token.slice(hash))) {
        // A tag token includes the whitespace/punctuation that introduced it.
        output += escapeHtml(token.slice(0, hash))
          + "<span style=\"color:" + accent + ";\">" + escapeHtml(token.slice(hash)) + "</span>"
      } else {
        var trailing = token.match(/[.,;:!?\]\}]+$/)
        var suffix = trailing ? trailing[0] : ""
        var url = suffix ? token.slice(0, -suffix.length) : token
        output += "<span style=\"color:" + accent + "; text-decoration:underline;\">"
          + escapeHtml(url) + "</span>" + escapeHtml(suffix)
      }
      cursor = index + token.length
    }
    output += escapeHtml(source.slice(cursor))
    return preserveIndent(restoreInlineHtml(output, replacements))
  }

  function highlightedMarkdown(value) {
    var lines = String(value || "").split("\n")
    var output = []
    var inCode = false
    var accent = hexColor(accentColor)
    var muted = rgbaColor(foregroundColor, 0.6)
    var foreground = hexColor(foregroundColor)

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var fence = line.match(/^(\s*)(```|~~~)/)
      if (fence) {
        output.push(preserveIndent(escapeHtml(fence[1]))
          + "<span style=\"color:" + accent + ";\">" + escapeHtml(line.slice(fence[1].length)) + "</span>")
        inCode = !inCode
        continue
      }
      if (inCode) {
        output.push("<span style=\"color:" + muted + ";\">" + preserveIndent(escapeHtml(line)) + "</span>")
        continue
      }

      var heading = line.match(/^(\s{0,3})(#{1,6})(\s+)(.*)$/)
      if (heading) {
        output.push(preserveIndent(escapeHtml(heading[1]))
          + "<span style=\"color:" + accent + ";\">" + escapeHtml(heading[2]) + "</span>"
          + escapeHtml(heading[3])
          + "<span style=\"color:" + foreground + "; font-weight:600;\">" + inlineHtml(heading[4]) + "</span>")
        continue
      }

      var task = line.match(/^(\s*[-*+]\s+)(\[[ xX]\])(\s*)/)
      if (task) {
        var taskLength = task[1].length + task[2].length + task[3].length
        output.push(preserveIndent(escapeHtml(task[1]))
          + "<span style=\"color:" + accent + "; font-weight:600;\">" + escapeHtml(task[2]) + "</span>"
          + escapeHtml(task[3]) + inlineHtml(line.slice(taskLength)))
        continue
      }

      var quote = line.match(/^(\s*>+\s?)(.*)$/)
      if (quote) {
        output.push("<span style=\"color:" + accent + ";\">" + escapeHtml(quote[1]) + "</span>"
          + "<span style=\"color:" + muted + "; font-style:italic;\">" + inlineHtml(quote[2]) + "</span>")
        continue
      }

      var marker = line.match(/^(\s*)([-*+]|\d+[.)])(\s+)/)
      if (marker) {
        var markerLength = marker[1].length + marker[2].length + marker[3].length
        output.push(preserveIndent(escapeHtml(marker[1]))
          + "<span style=\"color:" + accent + ";\">" + escapeHtml(marker[2]) + "</span>"
          + escapeHtml(marker[3]) + inlineHtml(line.slice(markerLength)))
        continue
      }

      output.push(inlineHtml(line))
    }
    return output.join("<br/>")
  }

  function wrapSelection(marker) {
    var start = Math.min(selectionStart, selectionEnd)
    var end = Math.max(selectionStart, selectionEnd)
    if (start === end) {
      insert(cursorPosition, marker + marker)
      cursorPosition = Math.max(0, cursorPosition - marker.length)
      return
    }
    var selection = text.slice(start, end)
    text = text.slice(0, start) + marker + selection + marker + text.slice(end)
    // Keep the original text selected between the new markers so a second
    // Ctrl+B/Ctrl+I (or typing) applies to the same span.
    select(start + marker.length, end + marker.length)
  }

  function currentLinkURL() {
    return MarkdownFormat.currentLinkURL(root.text, root.selectionStart, root.selectionEnd)
  }

  // Apply the pure formatter's minimal edit. The edit descriptor is derived by
  // the module and applied with remove()/insert() so the rest of the document
  // and its undo history stay intact.
  function applyFormat(action, value) {
    if (!root.enabled || root.readOnly) return false
    if (action === "undo") {
      root.undoFormat()
      root.forceActiveFocus()
      return true
    }
    if (action === "redo") {
      root.redoFormat()
      root.forceActiveFocus()
      return true
    }
    var plan = MarkdownFormat.plan(root.text, root.selectionStart, root.selectionEnd,
      String(action || ""), value)
    if (!plan || !plan.ok) {
      root.formatRejected(plan && plan.error ? plan.error : "Cannot apply formatting")
      return false
    }
    var edits = (plan.edits || []).slice().sort(function(a, b) { return b.start - a.start })
    var steps = 0
    for (var e = 0; e < edits.length; e++) {
      if (edits[e].end > edits[e].start) steps += 1
      if (edits[e].text !== "") steps += 1
    }
    root.suppressFormatHistory = true
    for (var i = 0; i < edits.length; i++) {
      var edit = edits[i]
      // TextEdit.remove(start, end) takes an end offset, not a length.
      if (edit.end > edit.start) root.remove(edit.start, edit.end)
      if (edit.text !== "") root.insert(edit.start, edit.text)
    }
    root.suppressFormatHistory = false
    root.formatUndoSteps = Math.max(1, steps)
    root.formatRedoSteps = Math.max(1, steps)
    root.formatUndoPending = steps > 0
    root.formatRedoPending = false
    root.select(plan.selectionStart, plan.selectionEnd)
    root.forceActiveFocus()
    return true
  }

  function undoFormat() {
    if (root.formatUndoPending && root.formatUndoSteps > 0) {
      root.suppressFormatHistory = true
      for (var i = 0; i < root.formatUndoSteps; i++) root.undo()
      root.suppressFormatHistory = false
      root.formatUndoPending = false
      root.formatRedoPending = true
      return
    }
    root.undo()
    root.formatUndoPending = false
    root.formatRedoPending = false
  }

  function redoFormat() {
    if (root.formatRedoPending && root.formatRedoSteps > 0) {
      root.suppressFormatHistory = true
      for (var i = 0; i < root.formatRedoSteps; i++) root.redo()
      root.suppressFormatHistory = false
      root.formatRedoPending = false
      root.formatUndoPending = true
      return
    }
    root.redo()
    root.formatRedoPending = false
    root.formatUndoPending = false
  }

  // Date/time are computed at menu click time. MarkdownFormat.planDate accepts
  // YYYY-MM-DD and planTime HH:MM, matching the toolbar's insert menu.
  function pad2(value) {
    return (value < 10 ? "0" : "") + value
  }

  function isoDate(date) {
    return date.getFullYear() + "-" + root.pad2(date.getMonth() + 1) + "-"
      + root.pad2(date.getDate())
  }

  function isoTime(date) {
    return root.pad2(date.getHours()) + ":" + root.pad2(date.getMinutes())
  }

  function insertDate() {
    root.applyFormat("date", root.isoDate(new Date()))
    root.forceActiveFocus()
  }

  function insertTime() {
    root.applyFormat("time", root.isoTime(new Date()))
    root.forceActiveFocus()
  }

  function insertPastedImage(markdown) {
    var position = Math.max(0, Math.min(cursorPosition, text.length))
    // Put the image on its own line, then leave the caret on a fresh line so
    // typing continues underneath it.
    var leading = (position > 0 && text.charAt(position - 1) !== "\n") ? "\n" : ""
    var insertion = leading + markdown + "\n"
    insert(position, insertion)
    cursorPosition = position + insertion.length
    forceActiveFocus()
  }

  function pasteAsText() {
    if (typeof root.paste === "function") {
      root.paste()
      return
    }
    // Older Qt builds without TextEdit.paste(); read the text ourselves.
    textPasteProcess.command = ["wl-paste", "--no-newline"]
    textPasteProcess.running = true
  }

  function finishImagePaste(exitCode) {
    pasteTimer.stop()
    if (!root.pastingImage) return
    root.pastingImage = false

    var payload = null
    try {
      payload = JSON.parse(String(root.pasteOutput || "").trim() || "{}")
    } catch (error) {
      payload = null
    }

    if (exitCode === 0 && payload && payload.ok === true && payload.markdown) {
      root.insertPastedImage(String(payload.markdown))
      root.imagePasted(String(payload.path || ""))
      return
    }

    if (exitCode === 0 && payload && payload.ok === false) {
      if (payload.reason === "no-image" && payload.hasText !== true) {
        // Nothing pasteable: say so instead of appearing to do nothing.
        root.pasteFailed(payload.hadImage === true
          ? "Unsupported image format on the clipboard"
          : "Nothing to paste")
        return
      }
      // no-image / text-preferred: behave exactly like a regular Ctrl+V.
      root.pasteAsText()
      return
    }

    var message = ""
    try {
      var failure = JSON.parse(String(root.pasteError || "").trim() || "{}")
      if (failure && (failure.error || failure.reason)) message = String(failure.error || failure.reason)
    } catch (error) {
      message = String(root.pasteError || "").trim()
    }
    if (!message) message = String(root.pasteError || "").trim()
    if (!message) message = "Could not paste image"
    root.pasteAsText()
    root.pasteFailed(message)
  }

  function beginImagePaste() {
    if (root.readOnly || root.pastingImage) return
    root.pastingImage = true
    root.pasteOutput = ""
    root.pasteError = ""
    pasteProcess.command = [root.pasteHelperPath]
    pasteProcess.running = true
    pasteTimer.restart()
  }

  Process {
    id: pasteProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pasteOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pasteError = String(text || "")
    }
    onExited: function(exitCode) { root.finishImagePaste(exitCode) }
  }

  Process {
    id: textPasteProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.insert(root.cursorPosition, String(text || ""))
    }
  }

  Timer {
    id: pasteTimer
    interval: 15000
    onTriggered: {
      if (!root.pastingImage) return
      root.pastingImage = false
      pasteProcess.running = false
      root.pasteAsText()
      root.pasteFailed("Image paste timed out")
    }
  }

  // Themed replacement for Qt's stock Undo/Redo/Cut/Copy/Paste/Delete menu.
  // Formatting actions reuse the same pure planner as the toolbar, so both
  // hosts (Library and Detached) get identical edits with no Library signals.
  Menu {
    id: editorMenu
    objectName: "editorContextMenu"
    width: Style.space(200)
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    palette.window: Commons.Color.menu.background
    palette.windowText: Commons.Color.menu.text
    palette.text: Commons.Color.menu.text
    palette.buttonText: Commons.Color.menu.text
    palette.light: Commons.Color.menu.selectedBackground
    palette.midlight: Util.alpha(Commons.Color.foreground, 0.12)
    palette.mid: Util.alpha(Commons.Color.foreground, 0.16)
    palette.dark: Commons.Color.menu.border
    palette.shadow: "#000000"
    onClosed: root.forceActiveFocus()

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    ContextMenuItem {
      text: "Undo"
      enabled: !root.readOnly && root.canUndo
      onTriggered: root.undoFormat()
    }
    ContextMenuItem {
      text: "Redo"
      enabled: !root.readOnly && root.canRedo
      onTriggered: root.redoFormat()
    }

    MenuSeparator {}

    ContextMenuItem {
      text: "Cut"
      enabled: !root.readOnly && root.selectedText.length > 0
      onTriggered: root.cut()
    }
    ContextMenuItem {
      text: "Copy"
      enabled: root.selectedText.length > 0
      onTriggered: root.copy()
    }
    ContextMenuItem {
      text: "Paste"
      enabled: !root.readOnly && !root.pastingImage
      onTriggered: root.beginImagePaste()
    }
    ContextMenuItem {
      text: "Delete"
      enabled: !root.readOnly && root.selectedText.length > 0
      onTriggered: {
        root.remove(Math.min(root.selectionStart, root.selectionEnd),
          Math.max(root.selectionStart, root.selectionEnd))
        root.forceActiveFocus()
      }
    }

    MenuSeparator {}

    ContextMenuItem {
      text: "Select all"
      enabled: root.text.length > 0
      onTriggered: {
        root.selectAll()
        root.forceActiveFocus()
      }
    }

    MenuSeparator {}

    ContextMenuItem {
      text: "Bold"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("bold")
    }
    ContextMenuItem {
      text: "Italic"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("italic")
    }
    ContextMenuItem {
      text: "Underline"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("underline")
    }
    ContextMenuItem {
      text: "Strikethrough"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("strike")
    }
    ContextMenuItem {
      text: "Highlight"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("highlight")
    }
    ContextMenuItem {
      text: "Inline code"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("code")
    }
    ContextMenuItem {
      text: "Clear formatting"
      enabled: !root.readOnly
      onTriggered: root.applyFormat("clear")
    }

    MenuSeparator {}

    ContextMenuItem {
      text: "Insert date"
      enabled: !root.readOnly
      onTriggered: root.insertDate()
    }
    ContextMenuItem {
      text: "Insert time"
      enabled: !root.readOnly
      onTriggered: root.insertTime()
    }
  }

  color: inputMethodComposing ? foregroundColor : "transparent"
  selectedTextColor: foregroundColor
  selectionColor: alpha(accentColor, 0.42)
  wrapMode: TextEdit.Wrap
  selectByMouse: true
  persistentSelection: true

  onTextChanged: {
    if (root.suppressFormatHistory) return
    root.formatUndoPending = false
    root.formatRedoPending = false
  }

  FontMetrics {
    id: editorMetrics
    font: root.font
  }

  cursorDelegate: Rectangle {
    // Track the caret rectangle Qt computes for the current line so the caret
    // always matches the text size, including wrapped lines.
    width: 2
    height: root.cursorRectangle.height
    color: root.accentColor
    visible: root.activeFocus
  }

  background: Item {
    clip: true
    opacity: root.inputMethodComposing ? 0 : 1

    Text {
      objectName: "quillUnderlay"
      x: root.leftPadding
      y: root.topPadding
      width: Math.max(0, root.width - root.leftPadding - root.rightPadding)
      text: root.richTextVisible ? root.highlightedMarkdown(root.text) : root.text
      textFormat: root.richTextVisible ? Text.RichText : Text.PlainText
      wrapMode: Text.Wrap
      lineHeightMode: Text.FixedHeight
      // One fixed line height for the whole underlay. Do not follow
      // cursorRectangle.height: TextEdit shrinks a line that contains only
      // emoji to the emoji font's metrics (12 px at the body size). Feeding
      // that back made every underlay line 4 px shorter, so in a long note the
      // painted text drifted hundreds of pixels above the real caret.
      lineHeight: Math.max(1, Math.round(editorMetrics.height))
      color: root.foregroundColor
      font.family: root.font.family
      font.pixelSize: root.font.pixelSize
    }
  }

  Keys.onShortcutOverride: function(event) {
    // TextEdit claims Ctrl+V as a built-in paste shortcut, so its ShortcutOverride
    // arrives before Keys.onPressed. Accept it here to turn paste into a normal
    // key press that we can intercept.
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    if (control && (event.key === Qt.Key_V || event.key === Qt.Key_Z)) event.accepted = true
  }

  Keys.onPressed: function(event) {
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)) {
      insert(cursorPosition, "  ")
      event.accepted = true
    } else if (control && event.key === Qt.Key_B) {
      root.applyFormat("bold")
      event.accepted = true
    } else if (control && event.key === Qt.Key_I) {
      root.applyFormat("italic")
      event.accepted = true
    } else if (control && event.key === Qt.Key_U) {
      root.applyFormat("underline")
      event.accepted = true
    } else if (control && event.key === Qt.Key_X
      && (event.modifiers & Qt.ShiftModifier) !== 0) {
      root.applyFormat("strike")
      event.accepted = true
    } else if (control && event.key === Qt.Key_H
      && (event.modifiers & Qt.ShiftModifier) !== 0) {
      root.applyFormat("highlight")
      event.accepted = true
    } else if (control && event.key === Qt.Key_K
      && (event.modifiers & Qt.ShiftModifier) !== 0) {
      root.noteLinkRequested()
      event.accepted = true
    } else if (control && event.key === Qt.Key_K) {
      root.linkRequested()
      event.accepted = true
    } else if (control && event.key === Qt.Key_Z) {
      if ((event.modifiers & Qt.ShiftModifier) !== 0) root.redoFormat()
      else root.undoFormat()
      event.accepted = true
    } else if (control && event.key === Qt.Key_V) {
      // Ctrl+V (and Ctrl+Shift+V) always goes through the image helper first;
      // accepting the event immediately prevents a double text paste.
      event.accepted = true
      if (root.readOnly || root.pastingImage) return
      root.beginImagePaste()
    }
  }
}
