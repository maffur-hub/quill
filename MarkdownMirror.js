// Edit-mirror highlighter for Quill.
//
// This paints the styled text behind MarkdownEditor's TextArea so the caret,
// selection and line wrapping line up with the Markdown source. It is not the
// preview renderer: MathText.js/MarkdownExtras.js build the reading view, this
// module mirrors the source line by line.
//
// It is plain ES5 with no Qt imports and no module.exports, because
// tests/js/helpers/load.js evaluates it in a node:vm context and reads the
// functions off that context, exactly like MarkdownFormat.js and MathText.js.
//
// Every colour comes from the caller through a palette object, so this module
// stays pure and the node tests can use fixed strings:
//
//   { foreground, accent, muted, code }
//
// foreground and accent are #rrggbb strings; muted is the dim colour for
// inline markers (the foreground at 52%) and code is the fence and quote
// colour (60%). MarkdownEditor.qml resolves them from Commons.Color/Util in
// mirrorPalette() and passes the result to each render call.

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function escapeHtml(value) {
  return textOf(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
}

// Qt's rich text collapses runs of spaces and draws a tab as one space, so
// the mirror came out narrower than the TextArea on any line with aligned
// text or tab-indented code, and the caret drifted by the difference.
// Protect every run of spaces outside markup; the last space of an internal
// run stays ordinary so long lines still wrap where the TextArea wraps.
function preserveSpaces(value) {
  var text = textOf(value)
  var output = ""
  var index = 0
  // Whitespace before any visible character is indentation, which Qt trims
  // outright, so every space of that run has to be protected.
  var visible = false
  while (index < text.length) {
    var char = text.charAt(index)
    if (char === "<") {
      var close = text.indexOf(">", index)
      if (close < 0) {
        output += text.slice(index)
        break
      }
      output += text.slice(index, close + 1)
      index = close + 1
      continue
    }
    if (char !== " " && char !== "\t") {
      output += char
      visible = true
      index += 1
      continue
    }
    var start = index
    while (index < text.length && (text.charAt(index) === " " || text.charAt(index) === "\t")) index += 1
    var run = text.slice(start, index).replace(/\t/g, "    ")
    var keep = visible ? run.length - 1 : run.length
    output += run.slice(0, keep).replace(/ /g, "&nbsp;") + run.slice(keep)
  }
  return output
}

// ------------------------------------------------------------- colour/style
//
// The colour grammar mirrors MarkdownFormat.colourToHex: hex or a plain
// rgb(r, g, b) triple, which is what Joplin/TinyMCE inline spans store.

function normaliseHex(value) {
  var raw = textOf(value).trim().replace(/^#/, "")
  if (!/^[0-9a-fA-F]{3}$|^[0-9a-fA-F]{6}$/.test(raw)) return null
  if (raw.length === 3) {
    raw = raw.charAt(0) + raw.charAt(0) + raw.charAt(1) + raw.charAt(1)
      + raw.charAt(2) + raw.charAt(2)
  }
  return "#" + raw.toLowerCase()
}

function channelText(value) {
  var text = String(value)
  return text.length < 2 ? "0" + text : text
}

function colourChannels(value) {
  var raw = textOf(value).trim()
  var hex = normaliseHex(raw)
  if (hex !== null) {
    return [
      parseInt(hex.slice(1, 3), 16),
      parseInt(hex.slice(3, 5), 16),
      parseInt(hex.slice(5, 7), 16)
    ]
  }
  // Integers only: rejects rgba(), signs, decimals and percentages.
  var match = raw.match(/^rgb\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*\)$/i)
  if (!match) return null
  var channels = [Number(match[1]), Number(match[2]), Number(match[3])]
  for (var i = 0; i < channels.length; i++) {
    if (channels[i] > 255) return null
  }
  return channels
}

function colourToHex(value) {
  var channels = colourChannels(value)
  if (channels === null) return null
  return "#" + channelText(channels[0].toString(16))
    + channelText(channels[1].toString(16))
    + channelText(channels[2].toString(16))
}

// Accept both the rgb() form Joplin stores and older Quill hex spans;
// Qt RichText renders either, but the underlay re-serialises as hex.
function safeHtmlColour(value) {
  return colourToHex(value)
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
function contrastHtmlColour(value, palette) {
  var hex = safeHtmlColour(value)
  if (hex === null) return palette.foreground
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
function protectInlineHtml(source, palette, replacements) {
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
    } else if (!closing && (name === "sup" || name === "sub") && attrs.trim() === "") {
      stack.push({ name: name, start: match.index, end: regex.lastIndex, tag: match[0],
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
  var muted = palette.muted
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
      var fontSize = null
      for (var p = 0; p < tag.props.length; p++) {
        if (tag.props[p].key === "color") colour = tag.props[p].value
        else if (tag.props[p].key === "background-color") background = tag.props[p].value
        // Re-run the same validator the span was read with, so the painted
        // size can only be one the note is allowed to carry.
        else if (tag.props[p].key === "font-size") fontSize = safeHtmlFontSize(tag.props[p].value)
      }
      if (colour !== null || background !== null || fontSize !== null) {
        var styles = []
        if (colour !== null) styles.push("color:" + colour + ";")
        if (background !== null) {
          styles.push("background-color:" + background + ";")
          // Paint the contrast colour without storing it in the note.
          if (colour === null) styles.push("color:" + contrastHtmlColour(background, palette) + ";")
        }
        if (fontSize !== null) styles.push("font-size: " + fontSize + ";")
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

function headingSize(level, base) {
  // Kept for reference: headings used to be scaled up in the underlay, but a
  // TextArea can only have one font size, so scaled headings never matched
  // the caret or the selection height. Headings now share the body size and
  // are distinguished by weight and colour instead.
  return base > 0 ? base : 14
}

function inlineHtml(value, palette, multiline) {
  var source = String(value || "")
  var replacements = []
  var accent = palette.accent
  var muted = palette.muted
  var foreground = palette.foreground
  source = protectInlineHtml(source, palette, replacements)
  // A plain paragraph is rendered in one pass so an inline mark stays open
  // across a soft line break, which is what the preview does for these
  // families. On one line the classes also exclude "\n", so a marker can
  // never reach past its line.
  var eol = multiline ? "" : "\\n"
  var tagPrefix = "(^|[\\s(\\[{>,;:.!?])"
  var pattern = new RegExp(
    "`[^`" + eol + "]+`"
    + "|\\[\\[[^\\]\\n]+\\]\\]"
    + "|" + tagPrefix + "#[A-Za-z0-9_/-]+"
    + "|\\[[^\\]\\n]+\\]\\([^\\s()\\n]+\\)"
    + "|\\*\\*\\*(?!\\s)[^*" + eol + "]*[^*\\s" + eol + "]\\*\\*\\*"
    + "|___(?!\\s)[^_" + eol + "]*[^_\\s" + eol + "]___"
    + "|\\*\\*(?!\\s)[^*" + eol + "]*[^*\\s" + eol + "]\\*\\*"
    + "|__(?!\\s)[^_" + eol + "]*[^_\\s" + eol + "]__"
    + "|~~(?!\\s)[^~" + eol + "]*[^~\\s" + eol + "]~~"
    + "|==(?!\\s)[^=\\n]*[^=\\s\\n]=="
    + "|\\*(?!\\s)[^*" + eol + "]*[^*\\s" + eol + "]\\*"
    + "|_(?!\\s)[^_" + eol + "]*[^_\\s" + eol + "]_"
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
  var html = restoreInlineHtml(output, replacements)
  if (multiline) return html
  return preserveSpaces(html)
}

// A plain paragraph goes through one inline pass, so an inline mark that opens
// on one line and closes on the next paints across both lines, agreeing with
// the preview. The HTML is then split back onto the source lines and joined
// with <br/> for the underlay: every source character still appears exactly
// once, so the caret and selection keep lining up with the painted text.
function paragraphHtml(value, palette) {
  var html = inlineHtml(String(value || ""), palette, true)
  var lines = html.split("\n")
  for (var i = 0; i < lines.length; i++) lines[i] = preserveSpaces(lines[i])
  return lines.join("<br/>")
}

function highlighted(value, palette) {
  var lines = String(value || "").split("\n")
  var output = []
  var paragraph = []
  var inCode = false
  var accent = palette.accent
  var muted = palette.code
  var foreground = palette.foreground

  // Consecutive plain lines are one paragraph. Rendering them together is what
  // lets an inline mark stay open across a soft line break.
  function flushParagraph() {
    if (paragraph.length === 0) return
    output.push(paragraphHtml(paragraph.join("\n"), palette))
    paragraph = []
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") {
      // A blank line ends the paragraph: open marks do not carry across it,
      // which is how the preview renders a pair split by a paragraph break.
      flushParagraph()
      output.push(inlineHtml(line, palette))
      continue
    }
    var fence = line.match(/^(\s*)(```|~~~)/)
    if (fence) {
      flushParagraph()
      output.push(preserveSpaces(escapeHtml(fence[1]))
        + "<span style=\"color:" + accent + ";\">" + escapeHtml(line.slice(fence[1].length)) + "</span>")
      inCode = !inCode
      continue
    }
    if (inCode) {
      output.push("<span style=\"color:" + muted + ";\">" + preserveSpaces(escapeHtml(line)) + "</span>")
      continue
    }

    var heading = line.match(/^(\s{0,3})(#{1,6})(\s+)(.*)$/)
    if (heading) {
      flushParagraph()
      output.push(preserveSpaces(escapeHtml(heading[1]))
        + "<span style=\"color:" + accent + ";\">" + escapeHtml(heading[2]) + "</span>"
        + preserveSpaces(escapeHtml(heading[3]))
        + "<span style=\"color:" + foreground + "; font-weight:600;\">" + inlineHtml(heading[4], palette) + "</span>")
      continue
    }

    var task = line.match(/^(\s*[-*+]\s+)(\[[ xX]\])(?=\s|$)(\s*)/)
    if (task) {
      flushParagraph()
      var taskLength = task[1].length + task[2].length + task[3].length
      output.push(preserveSpaces(escapeHtml(task[1]))
        + "<span style=\"color:" + accent + "; font-weight:600;\">" + escapeHtml(task[2]) + "</span>"
        + preserveSpaces(escapeHtml(task[3])) + inlineHtml(line.slice(taskLength), palette))
      continue
    }

    var quote = line.match(/^(\s*>+\s?)(.*)$/)
    if (quote) {
      flushParagraph()
      output.push("<span style=\"color:" + accent + ";\">" + escapeHtml(quote[1]) + "</span>"
        + "<span style=\"color:" + muted + "; font-style:italic;\">" + inlineHtml(quote[2], palette) + "</span>")
      continue
    }

    var marker = line.match(/^(\s*)([-*+]|\d+[.)])(\s+)/)
    if (marker) {
      flushParagraph()
      var markerLength = marker[1].length + marker[2].length + marker[3].length
      output.push(preserveSpaces(escapeHtml(marker[1]))
        + "<span style=\"color:" + accent + ";\">" + escapeHtml(marker[2]) + "</span>"
        + preserveSpaces(escapeHtml(marker[3])) + inlineHtml(line.slice(markerLength), palette))
      continue
    }

    paragraph.push(line)
  }
  flushParagraph()
  return output.join("<br/>")
}
