// Markdown → Qt RichText HTML for Quill preview blocks that contain maths.
//
// Qt's Text.MarkdownText cannot baseline-align images, so a block with inline
// maths is rendered as RichText instead. This converter covers the Markdown
// that PreviewPane text blocks actually contain: paragraphs, ATX headings,
// lists, blockquotes, fenced code, horizontal rules, inline emphasis, code
// spans, links and images. The source note is never modified.
//
// Plain ES5 with no Qt imports, so it is node-testable via vm. MathSyntax.js
// is passed in explicitly (third argument, or setSyntax) to keep this file
// free of QML-only .import statements.

var syntaxModule = null

function setSyntax(module) {
  syntaxModule = module
}

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

var FENCE_RE = /^\s{0,3}(`{3,}|~{3,})/
var HEADING_RE = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/
var HR_RE = /^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/
var QUOTE_RE = /^\s{0,3}>\s?(.*)$/
var ITEM_RE = /^\s{0,3}([-*+]|\d+[.)])\s+(.*)$/

// CommonMark's escapable ASCII punctuation. A backslash before one of these
// yields the literal character; before anything else it stays a backslash.
var ESCAPABLE_RE = /\\([!"#$%&'()*+,\-.\/:;<=>?@\[\]\\^_`{|}~])/g

// Private-use markers stand in for generated HTML while the remaining text is
// escaped and emphasis is applied. They cannot collide with Markdown syntax.
var MARK_OPEN = "\uE000"
var MARK_CLOSE = "\uE001"
var MARKER_RE = /\uE000[ms][0-9]+\uE001/g

