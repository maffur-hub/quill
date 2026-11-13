// Markdown extensions for Quill's preview: fenced code blocks, footnotes and
// Pandoc definition lists.
//
// These are block-level features, so they live outside MathText.js (which
// renders one block of inline Markdown to Qt RichText). PreviewBlocks calls
// this module while splitting a note into blocks; MathText only renders the
// inline pieces this module hands back through a renderInline callback.
//
// Plain ES5 with no Qt imports, so node tests can load it with vm and the QML
// preview can pass it around as an explicit dependency.

var FENCE_RE = /^\s{0,3}(`{3,}|~{3,})/
var FOOTNOTE_DEF_RE = /^ {0,3}\[\^([^\]\s]+)\]:(.*)$/
var DEF_MARK_RE = /^ {0,3}[:~][ \t]+(.*)$/
var HEADING_RE = /^\s{0,3}#{1,6}(?:[ \t]|$)/
var HR_RE = /^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/
var QUOTE_RE = /^\s{0,3}>/
var ITEM_RE = /^\s{0,3}(?:[-*+]|\d+[.)])\s+/
var REF_RE = /\[\^([^\]\s]+)\]/g

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function arrayOf(value) {
  return value === undefined || value === null ? [] : value
}

function stripCR(value) {
  var text = textOf(value)
  return text.charAt(text.length - 1) === "\r" ? text.slice(0, -1) : text
}

function isBlank(value) {
  return stripCR(textOf(value)).trim() === ""
}

function escapeHtml(value) {
  return textOf(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function indentWidth(value) {
  var text = stripCR(textOf(value))
  var width = 0
  for (var i = 0; i < text.length; i++) {
    if (text.charAt(i) === " ") width += 1
    else if (text.charAt(i) === "\t") width += 4
    else break
  }
  return width
}

// --- fences ---------------------------------------------------------------

// Mark every line that belongs to a fenced code block, including both fence
// lines. A fence only closes against the same character and at least the same
// length; an unclosed fence runs to the end of the note.
function scanFences(lines) {
  var source = arrayOf(lines)
  var mask = []
  var fence = ""
  for (var i = 0; i < source.length; i++) {
    var match = FENCE_RE.exec(stripCR(source[i]))
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

// The info string is the first word after the fence: ```js, ``` js title="x",
// ```{.python} and ```js{1,3} all name the same grammar.
function codeLanguage(info) {
  var text = textOf(info).trim()
  if (text === "") return ""
  var first = text.charAt(0)
  if (first === "{" || first === "[") {
    var close = text.indexOf(first === "{" ? "}" : "]")
    if (close > 0) text = text.slice(1, close)
  }
  text = text.split(/[ \t]+/)[0]
  text = text.replace(/[{\[][^}\]]*[}\]]$/, "")
  text = text.replace(/^[.\[]/, "").replace(/[{}\],]+$/, "")
  return text.toLowerCase()
}

function openingFence(line) {
  var text = stripCR(line)
  var match = FENCE_RE.exec(text)
  if (!match) return null
  return {
    marker: match[1],
    info: text.slice(match.index + match[0].length)
  }
}

function closesFence(line, marker) {
  var character = marker.charAt(0)
  var re = new RegExp("^\\s{0,3}" + (character === "`" ? "`" : "~")
    + "{" + marker.length + ",}\\s*$")
  return re.test(stripCR(line))
}

// Top-level fenced blocks only. A fence inside a blockquote starts with ">",
// so it never matches FENCE_RE here; it stays part of the quote's text block
// and MathText highlights it when that block is rendered.
function codeBlocks(lines) {
  var source = arrayOf(lines)
  var blocks = []
  var i = 0
  while (i < source.length) {
    var open = openingFence(source[i])
    if (!open) {
      i += 1
      continue
    }
    var start = i
    var code = []
    i += 1
    var closed = false
    while (i < source.length) {
      if (closesFence(source[i], open.marker)) {
        closed = true
        i += 1
        break
      }
      code.push(stripCR(source[i]))
      i += 1
    }
    blocks.push({
      startLine: start,
      endLine: closed ? i - 1 : source.length - 1,
      language: codeLanguage(open.info),
      code: code.join("\n")
    })
  }
  return blocks
}

// --- footnotes ------------------------------------------------------------

// Inline code is literal: a [^label] inside `backticks` is not a reference.
// Length is preserved so offsets stay valid, though callers only need to
// search the masked string.
function maskInlineCode(value) {
  var text = textOf(value)
  var chars = text.split("")
  var i = 0
  while (i < chars.length) {
    if (chars[i] !== "`") {
      i += 1
      continue
    }
    var run = 1
    while (chars[i + run] === "`") run += 1
    var j = i + run
    var close = -1
    while (j < chars.length) {
      if (chars[j] !== "`") {
        j += 1
        continue
      }
      var other = 1
      while (chars[j + other] === "`") other += 1
      if (other === run) {
        close = j
        break
      }
      j += other
    }
    if (close < 0) {
      i += run
      continue
    }
    for (var k = i; k < close + run; k++) {
      if (chars[k] !== "\n" && chars[k] !== "\r") chars[k] = "\u0001"
    }
    i = close + run
  }
  return chars.join("")
}

