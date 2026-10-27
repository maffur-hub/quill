// Maths syntax detection for Quill.
//
// Plain ES5 with no Qt imports, so the preview block splitter (PreviewPane),
// the rich-text converter (MathText.js) and the node tests all share one
// definition of what counts as maths. The on-disk Markdown is never rewritten:
// this module only reports offsets and TeX source.
//
// Supported delimiters:
//   $...$        inline maths
//   \(...\)      inline maths
//   $$...$$      display maths, one line or several
//   \[...\]      display maths, one line or several
//
// Everything inside fenced code blocks, inline code spans, and anything
// escaped with a backslash is left alone. A bare `$` that looks like a price
// (`$5`, `$1,200.50`) or that has no closing partner is text, not maths.

var FENCE_RE = /^\s{0,3}(`{3,}|~{3,})/
var ITEM_MARK = "\u0001"

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function stripCR(line) {
  var text = textOf(line)
  return text.charAt(text.length - 1) === "\r" ? text.slice(0, -1) : text
}

function isSpace(ch) {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r"
}

function isBlank(value) {
  return textOf(value).trim() === ""
}

function repeat(value, count) {
  var output = ""
  for (var i = 0; i < count; i++) output += value
  return output
}

// Mask the regions maths must not see: fenced code blocks, inline code spans,
// escaped dollars/backticks/backslashes. Length and line breaks are preserved,
// so offsets into the masked string are offsets into the source.
function mask(text) {
  var chars = text.split("")
  var length = chars.length
  var lineStarts = [0]
  for (var s = 0; s < length; s++) {
    if (chars[s] === "\n") lineStarts.push(s + 1)
  }

  // Fenced code blocks (``` or ~~~), including an unclosed fence at EOF.
  var line = 0
  while (line < lineStarts.length) {
    var start = lineStarts[line]
    var end = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : length
    var current = text.slice(start, end)
    var match = current.match(FENCE_RE)
    if (!match) {
      line += 1
      continue
    }
    var marker = match[1]
    var character = marker.charAt(0)
    var closingRe = new RegExp("^\\s{0,3}" + (character === "`" ? "`" : "~")
      + "{" + marker.length + ",}\\s*$")
    for (var c = start; c < end; c++) chars[c] = ITEM_MARK
    line += 1
    while (line < lineStarts.length) {
      var nextStart = lineStarts[line]
      var nextEnd = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : length
      for (var d = nextStart; d < nextEnd; d++) chars[d] = ITEM_MARK
      var closes = closingRe.test(text.slice(nextStart, nextEnd))
      line += 1
      if (closes) break
    }
  }

  var masked = chars.join("")

  // Inline code spans: a run of N backticks up to the next run of N. Fenced
  // lines are already masked, so this only sees ordinary text.
  var i = 0
  while (i < masked.length) {
    if (masked.charAt(i) !== "`") {
      i += 1
      continue
    }
    var run = 1
    while (masked.charAt(i + run) === "`") run += 1
    var fence = repeat("`", run)
    var close = masked.indexOf(fence, i + run)
    if (close < 0) {
      // No partner: mask the run itself so it cannot pair with later ticks.
      for (var k = i; k < i + run; k++) chars[k] = ITEM_MARK
      i += run
      continue
    }
    // Inline code does not cross a blank line.
    var between = masked.slice(i + run, close)
    if (between.indexOf("\n\n") >= 0 || between.indexOf("\r\n\r\n") >= 0) {
      for (var m = i; m < i + run; m++) chars[m] = ITEM_MARK
      i += run
      continue
    }
    // Keep line breaks: offsets and the line array must stay aligned even
    // when a code span wraps onto the next line.
    for (var n = i; n < close + run; n++) {
      if (chars[n] !== "\n" && chars[n] !== "\r") chars[n] = ITEM_MARK
    }
    i = close + run
  }

  masked = chars.join("")

  // Backslash escapes: \$ and \` are literal, and a second backslash in \\
  // must not escape the character after it. Delimiters (\( \) \[ \]) are left
  // intact, because those are maths markers rather than escapes.
  for (var j = 0; j < masked.length; j++) {
    if (masked.charAt(j) !== "\\") continue
    var after = masked.charAt(j + 1)
    if (after === "$" || after === "`" || after === "\\") chars[j + 1] = ITEM_MARK
    j += 1
  }

  return chars.join("")
}

function displayOpen(line) {
  var lead = line.length - line.replace(/^\s+/, "").length
  var at = line.slice(lead, lead + 2)
  if (at === "$$") return { marker: "$$", close: "$$", col: lead }
  if (at === "\\[") return { marker: "\\[", close: "\\]", col: lead }
  return null
}

