import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T
import Qt.labs.folderlistmodel
import Quickshell
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

  // "Attach file…": a themed in-app file browser rather than a portal,
  // zenity or QtQuick.Dialogs. The store copies the chosen file into the data
  // root and returns the Markdown to insert. attachPath/attachChosenPath are
  // the scripted entry points (Enter in the picker's path field uses them too).
  readonly property var attachPickerRef: attachPicker
  readonly property bool attachPickerOpen: attachPicker.visible
  property string attachPath: ""
  property string attachFolder: ""
  property string attachFilter: ""
  property bool attachShowHidden: false
  property string attachSelected: ""
  property string attachOutput: ""
  property string attachError: ""
  property bool attaching: false
  readonly property string attachHome: Quickshell.env("HOME") || "/"
  readonly property bool attachCanConfirm: root.attachPath.trim() !== ""

  // "Draw…": a themed freehand canvas. Strokes live in memory until Insert
  // exports a white-background PNG through the same attachment pipeline, so a
  // drawing behaves exactly like any other attached image.
  readonly property var drawPopupRef: drawPopup
  readonly property bool drawPopupOpen: drawPopup.visible
  property var drawingStrokes: []
  property string drawColour: "#000000"
  property int drawBrushWidth: 4
  property bool drawEraser: false
  property bool drawSaving: false
  property string drawTempPath: ""
  property string drawError: ""
  readonly property bool drawCanInsert: root.drawingStrokes.length > 0
    && !root.drawSaving && !root.attaching
  readonly property var drawPalette: [
    "#000000", "#e03e2d", "#3598db", "#2dc26b",
    "#f1c40f", "#e67e22", "#95a5a6", "#ffffff"
  ]
  readonly property var drawBrushSizes: [2, 4, 8, 16]

  // Replaces the stock white Qt text menu with a compact icon strip. The
  // attached menu stays null; right-click is handled in onPressed so the strip
  // can be centred over the click rather than dropped at the pointer.
  readonly property var contextMenuRef: editorMenu
  T.ContextMenu.menu: null

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
  signal attachmentAdded(string path)
  signal attachFailed(string message)
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

  // Background highlights are stored without a text colour so the note stays
  // theme-neutral. The underlay adds a readable foreground at paint time only.
  function contrastHtmlColour(value) {
    var hex = safeHtmlColour(value)
    if (hex === null) return hexColor(foregroundColor)
    var red = parseInt(hex.slice(1, 3), 16)
    var green = parseInt(hex.slice(3, 5), 16)
    var blue = parseInt(hex.slice(5, 7), 16)
    return (0.299 * red + 0.587 * green + 0.114 * blue) > 150 ? "#101315" : "#ffffff"
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
      } else if (key === "background-color") {
        var background = safeHtmlColour(value)
        if (background === null) return null
        props.push({ key: "background-color", value: background })
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
        var background = null
        for (var p = 0; p < tag.props.length; p++) {
          if (tag.props[p].key === "color") colour = tag.props[p].value
          else if (tag.props[p].key === "background-color") background = tag.props[p].value
        }
        if (colour !== null || background !== null) {
          var styles = []
          if (colour !== null) styles.push("color:" + colour + ";")
          if (background !== null) {
            styles.push("background-color:" + background + ";")
            // Paint the contrast colour without storing it in the note.
            if (colour === null) styles.push("color:" + contrastHtmlColour(background) + ";")
          }
          openHtml += '<span style="' + styles.join(" ") + '">'
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

  // ------------------------------------------------------------ attachments

  // Editing is blocked while the note is read-only, disabled, or a crash-draft
  // banner is pending: Library/Detached fold draftPending into readOnly or
  // enabled, so this is the same guard Ctrl+V uses.
  function attachAllowed() {
    return root.enabled && !root.readOnly && !root.pastingImage
  }

  function attachBasename(path) {
    var value = String(path || "")
    var cut = value.lastIndexOf("/")
    var name = cut >= 0 ? value.slice(cut + 1) : value
    return name === "" ? "file" : name
  }

  function attachParentFolder(path) {
    var value = String(path || "")
    while (value.length > 1 && value.charAt(value.length - 1) === "/") {
      value = value.slice(0, -1)
    }
    var cut = value.lastIndexOf("/")
    return cut <= 0 ? "/" : value.slice(0, cut)
  }

  // Expand ~, make relative paths relative to the current folder, and collapse
  // duplicate/trailing separators so the store always sees an absolute path.
  function attachResolvePath(value) {
    var path = String(value === undefined || value === null ? "" : value).trim()
    if (path === "") return ""
    if (path === "~") path = root.attachHome
    else if (path.slice(0, 2) === "~/") path = root.attachHome + path.slice(1)
    else if (path.charAt(0) !== "/") path = (root.attachFolder || root.attachHome) + "/" + path
    path = path.replace(/\/{2,}/g, "/")
    while (path.length > 1 && path.charAt(path.length - 1) === "/") {
      path = path.slice(0, -1)
    }
    return path
  }

  function attachFolderUrl(path) {
    return "file://" + String(path || "/").replace(/ /g, "%20")
      .replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  function attachEntryFor(path) {
    var target = String(path || "")
    var entries = root.attachFolderEntries
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].path === target) return entries[i]
    }
    return null
  }

  function attachNavigate(folder) {
    var path = root.attachResolvePath(folder)
    if (path === "") return false
    root.attachFolder = path
    root.attachFilter = ""
    root.attachPath = ""
    root.attachSelected = ""
    return true
  }

  function openAttachPicker() {
    if (!root.attachAllowed()) return false
    if (root.attachFolder === "") root.attachFolder = root.attachHome
    root.attachFilter = ""
    root.attachPath = ""
    root.attachSelected = ""
    root.attachOutput = ""
    root.attachError = ""
    attachPicker.open()
    attachFilterField.forceActiveFocus()
    return true
  }

  function closeAttachPicker() {
    attachPicker.close()
    root.attachSelected = ""
  }

  function chooseAttachEntry(entry) {
    if (!entry) return false
    if (entry.isDir) return root.attachNavigate(entry.path)
    root.attachSelected = entry.path
    root.attachPath = entry.path
    return true
  }

  // Enter in the path field / the footer's Attach button. A known directory
  // navigates; a known file attaches; anything else is probed with test(1) so
  // a hand-typed directory navigates instead of failing inside the store.
  function attachChosenPath() {
    if (!root.attachAllowed()) return false
    var target = root.attachResolvePath(root.attachPath)
    if (target === "") return false
    var entry = root.attachEntryFor(target)
    if (entry !== null) return root.chooseAttachEntry(entry)
    if (target === "/") return root.attachNavigate("/")
    attachProbe.target = target
    attachProbe.command = ["/usr/bin/test", "-d", target]
    attachProbe.running = true
    return true
  }

  function finishAttachProbe(exitCode) {
    var target = attachProbe.target
    if (exitCode === 0) root.attachNavigate(target)
    else root.attachFile(target)
  }

  function attachFile(path, altName) {
    if (!root.attachAllowed() || root.attaching) return false
    var target = root.attachResolvePath(path)
    if (target === "") return false
    if (root.storePath === "") {
      root.attachFailed("No store configured for attachments")
      return false
    }
    var alt = (altName === undefined || altName === null || String(altName) === "")
      ? root.attachBasename(target)
      : String(altName)
    root.attachOutput = ""
    root.attachError = ""
    root.attaching = true
    root.attachSelected = ""
    attachPicker.close()
    attachProcess.command = [root.storePath, "attachment", "save",
      "--file", target, "--name", alt]
    attachProcess.running = true
    attachTimer.restart()
    return true
  }

  function insertAttachmentMarkdown(markdown) {
    var position = Math.max(0, Math.min(cursorPosition, text.length))
    var leading = (position > 0 && text.charAt(position - 1) !== "\n") ? "\n" : ""
    var trailing = (position < text.length && text.charAt(position) !== "\n") ? "\n" : ""
    var insertion = leading + markdown + trailing
    insert(position, insertion)
    cursorPosition = position + insertion.length
    forceActiveFocus()
  }

  function finishAttach(exitCode) {
    attachTimer.stop()
    if (!root.attaching) return
    root.attaching = false

    var payload = null
    try {
      payload = JSON.parse(String(root.attachOutput || "").trim() || "{}")
    } catch (error) {
      payload = null
    }

    if (exitCode === 0 && payload && payload.markdown) {
      root.insertAttachmentMarkdown(String(payload.markdown))
      root.attachmentAdded(String(payload.path || ""))
      if (root.drawTempPath !== "") root.completeDrawInsert(true)
      return
    }

    // The store reports failures as JSON on stderr; show its message rather
    // than the JSON wrapper, but never lose unexpected stderr output.
    var message = ""
    try {
      var failure = JSON.parse(String(root.attachError || "").trim() || "{}")
      if (failure && failure.error) message = String(failure.error)
    } catch (error) {
      message = String(root.attachError || "").trim()
    }
    if (!message) message = String(root.attachError || "").trim()
    if (!message) message = "Could not attach file"
    root.attachFailed(message)
    if (root.drawTempPath !== "") root.completeDrawInsert(false, message)
  }

  // ---------------------------------------------------------------- drawing

  function openDrawCanvas() {
    if (root.drawSaving) return false
    if (!root.attachAllowed()) return false
    if (root.storePath === "") return false
    root.resetDrawCanvas()
    drawPopup.open()
    return true
  }

  function resetDrawCanvas() {
    root.drawingStrokes = []
    root.drawColour = "#000000"
    root.drawBrushWidth = 4
    root.drawEraser = false
    root.drawError = ""
    drawSurface.requestPaint()
  }

  function closeDrawCanvas() {
    if (root.drawSaving) return false
    drawPopup.close()
    return true
  }

  function drawChooseColour(value) {
    if (root.drawSaving) return false
    root.drawColour = String(value || "#000000")
    root.drawEraser = false
    return true
  }

  function drawChooseBrush(value) {
    if (root.drawSaving) return false
    var size = Math.round(Number(value))
    if (!(size > 0)) return false
    root.drawBrushWidth = size
    return true
  }

  function drawToggleEraser() {
    if (root.drawSaving) return false
    root.drawEraser = !root.drawEraser
    return root.drawEraser
  }

  function drawStrokeStart(x, y) {
    var px = Math.max(0, Math.min(drawSurface.width, Number(x) || 0))
    var py = Math.max(0, Math.min(drawSurface.height, Number(y) || 0))
    var stroke = {
      color: root.drawEraser ? "#ffffff" : root.drawColour,
      width: root.drawEraser ? root.drawBrushWidth * 3 : root.drawBrushWidth,
      points: [{ x: px, y: py }]
    }
    root.drawingStrokes = root.drawingStrokes.concat([stroke])
    drawSurface.requestPaint()
    return true
  }

  // Points are appended in place so a drag does not rebuild the stroke array;
  // the last stroke always owns the point list being extended.
  function drawStrokeMove(x, y) {
    if (root.drawingStrokes.length === 0) return false
    var px = Math.max(0, Math.min(drawSurface.width, Number(x) || 0))
    var py = Math.max(0, Math.min(drawSurface.height, Number(y) || 0))
    var stroke = root.drawingStrokes[root.drawingStrokes.length - 1]
    stroke.points.push({ x: px, y: py })
    drawSurface.requestPaint()
    return true
  }

  function drawStrokeEnd() {
    drawSurface.requestPaint()
    return true
  }

  function drawUndo() {
    if (root.drawSaving || root.drawingStrokes.length === 0) return false
    root.drawingStrokes = root.drawingStrokes.slice(0, -1)
    drawSurface.requestPaint()
    return true
  }

  function drawClear() {
    if (root.drawSaving) return false
    root.drawingStrokes = []
    drawSurface.requestPaint()
    return true
  }

  function insertDrawing() {
    if (!root.attachAllowed()) return false
    if (root.drawSaving || root.attaching) return false
    if (root.drawingStrokes.length === 0) return false
    if (root.storePath === "") {
      root.drawError = "No store configured for attachments"
      return false
    }
    root.drawSaving = true
    root.drawError = ""
    // Flush the pending stroke paint before the scene graph grabs the canvas.
    drawSurface.requestPaint()
    Qt.callLater(root.grabDrawing)
    return true
  }

  function grabDrawing() {
    if (!root.drawSaving) return
    if (drawSurface.width <= 0 || drawSurface.height <= 0) {
      root.drawError = "The drawing canvas is not ready"
      root.drawSaving = false
      return
    }
    drawSurface.grabToImage(function(result) {
      root.finishDrawGrab(result)
    }, Qt.size(Math.round(drawSurface.width), Math.round(drawSurface.height)))
  }

  function finishDrawGrab(result) {
    if (!root.drawSaving) return
    var folder = Quickshell.env("TMPDIR") || "/tmp"
    if (folder.length > 1 && folder.charAt(folder.length - 1) === "/") {
      folder = folder.slice(0, -1)
    }
    var tmp = folder + "/quill-drawing-" + Date.now() + ".png"
    var saved = result !== null && result !== undefined
      && result.saveToFile("file://" + tmp)
    if (!saved) {
      root.drawError = "Could not save the drawing image"
      root.drawSaving = false
      return
    }
    root.drawTempPath = tmp
    if (!root.attachFile(tmp, "drawing")) {
      Quickshell.execDetached(["rm", "-f", tmp])
      root.drawTempPath = ""
      root.drawSaving = false
      root.drawError = "Could not attach the drawing"
    }
  }

  function completeDrawInsert(ok, message) {
    var tmp = root.drawTempPath
    if (tmp !== "") Quickshell.execDetached(["rm", "-f", tmp])
    root.drawTempPath = ""
    root.drawSaving = false
    if (ok) {
      drawPopup.close()
      root.resetDrawCanvas()
      return
    }
    root.drawError = String(message || "Could not insert the drawing")
  }

  function paintDrawing(context) {
    context.clearRect(0, 0, drawSurface.width, drawSurface.height)
    // Always export on white, even when the shell theme is dark.
    context.fillStyle = "#ffffff"
    context.fillRect(0, 0, drawSurface.width, drawSurface.height)
    context.lineCap = "round"
    context.lineJoin = "round"
    for (var i = 0; i < root.drawingStrokes.length; i += 1) {
      var stroke = root.drawingStrokes[i]
      var points = stroke.points || []
      if (points.length === 0) continue
      context.strokeStyle = stroke.color
      context.fillStyle = stroke.color
      context.lineWidth = stroke.width
      if (points.length === 1) {
        context.beginPath()
        context.arc(points[0].x, points[0].y, stroke.width / 2, 0, Math.PI * 2)
        context.fill()
        continue
      }
      context.beginPath()
      context.moveTo(points[0].x, points[0].y)
      for (var p = 1; p < points.length; p += 1) {
        context.lineTo(points[p].x, points[p].y)
      }
      context.stroke()
    }
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

  // ---------------------------------------------------------- attach picker

  // Backing model for the picker. FolderListModel is synchronous for local
  // directories, so the list is ready as soon as the popup opens.
  FolderListModel {
    id: attachFolderModel
    folder: root.attachFolderUrl(root.attachFolder === "" ? root.attachHome : root.attachFolder)
    showDirs: true
    showFiles: true
    showHidden: root.attachShowHidden
    showDirsFirst: true
    sortField: FolderListModel.Name
    nameFilters: ["*"]
  }

  // Every row of the current folder (used for hit-testing typed paths).
  readonly property var attachFolderEntries: {
    var output = []
    var folder = root.attachFolder === "" ? root.attachHome : root.attachFolder
    var total = attachFolderModel.count
    for (var i = 0; i < total; i++) {
      var name = String(attachFolderModel.get(i, "fileName") || "")
      if (name === "") continue
      output.push({
        name: name,
        path: folder === "/" ? "/" + name : folder + "/" + name,
        isDir: !!attachFolderModel.get(i, "fileIsDir")
      })
    }
    return output
  }

  // The visible rows: hidden files only when asked for, plus the quick filter.
  readonly property var attachEntries: {
    var all = root.attachFolderEntries
    var query = String(root.attachFilter || "").trim().toLowerCase()
    var output = []
    for (var i = 0; i < all.length; i++) {
      var entry = all[i]
      if (!root.attachShowHidden && entry.name.charAt(0) === ".") continue
      if (query !== "" && entry.name.toLowerCase().indexOf(query) < 0) continue
      output.push(entry)
    }
    return output
  }

  Process {
    id: attachProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attachOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attachError = String(text || "")
    }
    onExited: function(exitCode) { root.finishAttach(exitCode) }
  }

  Process {
    id: attachProbe
    property string target: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.finishAttachProbe(exitCode) }
  }

  Timer {
    id: attachTimer
    interval: 20000
    onTriggered: {
      if (!root.attaching) return
      root.attaching = false
      attachProcess.running = false
      var message = "Attaching the file timed out"
      root.attachFailed(message)
      if (root.drawTempPath !== "") root.completeDrawInsert(false, message)
    }
  }

  Popup {
    id: attachPicker
    objectName: "quillAttachPicker"
    width: Style.space(360)
    height: Style.space(440)
    padding: Style.space(8)
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    x: Math.max(Style.space(4), Math.round((root.width - width) / 2))
    y: Math.max(Style.space(4), Math.round((root.height - height) / 2))
    onClosed: root.attachSelected = ""

    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Text {
        objectName: "attachFolderLabel"
        width: parent.width
        text: root.attachFolder === "" ? root.attachHome : root.attachFolder
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
        color: Util.alpha(Commons.Color.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // "Up" row and the hidden-files toggle share one compact line.
      Row {
        width: parent.width
        spacing: Style.space(4)

        BorderSurface {
          id: attachUpRow
          objectName: "attachUp"
          width: Style.space(56)
          height: Style.space(22)
          color: attachUpMouse.containsMouse
            ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
            : "transparent"
          borderSpec: Border.controlSpec("normal", Commons.Color.foreground,
            Commons.Color.accent)
          radius: Style.cornerRadius

          Text {
            anchors.centerIn: parent
            text: "↑ Up"
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: attachUpMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.attachNavigate(root.attachParentFolder(
              root.attachFolder === "" ? root.attachHome : root.attachFolder))
          }
        }

        BorderSurface {
          id: attachHiddenRow
          objectName: "attachHiddenToggle"
          width: Style.space(112)
          height: Style.space(22)
          color: attachHiddenMouse.containsMouse
            ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
            : "transparent"
          borderSpec: Border.none
          radius: Style.cornerRadius

          Text {
            anchors.centerIn: parent
            text: root.attachShowHidden ? "☑ Hidden files" : "☐ Hidden files"
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, root.attachShowHidden ? 0.92 : 0.62)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: attachHiddenMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.attachShowHidden = !root.attachShowHidden
          }
        }
      }

      TextField {
        id: attachFilterField
        objectName: "attachFilterField"
        width: parent.width
        height: Style.space(24)
        text: root.attachFilter
        placeholderText: "Filter…"
        font.pixelSize: Style.font.bodySmall
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        topPadding: Style.space(3)
        bottomPadding: Style.space(3)
        onTextChanged: if (root.attachFilter !== text) root.attachFilter = text
      }

      Item {
        // The list takes whatever height the rows above leave inside the
        // popup, so the path field and footer stay visible at the bottom
        // (24 px path field + 26 px footer + one 6 px gap each).
        width: parent.width
        height: Math.max(Style.space(80), attachPicker.availableHeight - y
          - Style.space(24) - Style.space(6) - Style.space(26) - Style.space(6))

        ListView {
          id: attachList
          objectName: "attachList"
          anchors.fill: parent
          clip: true
          model: root.attachEntries
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            id: attachRow
            required property var modelData

            width: attachList.width
            height: Style.space(23)
            radius: Style.cornerRadius
            color: root.attachSelected === modelData.path
              ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
              : attachRowMouse.containsMouse
                ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                : "transparent"

            Text {
              id: attachGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.isDir ? "📁" : "📄"
              textFormat: Text.PlainText
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.left: attachGlyph.right
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.name
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: attachRowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.chooseAttachEntry(modelData)
              onDoubleClicked: {
                if (!modelData.isDir) root.attachFile(modelData.path)
              }
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.attachEntries.length === 0
          text: "No files here"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      TextField {
        id: attachPathField
        objectName: "attachPathField"
        width: parent.width
        height: Style.space(24)
        text: root.attachPath
        placeholderText: "Path to a file or folder…"
        font.pixelSize: Style.font.bodySmall
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        topPadding: Style.space(3)
        bottomPadding: Style.space(3)
        onTextChanged: if (root.attachPath !== text) root.attachPath = text
        onAccepted: root.attachChosenPath()
      }

      Row {
        width: parent.width
        height: Style.space(26)
        spacing: Style.space(5)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - attachCancel.width - attachConfirm.width
            - parent.spacing * 2
          text: root.attaching ? "Attaching…" : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Util.alpha(Commons.Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Button {
          id: attachCancel
          objectName: "attachCancel"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.closeAttachPicker()
        }

        Button {
          id: attachConfirm
          objectName: "attachConfirm"
          text: "Attach"
          active: root.attachCanConfirm && !root.attaching
          enabled: root.attachCanConfirm && !root.attaching
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.attachChosenPath()
        }
      }
    }
  }

  // Freehand drawing: a themed modal canvas over the editor. Strokes stay
  // local until Insert exports a PNG, so Cancel never touches the note.
  Popup {
    id: drawPopup
    objectName: "drawCanvasPopup"
    // Narrow editor panes get a smaller popup; the canvas keeps a 3:5-ish
    // shape so a sketch remains usable without overflowing the window.
    width: Math.min(Style.space(680),
      Math.max(Style.space(320), root.width - Style.space(24)))
    padding: Style.space(8)
    focus: true
    modal: true
    // Outside clicks are deliberately ignored: losing a sketch to a stray
    // click is worse than closing with Escape or Cancel.
    closePolicy: root.drawSaving ? Popup.NoAutoClose : Popup.CloseOnEscape
    x: Math.max(Style.space(4), Math.round((root.width - width) / 2))
    y: Math.max(Style.space(4), Math.round((root.height - height) / 2))
    onClosed: {
      if (root.drawSaving) return
      if (root.drawTempPath !== "") {
        Quickshell.execDetached(["rm", "-f", root.drawTempPath])
        root.drawTempPath = ""
      }
      root.resetDrawCanvas()
    }

    background: BorderSurface {
      color: Commons.Color.background
      borderSpec: Border.controlSpec("normal", Commons.Color.foreground,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Draw"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(60)
          text: root.drawEraser ? "Erasing — drag over the drawing"
            : "Drag to sketch. Insert saves a PNG."
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Util.alpha(Commons.Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        id: drawFrame
        objectName: "drawSurfaceFrame"
        width: parent.width
        height: Math.max(Style.space(220), Math.round(width * 0.6))
        color: "#ffffff"
        border.width: 1
        border.color: Util.alpha(Commons.Color.foreground, 0.28)
        radius: Style.space(2)

        Canvas {
          id: drawSurface
          objectName: "drawSurface"
          anchors.fill: parent
          anchors.margins: 1
          onPaint: root.paintDrawing(getContext("2d"))
        }

        MouseArea {
          id: drawInput
          objectName: "drawInput"
          anchors.fill: drawSurface
          cursorShape: Qt.CrossCursor
          preventStealing: true
          onPressed: function(mouse) { root.drawStrokeStart(mouse.x, mouse.y) }
          onPositionChanged: function(mouse) {
            if (pressed) root.drawStrokeMove(mouse.x, mouse.y)
          }
          onReleased: root.drawStrokeEnd()
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.drawPalette

          delegate: Rectangle {
            id: drawSwatch
            required property int index
            required property string modelData

            objectName: "drawSwatch" + index
            width: Style.space(22)
            height: Style.space(20)
            radius: Style.space(3)
            color: drawSwatch.modelData
            border.width: root.drawColour === drawSwatch.modelData && !root.drawEraser
              ? 2 : 1
            border.color: root.drawColour === drawSwatch.modelData && !root.drawEraser
              ? Commons.Color.accent
              : Util.alpha(Commons.Color.foreground, 0.28)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.drawChooseColour(drawSwatch.modelData)
            }

            Text {
              anchors.centerIn: parent
              visible: root.drawColour === drawSwatch.modelData && !root.drawEraser
              text: "✓"
              textFormat: Text.PlainText
              color: drawSwatch.modelData === "#ffffff" || drawSwatch.modelData === "#f1c40f"
                ? "#1a1a1a" : "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(4)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(34)
          text: "Brush"
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.drawBrushSizes

          delegate: Button {
            id: drawBrushButton
            required property int index
            required property int modelData

            objectName: "drawBrush" + modelData
            width: Style.space(30)
            height: Style.space(22)
            text: String(modelData)
            fontSize: Style.font.caption
            horizontalPadding: 0
            verticalPadding: 0
            selected: root.drawBrushWidth === modelData
            onClicked: root.drawChooseBrush(modelData)
          }
        }

        Button {
          id: drawEraserButton
          objectName: "drawEraser"
          width: Style.space(58)
          height: Style.space(22)
          text: "Eraser"
          fontSize: Style.font.caption
          horizontalPadding: Style.space(5)
          verticalPadding: 0
          selected: root.drawEraser
          onClicked: root.drawToggleEraser()
        }
      }

      Text {
        objectName: "drawErrorLabel"
        width: parent.width
        visible: root.drawError !== ""
        text: root.drawError
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        height: Style.space(26)
        spacing: Style.space(5)

        Button {
          id: drawUndoButton
          objectName: "drawUndo"
          text: "Undo"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.drawingStrokes.length > 0 && !root.drawSaving
          onClicked: root.drawUndo()
        }

        Button {
          id: drawClearButton
          objectName: "drawClear"
          text: "Clear"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.drawingStrokes.length > 0 && !root.drawSaving
          onClicked: root.drawClear()
        }

        Item {
          width: Math.max(0, parent.width - drawUndoButton.width
            - drawClearButton.width - drawCancelButton.width - drawInsertButton.width
            - parent.spacing * 4)
          height: 1
        }

        Button {
          id: drawCancelButton
          objectName: "drawCancel"
          text: "Cancel"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          enabled: !root.drawSaving
          onClicked: root.closeDrawCanvas()
        }

        Button {
          id: drawInsertButton
          objectName: "drawInsert"
          text: root.drawSaving ? "Inserting…" : "Insert"
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          active: root.drawCanInsert
          enabled: root.drawCanInsert
          onClicked: root.insertDrawing()
        }
      }
    }
  }

  // A compact horizontal action strip in place of the stock vertical text
  // menu. Right-click centres it over the pointer and lifts it above the
  // click, flipping below when there is no room at the top of the editor.
  Popup {
    id: editorMenu
    objectName: "editorContextMenu"
    width: menuRow.implicitWidth + leftPadding + rightPadding
    height: menuRow.implicitHeight + topPadding + bottomPadding
    padding: Style.space(4)
    popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onClosed: root.forceActiveFocus()

    function showAt(px, py) {
      var gap = Style.space(6)
      var margin = Style.space(6)
      // Position in window space so a scrolled editor (whose item is taller
      // than the viewport) still keeps the strip inside the visible window.
      var win = root.Window.window
      var winWidth = win ? win.width : root.width
      var winHeight = win ? win.height : root.height
      var point = root.mapToItem(null, px, py)
      var nx = Math.max(margin,
        Math.min(winWidth - width - margin, point.x - width / 2))
      var ny = point.y - height - gap
      if (ny < margin) ny = point.y + gap
      ny = Math.max(margin, Math.min(winHeight - height - margin, ny))
      var origin = root.mapFromItem(null, nx, ny)
      x = origin.x
      y = origin.y
      open()
    }

    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.controlSpec("normal", Commons.Color.menu.border,
        Commons.Color.accent)
      radius: Style.cornerRadius
    }

    contentItem: Row {
      id: menuRow
      spacing: Style.space(1)

      MenuAction {
        glyph: "\uf0e2"
        tip: "Undo (Ctrl+Z)"
        enabled: !root.readOnly && root.canUndo
        onActivated: {
          root.undoFormat()
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf01e"
        tip: "Redo (Ctrl+Shift+Z)"
        enabled: !root.readOnly && root.canRedo
        onActivated: {
          root.redoFormat()
          editorMenu.close()
        }
      }

      MenuDivider {}

      MenuAction {
        glyph: "\uf0c4"
        tip: "Cut"
        enabled: !root.readOnly && root.selectedText.length > 0
        onActivated: {
          root.cut()
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf0c5"
        tip: "Copy"
        enabled: root.selectedText.length > 0
        onActivated: {
          root.copy()
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf0ea"
        tip: "Paste"
        enabled: !root.readOnly && !root.pastingImage
        onActivated: {
          root.beginImagePaste()
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf014"
        tip: "Delete"
        enabled: !root.readOnly && root.selectedText.length > 0
        onActivated: {
          root.remove(Math.min(root.selectionStart, root.selectionEnd),
            Math.max(root.selectionStart, root.selectionEnd))
          editorMenu.close()
        }
      }

      MenuDivider {}

      MenuAction {
        glyph: "\uf046"
        tip: "Select all"
        enabled: root.text.length > 0
        onActivated: {
          root.selectAll()
          editorMenu.close()
        }
      }

      MenuDivider {}

      MenuAction {
        glyph: "\uf032"
        tip: "Bold (Ctrl+B)"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("bold")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf033"
        tip: "Italic (Ctrl+I)"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("italic")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf0cd"
        tip: "Underline (Ctrl+U)"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("underline")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf0cc"
        tip: "Strikethrough (Ctrl+Shift+X)"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("strike")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf1fc"
        tip: "Highlight (Ctrl+Shift+H)"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("highlight")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf121"
        tip: "Inline code"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("code")
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf12d"
        tip: "Clear formatting"
        enabled: !root.readOnly
        onActivated: {
          root.applyFormat("clear")
          editorMenu.close()
        }
      }

      MenuDivider {}

      MenuAction {
        glyph: "\uf073"
        tip: "Insert date"
        enabled: !root.readOnly
        onActivated: {
          root.insertDate()
          editorMenu.close()
        }
      }
      MenuAction {
        glyph: "\uf017"
        tip: "Insert time"
        enabled: !root.readOnly
        onActivated: {
          root.insertTime()
          editorMenu.close()
        }
      }
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

  onPressed: function(mouse) {
    if (mouse.button === Qt.RightButton) editorMenu.showAt(mouse.x, mouse.y)
  }

  // One icon button in the right-click strip. The glyphs are Nerd Font icons
  // (the shell's monospace alias resolves to JetBrainsMono Nerd Font), so the
  // strip stays legible at 22 px without text labels; tooltips name each one.
  component MenuAction: Button {
    id: menuAction
    property string glyph: ""
    property string tip: ""
    signal activated()

    text: ""
    iconText: glyph
    iconSize: Style.font.bodySmall
    width: Style.space(22)
    height: Style.space(22)
    horizontalPadding: 0
    verticalPadding: 0
    focusable: false
    tooltipText: tip
    foreground: Commons.Color.menu.text
    opacity: enabled ? 1 : 0.35
    onClicked: menuAction.activated()
  }

  component MenuDivider: Item {
    width: Style.space(5)
    height: Style.space(22)

    Rectangle {
      anchors.centerIn: parent
      width: 1
      height: Style.space(13)
      color: Util.alpha(Commons.Color.foreground, 0.16)
    }
  }
}
