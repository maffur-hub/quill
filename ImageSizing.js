// Image sizing helpers for Quill's Markdown preview.
//
// Kept as plain ES5 with no Qt imports so the exact parsing and rewriting
// logic can also be exercised from node (see the test harness).
//
// Supported source forms:
//   ![alt](path){width=320}          ![alt](path){width=320px}
//   ![alt](path){height=200}         ![alt](path){width=320 height=200}
//   ![alt|320](path)                 Obsidian-style width (read-only support)
//
// Only image-only lines are recognised, matching PreviewPane's block splitter.
// A malformed or absurd value is simply ignored, so the block still renders
// with its default size instead of disappearing.

var IMAGE_LINE = /^(\s*)!\[([^\]]*)\]\((<[^>]+>|[^)\s]+)\)(\s*\{([^{}]*)\})?\s*$/
var MAX_DIMENSION = 20000

function toPositiveInt(value) {
  var n = parseInt(value, 10)
  if (!isFinite(n) || n <= 0 || n > MAX_DIMENSION) return null
  return n
}

// Read `width=NNN` / `height=NNN` (an optional px suffix is allowed) from the
// inside of a { ... } attribute list.
function attributeValue(attributes, name) {
  if (!attributes) return null
  var pattern = new RegExp("(?:^|[\\s,;])" + name + "\\s*=\\s*(\\d+)(?:\\s*px)?(?=$|[\\s,;])", "i")
  var match = String(attributes).match(pattern)
  return match ? toPositiveInt(match[1]) : null
}

function splitLine(line) {
  var text = String(line === undefined || line === null ? "" : line)
  var match = text.match(IMAGE_LINE)
  if (!match) return null

  var source = match[3]
  if (source.length >= 2 && source.charAt(0) === "<" && source.charAt(source.length - 1) === ">") {
    source = source.slice(1, -1)
  }

  var altRaw = match[2]
  var attributes = match[5] || ""
  var width = attributeValue(attributes, "width")
  var height = attributeValue(attributes, "height")

  // Obsidian writes the width in the alt text: ![alt|320](path). Only the
  // trailing all-digit segment is a size; a normal alt containing "|" is not.
  var obsidian = altRaw.match(/\|(\d{1,5})\s*$/)
  var obsidianWidth = obsidian ? toPositiveInt(obsidian[1]) : null
  var alt = obsidian ? altRaw.slice(0, obsidian.index) : altRaw
  if (width === null && obsidianWidth !== null) width = obsidianWidth
  var namesSize = /(?:^|[\s,;])(?:width|height)\s*=/i.test(attributes)

  return {
    alt: alt,
    altRaw: altRaw,
    source: source,
    attributes: attributes,
    width: width,
    height: height,
    hasSize: width !== null || height !== null || namesSize
  }
}

// Split markdown into renderable blocks. Image-only lines become image blocks
// carrying their zero-based line index in the markdown string; everything
// else is joined into text blocks (blank-only blocks are dropped, as before).
function splitBlocks(value) {
  var lines = String(value === undefined || value === null ? "" : value).split("\n")
  var result = []
  var buffer = []

  function flushText() {
    if (buffer.length === 0) return
    var joined = buffer.join("\n")
    buffer = []
    if (joined.trim() === "") return
    result.push({ kind: "text", text: joined })
  }

  for (var i = 0; i < lines.length; i++) {
    var parsed = splitLine(lines[i])
    if (!parsed) {
      buffer.push(lines[i])
      continue
    }
    flushText()
    result.push({
      kind: "image",
      source: parsed.source,
      alt: parsed.alt,
      size: parsed,
      line: i
    })
  }
  flushText()
  return result
}

// Split markdown into renderable blocks. Image-only lines become image blocks
// carrying their zero-based line index in the markdown string; everything
// else is joined into text blocks (blank-only blocks are dropped, as before).

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Resolve the requested size into a display box for a pane of `available`
// pixels. `ratio` is the image's width / height, or 0 while it is loading.
// Returns null for the default (no explicit size) behaviour, which the caller
// keeps exactly as it was before sizing existed.
function displayFor(size, available, ratio) {
  if (!size || !size.hasSize) return null
  var maxWidth = Math.max(60, Math.floor(available || 0))
  var width = size.width === null ? null : clamp(size.width, 60, maxWidth)
  var height = size.height === null ? null : clamp(size.height, 60, MAX_DIMENSION)

  if (width !== null && height !== null) {
    return { mode: "box", width: width, height: height }
  }
  if (width !== null) {
    return { mode: "width", width: width, height: ratio > 0 ? width / ratio : 0 }
  }
  if (height !== null) {
    var boxHeight = height
    var boxWidth = ratio > 0 ? boxHeight * ratio : 0
    if (boxWidth > maxWidth) {
      // A tall image only fits the pane if it is also scaled down.
      boxHeight = maxWidth / ratio
      boxWidth = maxWidth
    }
    return { mode: "height", width: boxWidth, height: boxHeight }
  }
  return null
}

// Replace (or append) the trailing size suffix with {width=NNN}. Obsidian's
// |NNN alt form is normalised into the portable brace form. Returns null when
// the line is not an image-only line.
function setWidth(line, width) {
  var n = Math.round(Number(width))
  if (!isFinite(n)) return null
  var bounded = clamp(n, 60, MAX_DIMENSION)
  var parsed = splitLine(line)
  if (!parsed) return null

  var text = String(line)
  var carriage = /\r$/.test(text) ? "\r" : ""
  var body = carriage ? text.slice(0, -1) : text
  var match = body.match(IMAGE_LINE)
  var indent = match[1]
  var alt = match[2].replace(/\|\s*\d{1,5}\s*$/, "")

  return indent + "![" + alt + "](" + match[3] + "){width=" + bounded + "}" + carriage
}

// Remove both the { ... } suffix and an Obsidian |NNN width. Returns null for
// non-image lines; the unchanged line when there was no size to remove.
function clearSize(line) {
  var parsed = splitLine(line)
  if (!parsed) return null

  var text = String(line)
  var carriage = /\r$/.test(text) ? "\r" : ""
  var body = carriage ? text.slice(0, -1) : text
  var match = body.match(IMAGE_LINE)
  var indent = match[1]
  var alt = match[2].replace(/\|\s*\d{1,5}\s*$/, "")

  return indent + "![" + alt + "](" + match[3] + ")" + carriage
}