// Display blocks, line-oriented. startLine/endLine are 0-based indices into
// the passed lines array. The TeX source is the exact text between markers.
function findDisplayBlocks(lines) {
  var source = []
  var input = lines === undefined || lines === null ? [] : lines
  for (var l = 0; l < input.length; l++) source.push(stripCR(input[l]))
  var maskedLines = mask(source.join("\n")).split("\n")
  var blocks = []
  var i = 0

  while (i < source.length) {
    var open = displayOpen(maskedLines[i] === undefined ? "" : maskedLines[i])
    if (!open) {
      i += 1
      continue
    }
    var afterColumn = open.col + open.marker.length
    var after = maskedLines[i].slice(afterColumn)

    // One-line block: the closing marker ends the line.
    var sameLine = after.indexOf(open.close)
    if (sameLine >= 0 && after.slice(sameLine + open.close.length).trim() === "") {
      var inlineTex = source[i].slice(afterColumn, afterColumn + sameLine)
      if (!isBlank(inlineTex)) blocks.push({ startLine: i, endLine: i, tex: inlineTex.trim() })
      i += 1
      continue
    }

    // Multi-line block: find a closing line whose tail is whitespace.
    var closed = false
    for (var j = i + 1; j < maskedLines.length; j++) {
      var at = maskedLines[j].indexOf(open.close)
      if (at < 0 || maskedLines[j].slice(at + open.close.length).trim() !== "") continue
      var parts = []
      if (after.trim() !== "") parts.push(source[i].slice(afterColumn))
      for (var middle = i + 1; middle < j; middle++) parts.push(source[middle])
      var before = source[j].slice(0, at)
      if (before.trim() !== "") parts.push(before)
      var tex = parts.join("\n").replace(/^\s+|\s+$/g, "")
      if (!isBlank(tex)) blocks.push({ startLine: i, endLine: j, tex: tex })
      i = j + 1
      closed = true
      break
    }
    if (!closed) i += 1
  }

  return blocks
}

function findClose(masked, from, delimiter) {
  var at = masked.indexOf(delimiter, from)
  return at
}

function dollarClose(masked, open, limit) {
  var j = open + 1
  while (j < limit) {
    var ch = masked.charAt(j)
    if (ch === "\\") { j += 2; continue }
    if (ch === "\n" && (masked.charAt(j + 1) === "\n" || masked.charAt(j + 1) === "\r")) break
    if (ch === "$") {
      if (masked.charAt(j + 1) === "$") { j += 2; continue }
      if (j > 0 && !isSpace(masked.charAt(j - 1))) return j
    }
    j += 1
  }
  return -1
}

// Character spans for inline maths. Offsets refer to the passed string.
function inlineSpans(value) {
  var text = textOf(value)
  var masked = mask(text)
  var spans = []
  var i = 0

  while (i < masked.length) {
    var ch = masked.charAt(i)

    if (ch === "\\" && masked.charAt(i + 1) === "(") {
      var closeParen = findClose(masked, i + 2, "\\)")
      if (closeParen >= 0 && !isBlank(text.slice(i + 2, closeParen))) {
        spans.push({ start: i, end: closeParen + 2, tex: text.slice(i + 2, closeParen) })
        i = closeParen + 2
        continue
      }
      i += 1
      continue
    }

    if (ch !== "$") {
      i += 1
      continue
    }

    if (masked.charAt(i + 1) === "$") {
      // Display maths is handled by findDisplayBlocks.
      i += 2
      continue
    }

    var next = masked.charAt(i + 1)
    if (next === "" || isSpace(next)) {
      i += 1
      continue
    }

    var limit = masked.length
    if (next >= "0" && next <= "9") {
      // Currency guard: $5 and $1,200.50 are prices, not maths. A real
      // formula that starts with a digit has its closing $ before any space.
      var space = i + 1
      while (space < masked.length && !isSpace(masked.charAt(space))) space += 1
      limit = space
    }

    var close = dollarClose(masked, i, limit)
    if (close < 0) {
      i += 1
      continue
    }

    var tex = text.slice(i + 1, close)
    if (isBlank(tex)) {
      i += 1
      continue
    }
    spans.push({ start: i, end: close + 1, tex: tex })
    i = close + 1
  }

  return spans
}

function hasInlineMath(value) {
  return inlineSpans(value).length > 0
}

// Ordered tokens for MathText.js: text chunks exactly as written, maths chunks
// carrying only the TeX source.
function scan(value) {
  var text = textOf(value)
  var spans = inlineSpans(text)
  var tokens = []
  var at = 0
  for (var i = 0; i < spans.length; i++) {
    if (spans[i].start > at) tokens.push({ type: "text", text: text.slice(at, spans[i].start) })
    tokens.push({ type: "math", tex: spans[i].tex })
    at = spans[i].end
  }
  if (at < text.length) tokens.push({ type: "text", text: text.slice(at) })
  return tokens
}