function escapeHtml(value) {
  return textOf(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function escapeUrl(value) {
  return textOf(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/ /g, "%20")
    .replace(/\t/g, "%09")
}

// Undo exactly one HTML-escape pass. Link/image destinations are captured
// after the whole buffer was escaped, so `?a=1&b=2` arrives as `&amp;`; without
// this the later escapeUrl() would produce `&amp;amp;`.
function unescapeHtml(value) {
  return textOf(value).replace(/&(amp|lt|gt|quot|#39);/g, function(match, name) {
    if (name === "amp") return "&"
    if (name === "lt") return "<"
    if (name === "gt") return ">"
    if (name === "quot") return "\""
    return "'"
  })
}

function cleanUrl(value) {
  var url = textOf(value).trim()
  var lower = url.toLowerCase()
  if (lower.slice(0, 4) === "&lt;" && lower.slice(-4) === "&gt;") url = url.slice(4, -4)
  // Drop a Markdown title: [a](url "title") or [a](url 'title').
  var title = url.search(/\s+(&quot;|')/)
  if (title > 0) url = url.slice(0, title)
  return url.trim()
}

// Raw HTML that survives into RichText. Tags map to themselves except for
// the pairs Qt renders differently: <del> is struck like <s>, <ins> is
// underlined like <u>, <mark> borrows the same highlight as ==text==, and
// <kbd> becomes a key-cap span because Qt gives the tag no default look.
// Attributes are only accepted on <span> (colour/background/size); every
// other allowed tag must be bare, which keeps event handlers out.
var ALLOWED_TAG_RE = /<(\/?)(u|span|sup|sub|kbd|mark|b|i|s|code|var|samp|cite|dfn|del|ins|br)((?:\s+[^>]*)?)\s*\/?>/gi

var SIMPLE_TAGS = {
  u: true, sup: true, sub: true, kbd: true, mark: true, b: true, i: true,
  s: true, code: true, var: true, samp: true, cite: true, dfn: true,
  del: true, ins: true
}

var MARK_HTML = '<span style="background-color:#f5e663; color:#1f1f1f;">'

// A <kbd> with no styling is indistinguishable from body text in Qt, so it
// always becomes a generated span. The QML side supplies theme-aware values;
// anything that is not a plain #rgb/#rrggbb colour falls back to this pair as
// a unit, so a half-valid palette cannot produce unreadable contrast.
var KBD_BACKGROUND = "#2a2d31"
var KBD_TEXT = "#e6e6e6"

function kbdColours(palette) {
  var background = palette ? safeHex(palette.kbdBackground) : null
  var text = palette ? safeHex(palette.kbdText) : null
  if (background === null || text === null) {
    return { background: KBD_BACKGROUND, text: KBD_TEXT }
  }
  return { background: background, text: text }
}

function openTag(name, palette) {
  if (name === "mark") return MARK_HTML
  if (name === "del") return "<s>"
  if (name === "ins") return "<u>"
  if (name === "kbd") {
    var colours = kbdColours(palette)
    return '<span style="background-color:' + colours.background + "; color:"
      + colours.text + '">'
  }
  return "<" + name + ">"
}

function closeTag(name) {
  if (name === "mark") return "</span>"
  if (name === "kbd") return "</span>"
  if (name === "del") return "</s>"
  if (name === "ins") return "</u>"
  return "</" + name + ">"
}

function safeHex(value) {
  var raw = textOf(value).trim()
  if (raw.charAt(0) !== "#") return null
  raw = raw.slice(1)
  if (!/^[0-9a-fA-F]{3}$|^[0-9a-fA-F]{6}$/.test(raw)) return null
  if (raw.length === 3) {
    raw = raw.charAt(0) + raw.charAt(0) + raw.charAt(1) + raw.charAt(1)
      + raw.charAt(2) + raw.charAt(2)
  }
  return "#" + raw.toLowerCase()
}

// Joplin stores colours as rgb(r, g, b); Quill's older spans used hex. Both
// are accepted and canonicalised, nothing else is.
function safeRgb(value) {
  var match = textOf(value).trim()
    .match(/^rgb\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*\)$/i)
  if (!match) return null
  var channels = [Number(match[1]), Number(match[2]), Number(match[3])]
  for (var i = 0; i < channels.length; i++) {
    if (channels[i] > 255) return null
  }
  return "rgb(" + channels[0] + ", " + channels[1] + ", " + channels[2] + ")"
}

function safeColour(value) {
  var colour = safeHex(value)
  return colour === null ? safeRgb(value) : colour
}

function safeFontSize(value) {
  var match = textOf(value).trim().match(/^([0-9]+(?:\.[0-9]+)?)(%|em|px|pt)$/i)
  if (!match) return null
  var amount = Number(match[1])
  var unit = match[2].toLowerCase()
  if (!isFinite(amount) || amount <= 0) return null
  if (unit === "em") return amount >= 0.1 && amount <= 10 ? amount + unit : null
  return amount >= 1 && amount <= 400 ? amount + unit : null
}

// Readable foreground for a stored background colour. Computed at render time
// only; the note keeps just background-color.
function contrastColour(value) {
  var colour = safeColour(value)
  if (colour === null) return "#101315"
  var red, green, blue
  if (colour.charAt(0) === "#") {
    red = parseInt(colour.slice(1, 3), 16)
    green = parseInt(colour.slice(3, 5), 16)
    blue = parseInt(colour.slice(5, 7), 16)
  } else {
    var match = colour.match(/\(([^)]*)\)/)
    var channels = match ? match[1].split(",") : []
    red = Number(channels[0])
    green = Number(channels[1])
    blue = Number(channels[2])
  }
  return (0.299 * red + 0.587 * green + 0.114 * blue) > 150 ? "#101315" : "#ffffff"
}

// Only style="..." is allowed, and only colour / background / font-size
// declarations. Every other attribute and every other CSS property is
// rejected.
function safeSpanStyle(attributes) {
  var match = textOf(attributes).match(/^\s+style="([^"]*)"\s*$/i)
  if (!match) return null
  var pieces = []
  var hasColour = false
  var background = null
  var declarations = match[1].split(";")
  for (var i = 0; i < declarations.length; i++) {
    var part = declarations[i].trim()
    if (part === "") continue
    var colon = part.indexOf(":")
    if (colon < 1) return null
    var key = part.slice(0, colon).trim().toLowerCase()
    var value = part.slice(colon + 1).trim()
    if (key === "color") {
      var colour = safeColour(value)
      if (colour === null) return null
      hasColour = true
      pieces.push("color:" + colour)
    } else if (key === "background-color") {
      var fill = safeColour(value)
      if (fill === null) return null
      background = fill
      pieces.push("background-color:" + fill)
    } else if (key === "font-size") {
      var size = safeFontSize(value)
      if (size === null) return null
      pieces.push("font-size:" + size)
    } else {
      return null
    }
  }
  if (background !== null && !hasColour) pieces.push("color:" + contrastColour(background))
  return pieces.length === 0 ? null : pieces.join("; ")
}

function hasFormatting(value) {
  var text = textOf(value)
  if (/<\/?u>/i.test(text)) return true
  if (/<\/?(sup|sub)>/i.test(text)) return true
  if (/<\/?(?:kbd|mark|b|i|s|code|var|samp|cite|dfn|del|ins|br)(?:\s[^>]*)?\/?>/i.test(text)) return true
  if (/==[^=\n]+==/.test(text)) return true
  if (/<span\s+style="[^"]*">/i.test(text)) return true
  if (/^\s{0,3}[-*+]\s+\[[ xX]\]\s+/m.test(text)) return true
  // Footnote references need RichText as well: a MarkdownText block would
  // print [^label] literally instead of linking it to the notes section.
  if (/\[\^[^\]\s]+\]/.test(text)) return true
  // Fenced code reaches this block only inside a blockquote (top-level fences
  // become code blocks); route it here so the highlighter can colour it.
  if (/^(?: {0,3}> ?)*[ \t]{0,3}(`{3,}|~{3,})/m.test(text)) return true
  // Qt's Text.MarkdownText paints single-underscore emphasis as underline,
  // unlike the editor underlay and every other Markdown renderer. Route those
  // blocks through this converter so _text_ is italic everywhere.
  if (/(^|[^\\A-Za-z0-9_])_(?!_)[^_\n]+_(?![A-Za-z0-9_])/m.test(text)) return true
  return false
}

function isFence(line) {
  return FENCE_RE.test(line)
}

// The info string names the language: ```js, ``` js title="x", ```{.python}
// and ```js{1,3} all yield a grammar key the highlighter understands.
function fenceLanguage(line) {
  var source = textOf(line)
  var match = FENCE_RE.exec(source)
  if (!match) return ""
  var info = source.slice(match.index + match[0].length).trim()
  if (info === "") return ""
  var first = info.charAt(0)
  if (first === "{" || first === "[") {
    var close = info.indexOf(first === "{" ? "}" : "]")
    if (close > 0) info = info.slice(1, close)
  }
  var token = info.split(/[ \t]+/)[0]
  token = token.replace(/[{\[][^}\]]*[}\]]$/, "")
  token = token.replace(/^[.\[]/, "").replace(/[{}\],]+$/, "")
  return token.toLowerCase()
}

function isBlank(line) {
  return textOf(line).trim() === ""
}

function blockStart(line) {
  return isFence(line) || HEADING_RE.test(line) || HR_RE.test(line)
    || QUOTE_RE.test(line) || ITEM_RE.test(line)
}

function applyEmphasis(value) {
  var out = value
  out = out.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
  out = out.replace(/__([^_]+)__/g, "<b>$1</b>")
  out = out.replace(/~~([^~]+)~~/g, "<s>$1</s>")
  // Joplin's markdown-it-mark syntax. Only a full ==pair== counts; === and a
  // lone = stay literal, and a highlight never crosses a line break.
  out = out.replace(/==([^=\n]+)==/g,
    '<span style="background-color:#f5e663; color:#1f1f1f;">$1</span>')
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>")
  out = out.replace(/(^|[^_\w])_([^_\n]+)_/g, "$1<i>$2</i>")
  return out
}

function mathImage(path) {
  return "<img src=\"file://" + escapeUrl(path) + "\" valign=\"middle\" alt=\"math\">"
}

// Qt's MarkdownText puts exactly 7 px between block elements at every font
// size; RichText's default <p> margins add 12. Add MarkdownText's spacing to
// every block after the first so a maths block keeps the note's rhythm.
function withBlockSpacing(blocks) {
  var output = []
  for (var i = 0; i < blocks.length; i++) {
    var html = blocks[i]
    var end = html.indexOf(">")
    var start = end > 0 ? html.slice(0, end) : ""
    if (start !== "" && start.indexOf(" style=") < 0) {
      html = start + " style=\"margin-top:7px; margin-bottom:0px\"" + html.slice(end)
    }
    output.push(html)
  }
  return output.join("")
}

function displayMath(tex, resolve) {
  var result = resolve ? resolve(tex, true) : null
  if (result && result.ok) {
    return "<p align=\"center\">" + mathImage(String(result.path || "")) + "</p>"
  }
  return "<p align=\"center\">" + escapeHtml("$$" + tex + "$$") + "</p>"
}

// Inline conversion. Escapes raw text exactly once; generated tags and maths
// images are inserted through placeholders so emphasis cannot corrupt them.
function renderInline(value, resolve, syntax, options) {
  var text = textOf(value)
  if (text === "") return ""
  var tokens = syntax ? syntax.scan(text) : [{ type: "text", text: text }]
  var buffer = ""
  var maths = []
  for (var t = 0; t < tokens.length; t++) {
    if (tokens[t].type === "math") {
      var marker = MARK_OPEN + "m" + maths.length + MARK_CLOSE
      maths.push({ marker: marker, tex: tokens[t].tex })
      buffer += marker
    } else {
      buffer += tokens[t].text
    }
  }

  var html = ""
  var slots = []
  var nextSlot = 0

  function slot(value, plain) {
    var marker = MARK_OPEN + "s" + nextSlot + MARK_CLOSE
    nextSlot += 1
    slots.push({ marker: marker, html: value, plain: plain })
    return marker
  }

  function protectWhitelistTags(value) {
    var text = String(value)
    var entries = []
    var stack = []
    ALLOWED_TAG_RE.lastIndex = 0
    var match
    while ((match = ALLOWED_TAG_RE.exec(text)) !== null) {
      var closing = match[1] === "/"
      var name = match[2].toLowerCase()
      var attributes = match[3] || ""
      // A self-closing slash (<br />) is not an attribute.
      var bare = attributes.replace(/\/\s*$/, "").trim() === ""
      if (closing) {
        if (!bare) continue
        if (stack.length > 0 && stack[stack.length - 1].name === name) {
          var closed = stack.pop()
          closed.valid = true
          entries.push({ start: closed.start, end: closed.end, html: closed.html })
          entries.push({ start: match.index, end: match.index + match[0].length,
            html: closeTag(name) })
        }
        continue
      }
      if (name === "br") {
        // A void tag: no pair, no attributes, always the RichText <br>.
        if (bare) entries.push({ start: match.index, end: match.index + match[0].length,
          html: "<br>" })
        continue
      }
      if (name === "span") {
        var style = safeSpanStyle(attributes)
        if (style === null) continue
        stack.push({ name: "span", start: match.index, end: match.index + match[0].length,
          html: '<span style="' + style + '">', valid: false })
        continue
      }
      if (SIMPLE_TAGS[name] && bare) {
        stack.push({ name: name, start: match.index, end: match.index + match[0].length,
          html: openTag(name, options ? options.palette : null), valid: false })
      }
    }
    if (entries.length === 0) return text
    entries.sort(function(a, b) { return b.start - a.start })
    var output = text
    for (var i = 0; i < entries.length; i++) {
      output = output.slice(0, entries[i].start) + slot(entries[i].html, "")
        + output.slice(entries[i].end)
    }
    return output
  }

  // Text-safe expansion for attributes (alt/href), which cannot hold tags.
  function stripMarkers(value) {
    var output = String(value).replace(MARKER_RE, function(marker) {
      for (var i = 0; i < slots.length; i++) {
        if (slots[i].marker === marker) {
          return slots[i].plain === undefined ? "" : slots[i].plain
        }
      }
      return ""
    })
    output = output.replace(/\uE000m[0-9]+\uE001/g, "")
    // Text-safe contexts (alt/href) cannot hold the inline wrappers either.
    output = output.replace(/<\/?(sup|sub)>/gi, "")
    output = output.replace(/==([^=\n]+)==/g, "$1")
    return output
  }

  // Inline code spans come first, before escaping and before backslash
  // handling: their contents are literal, so `\$5` stays a backslash and a
  // dollar. The slot's plain form is escaped because attributes use it.
  buffer = buffer.replace(/`([^`\n]+)`/g, function(match, code) {
    var escaped = escapeHtml(code)
    return slot("<tt>" + escaped + "</tt>", escaped)
  })

  // Backslash punctuation through slots as well, so an escaped * or [ can
  // never reach the emphasis and link regexes.
  buffer = buffer.replace(ESCAPABLE_RE, function(match, character) {
    var literal = escapeHtml(character)
    return slot(literal, literal)
  })

  // Footnote references become links through slots, so the label's number
  // comes from the block builder's first-reference numbering. A label with no
  // definition is not a reference and stays literal; inline code has already
  // been turned into a slot above, so refs inside backticks are untouched.
  var numbers = options && options.footnotes ? options.footnotes.numbers : null
  if (numbers) {
    buffer = buffer.replace(/\[\^([^\]\s]+)\](?!:)/g, function(match, label) {
      if (!Object.prototype.hasOwnProperty.call(numbers, label)) return match
      var safe = escapeHtml(label)
      return slot("<a href=\"#fn-" + safe + "\" name=\"fnref-" + safe
        + "\"><sup>" + String(numbers[label]) + "</sup></a>", "")
    })
  }

  // Whitelist inline HTML. Only well-formed pairs of the allowlisted tags
  // survive; <span> additionally has to carry a safe colour/background/size
  // style. Every other tag stays literal text and is escaped below.
  buffer = protectWhitelistTags(buffer)

  html = escapeHtml(buffer)

  // Images before links (the leading ! is otherwise just text).
  html = html.replace(/!\[([^\]]*)\]\(([^)]*)\)/g, function(match, alt, target) {
    var src = unescapeHtml(cleanUrl(target))
    if (src === "") return match
    // Attributes cannot hold formatting; unwrap any pending code marker.
    return slot("<img src=\"" + escapeUrl(src) + "\" alt=\""
      + stripMarkers(alt) + "\">")
  })

  html = html.replace(/\[([^\]]+)\]\(([^)]*)\)/g, function(match, label, target) {
    var href = unescapeHtml(cleanUrl(target))
    if (href === "") return match
    href = stripMarkers(href)
    return slot("<a href=\"" + escapeUrl(href) + "\">" + applyEmphasis(label) + "</a>")
  })

  html = applyEmphasis(html)

  // Restore newest first: a later slot's HTML can contain an earlier slot's
  // marker (for example a code span inside a link label).
  for (var s = slots.length - 1; s >= 0; s--) {
    html = html.split(slots[s].marker).join(slots[s].html)
  }

  for (var m = 0; m < maths.length; m++) {
    var result = resolve ? resolve(maths[m].tex, false) : null
    var replacement = result && result.ok
      ? mathImage(String(result.path || ""))
      : escapeHtml("$" + maths[m].tex + "$")
    html = html.split(maths[m].marker).join(replacement)
  }

  return html
}

function renderBlocks(lines, resolve, syntax, depth, options) {
  var output = []
  var i = 0
  var displays = syntax ? syntax.findDisplayBlocks(lines) : []
  var displayAt = {}
  for (var d = 0; d < displays.length; d++) displayAt[displays[d].startLine] = displays[d]

  while (i < lines.length) {
    var line = lines[i]

    if (displayAt[i]) {
      output.push(displayMath(displayAt[i].tex, resolve))
      i = displayAt[i].endLine + 1
      continue
    }

    if (isBlank(line)) {
      i += 1
      continue
    }

    if (isFence(line)) {
      var language = fenceLanguage(line)
      var fence = line.match(FENCE_RE)[1]
      var character = fence.charAt(0)
      var closing = new RegExp("^\\s{0,3}" + (character === "`" ? "`" : "~")
        + "{" + fence.length + ",}\\s*$")
      var code = []
      i += 1
      while (i < lines.length) {
        if (closing.test(lines[i])) { i += 1; break }
        code.push(lines[i])
        i += 1
      }
      var body = code.join("\n")
      var highlight = options ? options.highlight : null
      var rendered = highlight && typeof highlight.toHtml === "function"
        ? textOf(highlight.toHtml(body, language, options ? options.palette : null))
        : escapeHtml(body)
      output.push("<pre style=\"margin-top:7px; margin-bottom:0\">" + rendered + "</pre>")
      continue
    }

    var heading = line.match(HEADING_RE)
    if (heading) {
      var level = heading[1].length
      output.push("<h" + level + ">"
        + renderInline(heading[2], resolve, syntax, options)
        + "</h" + level + ">")
      i += 1
      continue
    }

    if (HR_RE.test(line)) {
      output.push("<hr>")
      i += 1
      continue
    }

    if (QUOTE_RE.test(line)) {
      var quoted = []
      while (i < lines.length && QUOTE_RE.test(lines[i])) {
        quoted.push(lines[i].match(QUOTE_RE)[1])
        i += 1
      }
      var inner = depth < 6 ? renderBlocks(quoted, resolve, syntax, depth + 1, options) : ""
      output.push("<blockquote>" + inner + "</blockquote>")
      continue
    }

    var item = line.match(ITEM_RE)
    if (item) {
      var ordered = /^[0-9]/.test(item[1])
      var items = []
      while (i < lines.length) {
        var current = lines[i].match(ITEM_RE)
        if (!current || /^[0-9]/.test(current[1]) !== ordered) break
        var task = current[2].match(/^\[([ xX])\]\s?(.*)$/)
        if (task) {
          items.push("<li>" + (task[1].toLowerCase() === "x" ? "☑" : "☐") + " "
            + renderInline(task[2], resolve, syntax, options) + "</li>")
        } else {
          items.push("<li>" + renderInline(current[2], resolve, syntax, options) + "</li>")
        }
        i += 1
      }
      var tag = ordered ? "ol" : "ul"
      output.push("<" + tag + ">" + items.join("") + "</" + tag + ">")
      continue
    }

    var paragraph = []
    while (i < lines.length && !isBlank(lines[i]) && !displayAt[i] && !blockStart(lines[i])) {
      paragraph.push(lines[i])
      i += 1
    }
    if (paragraph.length === 0) {
      i += 1
      continue
    }
    output.push("<p>" + renderInline(paragraph.join("\n"), resolve, syntax, options) + "</p>")
  }

  return withBlockSpacing(output)
}

// resolve(tex, display) returns { ok: true, path: "/abs/file.svg" } or null.
// While maths is pending the raw TeX is kept visible as escaped text.
// options (4th argument) carries { highlight, palette, footnotes: {numbers} }.
function toHtml(markdown, resolve, syntaxArg, options) {
  var syntax = syntaxModule
  if (!syntax && resolve && resolve.syntax) syntax = resolve.syntax
  if (!syntax && arguments.length > 2) syntax = syntaxArg
  var source = textOf(markdown)
  if (source.trim() === "") return ""
  return renderBlocks(source.split("\n"), resolve, syntax, 0, options)
}