function escapedAt(text, index) {
  var slashes = 0
  var at = index - 1
  while (at >= 0 && text.charAt(at) === "\\") {
    slashes += 1
    at -= 1
  }
  return slashes % 2 === 1
}

// References in one line, in source order. Definition syntax ([^x]: text) is
// not a reference, and escaped brackets are literal.
function referencesInLine(value) {
  var masked = maskInlineCode(stripCR(value))
  var refs = []
  var match
  REF_RE.lastIndex = 0
  while ((match = REF_RE.exec(masked)) !== null) {
    if (escapedAt(masked, match.index)) continue
    if (masked.charAt(match.index + match[0].length) === ":") continue
    refs.push(match[1])
  }
  return refs
}

function hasFootnoteRefs(value) {
  var lines = textOf(value).split("\n")
  var fenced = scanFences(lines)
  for (var i = 0; i < lines.length; i++) {
    if (fenced[i]) continue
    if (referencesInLine(lines[i]).length > 0) return true
  }
  return false
}

// A definition starts at [^label]: text. Continuation lines are indented by
// at least two spaces; a blank line may sit inside the definition when the
// next non-blank line is still indented. The first non-indented, non-blank
// line ends it. Fenced code is never scanned, so ```[^x]: y``` stays code.
function parseFootnotes(lines) {
  var source = arrayOf(lines)
  var fenced = scanFences(source)
  var skip = []
  var definitions = []
  var i = 0

  for (var s = 0; s < source.length; s++) skip[s] = false

  while (i < source.length) {
    if (fenced[i]) {
      i += 1
      continue
    }
    var match = FOOTNOTE_DEF_RE.exec(stripCR(source[i]))
    if (!match) {
      i += 1
      continue
    }

    var label = match[1]
    var parts = [match[2].replace(/^[ \t]+/, "").replace(/[ \t]+$/, "")]
    skip[i] = true
    var last = i
    var j = i + 1

    while (j < source.length) {
      if (fenced[j]) break
      if (isBlank(source[j])) {
        // Look past the blank run: the definition continues only if the next
        // real line is indented. Those blank lines belong to the definition.
        var next = j + 1
        while (next < source.length && !fenced[next] && isBlank(source[next])) next += 1
        if (next < source.length && !fenced[next] && indentWidth(source[next]) >= 2) {
          for (var blank = j; blank < next; blank++) {
            skip[blank] = true
            parts.push("")
          }
          j = next
          continue
        }
        break
      }
      if (indentWidth(source[j]) < 2) break
      parts.push(stripCR(source[j]).replace(/^[ \t]+/, "").replace(/[ \t]+$/, ""))
      skip[j] = true
      last = j
      j += 1
    }

    definitions.push({
      label: label,
      text: parts.join("\n").replace(/^\s+|\s+$/g, ""),
      startLine: i,
      endLine: last
    })
    i = last + 1
  }

  return { definitions: definitions, skip: skip }
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key)
}

// Numbers follow the first reference in the body. Definitions nobody refers
// to are numbered afterwards rather than dropped: a note is the user's text,
// and hiding part of it because a link is missing would lose content.
function footnoteNumbers(lines, definitions, skip) {
  var source = arrayOf(lines)
  var defs = arrayOf(definitions)
  var skipped = arrayOf(skip)
  var fenced = scanFences(source)
  var known = {}
  var d

  for (d = 0; d < defs.length; d++) known[defs[d].label] = true

  var numbers = {}
  var order = []
  var next = 0
  for (var i = 0; i < source.length; i++) {
    if (skipped[i] || fenced[i]) continue
    var refs = referencesInLine(source[i])
    for (var r = 0; r < refs.length; r++) {
      var label = refs[r]
      if (!hasOwn(known, label) || hasOwn(numbers, label)) continue
      next += 1
      numbers[label] = next
      order.push(label)
    }
  }

  for (d = 0; d < defs.length; d++) {
    var unused = defs[d].label
    if (hasOwn(numbers, unused)) continue
    next += 1
    numbers[unused] = next
    order.push(unused)
  }

  return { numbers: numbers, order: order }
}

// --- definition lists -----------------------------------------------------

function isTermLine(value) {
  var text = stripCR(textOf(value))
  if (text.trim() === "") return false
  if (FENCE_RE.test(text)) return false
  if (HEADING_RE.test(text)) return false
  if (HR_RE.test(text)) return false
  if (QUOTE_RE.test(text)) return false
  if (ITEM_RE.test(text)) return false
  if (FOOTNOTE_DEF_RE.test(text)) return false
  return true
}

function definitionAt(value) {
  var match = DEF_MARK_RE.exec(stripCR(textOf(value)))
  return match ? match[1].replace(/[ \t]+$/, "").trim() : null
}

// A Pandoc definition-list block: a term line immediately followed by one or
// more ":" or "~" definition lines. Adjacent term+definition groups join the
// same block; a blank line starts a new one.
function definitionListAt(lines, index) {
  var source = arrayOf(lines)
  var i = index
  if (i < 0 || i >= source.length) return null
  if (!isTermLine(source[i])) return null
  if (i + 1 >= source.length || definitionAt(source[i + 1]) === null) return null

  var start = i
  var end = i
  var groups = []

  while (i < source.length) {
    if (!isTermLine(source[i])) break
    if (i + 1 >= source.length) break
    if (definitionAt(source[i + 1]) === null) break

    var group = {
      term: stripCR(source[i]).trim(),
      definitions: []
    }
    var j = i + 1
    while (j < source.length) {
      var definition = definitionAt(source[j])
      if (definition === null) break
      group.definitions.push(definition)
      j += 1
    }
    groups.push(group)
    end = j - 1
    i = j

    if (i >= source.length || isBlank(source[i])) break
    if (!isTermLine(source[i])) break
    if (i + 1 >= source.length || definitionAt(source[i + 1]) === null) break
  }

  return { startLine: start, endLine: end, groups: groups }
}

// Qt's RichText engine flattens <dl>/<dt>/<dd> into one run-together line, so
// there is deliberately no HTML emitter here: QML walks block.groups and
// lays each term/definition out itself. definitionListAt above is the whole
// contract.

// --- footnote section -----------------------------------------------------

// The preview draws its own hairline rule above this block, so the HTML is
// only the entries themselves; duplicating a separator here produced a double
// rule in the real render. The top spacing lives on the entries paragraph.
function footnoteSectionHtml(items, renderInline) {
  var list = arrayOf(items)
  if (list.length === 0) return ""
  var render = typeof renderInline === "function" ? renderInline : escapeHtml
  var output = ["<p style=\"margin-top:10px; font-size:90%\">"]
  for (var i = 0; i < list.length; i++) {
    if (i > 0) output.push("<br>")
    output.push("<sup>" + String(list[i].number) + "</sup> " + render(textOf(list[i].text)))
  }
  output.push("</p>")
  return output.join("")
}
