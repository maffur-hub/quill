// Markdown formatting engine for Quill.
//
// Plain ES5 with no Qt imports, so every action can be exercised from node.
// The editor calls plan() with the current text and selection and receives the
// final text, the selection to restore, and a minimal edit descriptor. The
// returned edit is applied with TextEdit.remove()/insert() rather than
// assigning the whole document, so undo history stays local.
//
// Actions write ordinary Markdown. The only HTML Quill emits is a small
// whitelist that Joplin and Qt RichText both understand: <u>...</u> and
// <span style="...">...</span> spans for text colour, background highlight and
// font size. Joplin stores colours as an rgb() triple, so new spans use that
// canonical form; hex input is still accepted and old hex spans can be
// replaced in place.

var SEL_OPEN = "\uE100"
var SEL_CLOSE = "\uE101"

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// ------------------------------------------------------------ task lines
// A task line is a bullet whose first token is an unchecked or checked box:
//   - [ ] buy milk
//   * [x] done
//   + [ ] (empty content is allowed)
// The preview uses parseTaskLine to draw a checkbox and toggleTaskLine to
// rewrite only the box character, so everything else stays byte-identical.

function parseTaskLine(line) {
  var value = textOf(line)
  // The box must be followed by whitespace or the end of the line: a word
  // like "- [x]ylophone" is a bullet, not a task.
  var match = /^([ \t]*)([-*+])\s+\[([ xX])\](?:[ \t]+(.*))?$/.exec(value)
  if (!match) return null
  var lead = match[1]
  var indent = 0
  for (var i = 0; i < lead.length; i++) {
    indent += lead.charAt(i) === "\t" ? 4 : 1
  }
  return {
    indent: indent,
    checked: match[3] === "x" || match[3] === "X",
    content: match[4] === undefined ? "" : match[4]
  }
}

function toggleTaskLine(line) {
  var parsed = parseTaskLine(line)
  if (!parsed) return null
  var value = textOf(line)
  // Locate the box character without rebuilding the line: the marker,
  // spacing and trailing content must survive exactly as written.
  var match = /^([ \t]*)([-*+])(\s+)\[([ xX])\]/.exec(value)
  if (!match) return null
  var box = match[1].length + match[2].length + match[3].length + 1
  var next = parsed.checked ? " " : "x"
  return value.slice(0, box) + next + value.slice(box + 1)
}

function normaliseSelection(text, start, end) {
  var length = text.length
  var from = clamp(Math.floor(Number(start) || 0), 0, length)
  var to = clamp(Math.floor(Number(end) || 0), 0, length)
  return from <= to ? { start: from, end: to } : { start: to, end: from }
}

// Inline formatting must never wrap between the characters of an HTML tag.
// Selecting the "<" of "</span>" used to insert a new close tag inside the
// old one, producing garbage such as "<</span>/span>". A boundary may sit
// before "<" or after ">", never strictly inside a tag.
function tagRanges(text) {
  var ranges = []
  var index = 0
  while (index < text.length) {
    var lt = text.indexOf("<", index)
    if (lt < 0) break
    var next = text.charAt(lt + 1)
    // "a < b" and "<3" are text, not tags.
    if (!/[A-Za-z\/]/.test(next)) {
      index = lt + 1
      continue
    }
    var gt = text.indexOf(">", lt + 1)
    if (gt < 0) break
    var nested = text.indexOf("<", lt + 1)
    if (nested >= 0 && nested < gt) {
      index = lt + 1
      continue
    }
    ranges.push({ start: lt, end: gt + 1 })
    index = gt + 1
  }
  return ranges
}

function clampOutsideTags(text, start, end) {
  var source = textOf(text)
  var length = source.length
  var from = clamp(Math.floor(Number(start) || 0), 0, length)
  var to = clamp(Math.floor(Number(end) || 0), 0, length)
  if (from > to) {
    var swap = from
    from = to
    to = swap
  }
  var ranges = tagRanges(source)
  for (var i = 0; i < ranges.length; i++) {
    // Strictly inside, including immediately before ">".
    if (ranges[i].start < from && from <= ranges[i].end - 1) {
      from = ranges[i].end
      break
    }
  }
  for (var j = ranges.length - 1; j >= 0; j--) {
    if (ranges[j].start < to && to <= ranges[j].end - 1) {
      to = ranges[j].start
      break
    }
  }
  if (from > to) from = to
  return { start: from, end: to }
}

function lineStartAt(text, position) {
  var cut = text.lastIndexOf("\n", Math.max(0, position - 1))
  return cut < 0 ? 0 : cut + 1
}

function lineEndAt(text, position) {
  var cut = text.indexOf("\n", position)
  return cut < 0 ? text.length : cut
}

function isEscaped(text, index) {
  var count = 0
  for (var i = index - 1; i >= 0 && text.charAt(i) === "\\"; i--) count += 1
  return count % 2 === 1
}

function repeat(value, count) {
  var output = ""
  for (var i = 0; i < count; i++) output += value
  return output
}

// ------------------------------------------------------------------ results

function diffEdit(oldText, newText) {
  if (oldText === newText) return []
  var prefix = 0
  var maxPrefix = Math.min(oldText.length, newText.length)
  while (prefix < maxPrefix && oldText.charAt(prefix) === newText.charAt(prefix)) prefix += 1
  var suffix = 0
  var maxSuffix = Math.min(oldText.length - prefix, newText.length - prefix)
  while (suffix < maxSuffix
    && oldText.charAt(oldText.length - 1 - suffix) === newText.charAt(newText.length - 1 - suffix)) {
    suffix += 1
  }
  return [{
    start: prefix,
    end: oldText.length - suffix,
    text: newText.slice(prefix, newText.length - suffix)
  }]
}

// Split a plan's coarse replacement into the least destructive native edits.
//
// The formatter describes a toggle as one replacement (replace "hello" with
// "**hello**"). Applying that literally removes the selected text and inserts
// it again, so a native undo that lands between the two commands restores a
// hole. Whenever the new text still contains the old segment unchanged, emit
// pure inserts around it instead; when the old text contains the new segment,
// emit pure deletes. Only a genuinely different middle becomes a small
// remove+insert. The returned edits are in the original text's coordinates.
function minimalEdits(oldText, edits) {
  var source = textOf(oldText)
  var input = edits || []
  var output = []
  for (var i = 0; i < input.length; i++) {
    var edit = input[i] || {}
    var start = clamp(Math.floor(Number(edit.start) || 0), 0, source.length)
    var end = clamp(Math.floor(Number(edit.end) || start), start, source.length)
    var next = textOf(edit.text)
    var original = source.slice(start, end)

    if (start === end) {
      if (next !== "") output.push({ start: start, end: start, text: next })
      continue
    }
    if (next === "") {
      output.push({ start: start, end: end, text: "" })
      continue
    }
    if (original === next) continue

    // The old segment survives inside the replacement: insert only what was
    // added, leaving the original characters untouched.
    var at = original === "" ? -1 : next.indexOf(original)
    if (at >= 0 && next.indexOf(original, at + 1) < 0) {
      if (at > 0) output.push({ start: start, end: start, text: next.slice(0, at) })
      var tail = at + original.length
      if (tail < next.length) output.push({ start: end, end: end, text: next.slice(tail) })
      continue
    }

    // The replacement survives inside the old segment (for example removing
    // ** from **hello**): delete only the characters that disappear.
    var keptAt = next === "" ? -1 : original.indexOf(next)
    if (keptAt >= 0 && original.indexOf(next, keptAt + 1) < 0) {
      if (keptAt > 0) output.push({ start: start, end: start + keptAt, text: "" })
      var keptEnd = keptAt + next.length
      if (keptEnd < original.length) output.push({ start: start + keptEnd, end: end, text: "" })
      continue
    }

    // Genuinely different text: keep the common prefix/suffix and replace the
    // narrow middle only.
    var prefix = 0
    var maxPrefix = Math.min(original.length, next.length)
    while (prefix < maxPrefix && original.charAt(prefix) === next.charAt(prefix)) prefix += 1
    var suffix = 0
    var maxSuffix = Math.min(original.length - prefix, next.length - prefix)
    while (suffix < maxSuffix
      && original.charAt(original.length - 1 - suffix) === next.charAt(next.length - 1 - suffix)) {
      suffix += 1
    }
    output.push({
      start: start + prefix,
      end: end - suffix,
      text: next.slice(prefix, next.length - suffix)
    })
  }
  return output
}

function finish(oldText, newText, selectionStart, selectionEnd, extra) {
  var length = newText.length
  var result = {
    ok: true,
    text: newText,
    selectionStart: clamp(Math.floor(Number(selectionStart) || 0), 0, length),
    selectionEnd: clamp(Math.floor(Number(selectionEnd) || 0), 0, length),
    edits: diffEdit(oldText, newText)
  }
  if (result.selectionStart > result.selectionEnd) {
    var swap = result.selectionStart
    result.selectionStart = result.selectionEnd
    result.selectionEnd = swap
  }
  if (extra) {
    for (var key in extra) result[key] = extra[key]
  }
  return result
}

function fail(message) {
  return { ok: false, error: String(message || "Cannot apply formatting") }
}

function applyEdits(text, edits) {
  var ordered = (edits || []).slice().sort(function(a, b) { return b.start - a.start })
  var output = text
  for (var i = 0; i < ordered.length; i++) {
    var edit = ordered[i]
    output = output.slice(0, edit.start) + (edit.text || "") + output.slice(edit.end)
  }
  return output
}

function mapOffset(edits, offset, bias) {
  var ordered = (edits || []).slice().sort(function(a, b) { return a.start - b.start })
  var shift = 0
  for (var i = 0; i < ordered.length; i++) {
    var edit = ordered[i]
    var newLength = String(edit.text || "").length
    var delta = newLength - (edit.end - edit.start)
    if (offset < edit.start) break
    if (offset > edit.end) {
      shift += delta
      continue
    }
    if (offset === edit.start && offset === edit.end) {
      return offset + shift + (bias === "end" ? newLength : 0)
    }
    if (offset === edit.start) {
      return edit.start + shift + (bias === "end" ? newLength : 0)
    }
    if (offset === edit.end) {
      shift += delta
      return offset + shift
    }
    return edit.start + shift + (bias === "end" ? newLength : 0)
  }
  return offset + shift
}

// ------------------------------------------------------------- colour/style

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

// Canonical Joplin/TinyMCE inline colour: rgb(224, 62, 45).
function normaliseColour(value) {
  var channels = colourChannels(value)
  if (channels === null) return null
  return "rgb(" + channels[0] + ", " + channels[1] + ", " + channels[2] + ")"
}

function colourToHex(value) {
  var channels = colourChannels(value)
  if (channels === null) return null
  return "#" + channelText(channels[0].toString(16))
    + channelText(channels[1].toString(16))
    + channelText(channels[2].toString(16))
}

function parseStyle(styleText) {
  var props = []
  var parts = textOf(styleText).split(";")
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim()
    if (part === "") continue
    var colon = part.indexOf(":")
    if (colon < 1) continue
    var key = part.slice(0, colon).trim().toLowerCase()
    var value = part.slice(colon + 1).trim()
    props.push({ key: key, value: value })
  }
  return props
}

function styleText(props) {
  var pieces = []
  for (var i = 0; i < props.length; i++) {
    pieces.push(props[i].key + ": " + props[i].value + ";")
  }
  return pieces.join(" ")
}

function propsWith(props, key, value) {
  var output = []
  var found = false
  for (var i = 0; i < props.length; i++) {
    if (props[i].key === key) {
      if (value !== null && value !== "") {
        output.push({ key: key, value: value })
        found = true
      }
    } else {
      output.push({ key: props[i].key, value: props[i].value })
    }
  }
  if (!found && value !== null && value !== "") output.push({ key: key, value: value })
  return output
}

function spanTag(props) {
  return '<span style="' + styleText(props) + '">'
}

function parseSpanTag(text, start) {
  if (text.slice(start, start + 5).toLowerCase() !== "<span") return null
  var close = text.indexOf(">", start)
  if (close < 0) return null
  var tag = text.slice(start, close + 1)
  var match = tag.match(/^<span\s+style="([^"]*)"\s*>$/i)
  if (!match) return null
  return {
    tag: tag,
    start: start,
    end: close + 1,
    props: parseStyle(match[1])
  }
}

// All well-formed <span style="..."> pairs, with nesting.
function collectSpans(text) {
  var spans = []
  var stack = []
  var index = 0
  while (index < text.length) {
    var lt = text.indexOf("<", index)
    if (lt < 0) break
    if (text.slice(lt, lt + 6).toLowerCase() === "</span") {
      var gt = text.indexOf(">", lt)
      if (gt < 0) break
      if (stack.length > 0) {
        var open = stack.pop()
        spans.push({
          openStart: open.start,
          openEnd: open.end,
          closeStart: lt,
          closeEnd: gt + 1,
          props: open.props,
          tag: open.tag
        })
      }
      index = gt + 1
      continue
    }
    var parsed = parseSpanTag(text, lt)
    if (parsed) {
      stack.push(parsed)
      index = parsed.end
      continue
    }
    index = lt + 1
  }
  return spans
}

function hasProp(span, key) {
  for (var i = 0; i < span.props.length; i++) if (span.props[i].key === key) return true
  return false
}

function propValue(span, key) {
  for (var i = 0; i < span.props.length; i++) if (span.props[i].key === key) return span.props[i].value
  return null
}

// A span whose whole content is selected. start/end are the selection-marker
// boundaries in marked space, so the content-end boundary is one before the
// close tag (right + 1 === closeStart when the selection ends there).
function enclosingSpan(spans, start, end, key) {
  var best = null
  for (var i = 0; i < spans.length; i++) {
    var span = spans[i]
    if (!hasProp(span, key)) continue
    if (span.openStart <= start && span.closeEnd >= end && start <= span.openEnd
      && end + 1 >= span.closeStart) {
      if (!best || span.openStart > best.openStart) best = span
    }
  }
  return best
}

// A same-key span that contains the selection without covering all of its
// content. Used to split the span instead of recolouring all of it.
function partialSpan(spans, start, end, key) {
  var best = null
  for (var i = 0; i < spans.length; i++) {
    var span = spans[i]
    if (!hasProp(span, key)) continue
    if (span.openEnd > start || span.closeStart < end) continue
    if (start <= span.openEnd && end >= span.closeStart) continue
    if (!best || span.openStart > best.openStart) best = span
  }
  return best
}

function replaceSpanPropertyRaw(text, span, key, value) {
  var props = propsWith(span.props, key, value)
  if (props.length === 0) {
    return text.slice(0, span.openStart) + text.slice(span.openEnd, span.closeStart)
      + text.slice(span.closeEnd)
  }
  return text.slice(0, span.openStart) + spanTag(props) + text.slice(span.openEnd)
}

// Split a simple (tag-free content) span around a partial selection:
// before text / middle with the new property (or plain, when removing) / after.
function splitSpanText(text, span, start, end, key, value) {
  var middleProps = propsWith(span.props, key, value === "" ? null : value)
  var middleOpen = middleProps.length === 0 ? "" : spanTag(middleProps)
  var beforeText = text.slice(span.openEnd, start)
  var afterText = text.slice(end, span.closeStart)
  var before = beforeText === "" ? "" : span.tag + beforeText + "</span>"
  var after = afterText === "" ? "" : span.tag + afterText + "</span>"
  var middle = text.slice(start, end)
  var output = text.slice(0, span.openStart) + before + middleOpen + middle
    + (middleOpen === "" ? "" : "</span>") + after + text.slice(span.closeEnd)
  var selectionStart = span.openStart + before.length + middleOpen.length
  return {
    text: output,
    selectionStart: selectionStart,
    selectionEnd: selectionStart + middle.length
  }
}

// Well-formedness of the inline tags the planner itself emits: span, u, sup
// and sub. A stack keeps openers and closers in order, so a pair that crosses
// another pair is rejected. Any other "<" is plain text. Escape sequences are
// deliberately not handled, matching the blindness of the count-based check
// this replaces.
function inlineWellFormed(text) {
  var pattern = /<(\/?)(span|u|sup|sub)\b[^>]*>/gi
  var stack = []
  var match
  while ((match = pattern.exec(text)) !== null) {
    var name = match[2].toLowerCase()
    if (match[1] === "") {
      stack.push(name)
    } else if (stack.length === 0 || stack[stack.length - 1] !== name) {
      return false
    } else {
      stack.pop()
    }
  }
  return stack.length === 0
}

// Refuse output that creates a malformed close-tag run or breaks inline tag
// nesting that used to be intact. Texts that were already unbalanced (for
// example a code sample showing literal tags, or a note written before this
// guard existed) are left alone.
function spanEditIsSafe(oldText, newText) {
  if (newText.indexOf("<<") >= 0 && oldText.indexOf("<<") < 0) return false
  if (newText.indexOf("<</span>") >= 0 && oldText.indexOf("<</span>") < 0) return false
  if (inlineWellFormed(oldText) && !inlineWellFormed(newText)) return false
  return true
}

function finishSpan(oldText, newText, selectionStart, selectionEnd) {
  if (!spanEditIsSafe(oldText, newText)) return fail("Cannot apply formatting across a tag")
  return finish(oldText, newText, selectionStart, selectionEnd)
}

function replaceSpanProperty(marked, span, key, value) {
  var props = propsWith(span.props, key, value)
  if (props.length === 0) {
    return marked.slice(0, span.openStart) + marked.slice(span.openEnd, span.closeStart)
      + marked.slice(span.closeEnd)
  }
  return marked.slice(0, span.openStart) + spanTag(props) + marked.slice(span.openEnd)
}

// Remove a property from spans that intersect a selected range. The range is
// marked with private-use sentinels so callers do not have to track offsets
// through several tag replacements.
function stripPropertyInRange(marked, key) {
  var left = marked.indexOf(SEL_OPEN)
  var right = marked.indexOf(SEL_CLOSE)
  if (left < 0 || right < 0) return marked
  var spans = collectSpans(marked)
  var touching = []
  for (var i = 0; i < spans.length; i++) {
    var span = spans[i]
    if (!hasProp(span, key)) continue
    if (span.openStart < right && span.closeEnd > left) touching.push(span)
  }
  touching.sort(function(a, b) { return b.openStart - a.openStart })
  var output = marked
  for (var t = 0; t < touching.length; t++) {
    // Re-collect because earlier removals can remove nested tags.
    var current = collectSpans(output)
    var found = null
    for (var c = 0; c < current.length; c++) {
      if (current[c].openStart === touching[t].openStart
        && current[c].closeEnd === touching[t].closeEnd) { found = current[c]; break }
    }
    if (found) output = replaceSpanProperty(output, found, key, null)
  }
  return output
}

function markSelection(text, start, end) {
  return text.slice(0, start) + SEL_OPEN + text.slice(start, end) + SEL_CLOSE + text.slice(end)
}

function extractSelection(marked) {
  var left = marked.indexOf(SEL_OPEN)
  var right = marked.indexOf(SEL_CLOSE)
  if (left < 0 || right < 0 || right < left) return { text: marked, selectionStart: 0, selectionEnd: 0 }
  var clean = marked.slice(0, left) + marked.slice(left + 1, right) + marked.slice(right + 1)
  return { text: clean, selectionStart: left, selectionEnd: right - 1 }
}

function insertWrapped(marked, open, close) {
  var left = marked.indexOf(SEL_OPEN)
  var right = marked.indexOf(SEL_CLOSE)
  if (left < 0 || right < 0) return marked
  var withTags = marked.slice(0, left) + open + marked.slice(left, right + 1) + close
    + marked.slice(right + 1)
  return withTags
}

// -------------------------------------------------------------- inline marks

var INLINE_MARKS = {
  bold: { open: "**", close: "**", kind: "bold" },
  italic: { open: "*", close: "*", kind: "italic" },
  underline: { open: "<u>", close: "</u>", kind: "tag" },
  strike: { open: "~~", close: "~~", kind: "pair" },
  code: { open: "`", close: "`", kind: "code" },
  highlight: { open: "==", close: "==", kind: "pair" },
  superscript: { open: "<sup>", close: "</sup>", kind: "tag" },
  subscript: { open: "<sub>", close: "</sub>", kind: "tag" }
}

function isSpaceChar(value) {
  return value === "" || value === " " || value === "\t" || value === "\n" || value === "\r"
}

// Bounds of the run of `char` around `position`, so a ** token is never read
// as a * one and a list bullet is never read as italic.
function runBounds(text, position, char) {
  var start = position
  while (start > 0 && text.charAt(start - 1) === char) start -= 1
  var end = position
  while (end + 1 < text.length && text.charAt(end + 1) === char) end += 1
  return { start: start, end: end + 1, length: end - start + 1 }
}

// Matched markers on the lines that hold [from, to). Symmetric marks alternate
// opener and closer, which is how CommonMark resolves runs of one marker; the
// underline and sup/sub tags use a stack so nesting stays balanced. Runs that
// belong to a stronger marker are skipped, so a caret between two bold words
// is not mistaken for a caret inside one.
function inlinePairs(text, mark, from, to) {
  var pairs = []
  if (mark.kind === "tag") {
    var stack = []
    var index = from
    while (index < to) {
      if (text.substr(index, mark.open.length) === mark.open && !isEscaped(text, index)) {
        stack.push(index)
        index += mark.open.length
      } else if (text.substr(index, mark.close.length) === mark.close
        && !isEscaped(text, index)) {
        if (stack.length > 0) {
          var opened = stack.pop()
          pairs.push({ openAt: opened, openLen: mark.open.length,
            closeAt: index, closeLen: mark.close.length })
        }
        index += mark.close.length
      } else {
        index += 1
      }
    }
    return pairs
  }
  var delimiters = markerDelimiters(text, mark, from, to)
  var opener = null
  for (var i = 0; i < delimiters.length; i++) {
    if (!opener) {
      opener = delimiters[i]
    } else {
      pairs.push({ openAt: opener.at, openLen: opener.len,
        closeAt: delimiters[i].at, closeLen: delimiters[i].len })
      opener = null
    }
  }
  return pairs
}

function markerDelimiters(text, mark, from, to) {
  var list = []
  var char = mark.open.charAt(0)
  var expectOpener = true
  var index = from
  while (index < to) {
    if (text.charAt(index) !== char) { index += 1; continue }
    var run = runBounds(text, index, char)
    index = run.end
    if (run.start < from || isEscaped(text, run.start)) continue
    var after = text.charAt(run.end)
    var before = text.charAt(run.start - 1)
    var at = run.start
    var len = mark.open.length
    if (mark.kind === "italic") {
      if (run.length !== 1 && run.length !== 3) continue
      if (expectOpener && isSpaceChar(after)) continue
      if (!expectOpener && isSpaceChar(before)) continue
      // The italic layer of a triple run is the star next to the content.
      at = expectOpener ? run.end - 1 : run.start
      len = 1
    } else if (mark.kind === "bold") {
      if (run.length !== 2 && run.length !== 3) continue
      if (expectOpener && isSpaceChar(after)) continue
      if (!expectOpener && isSpaceChar(before)) continue
      len = 2
    } else if (mark.kind === "code") {
      if (run.length !== 1) continue
    } else {
      if (run.length !== 2) continue
      if (expectOpener && isSpaceChar(after)) continue
      if (!expectOpener && isSpaceChar(before)) continue
    }
    list.push({ at: at, len: len })
    expectOpener = !expectOpener
  }
  return list
}

function hasInlineMarker(text, mark, from, to) {
  if (mark.kind === "tag") {
    for (var i = from; i < to; i++) {
      if (isEscaped(text, i)) continue
      if (text.substr(i, mark.open.length) === mark.open) return true
      if (text.substr(i, mark.close.length) === mark.close) return true
    }
    return false
  }
  return markerDelimiters(text, mark, from, to).length > 0
}

function removePairs(oldText, pairs, start, end) {
  var edits = []
  for (var i = 0; i < pairs.length; i++) {
    edits.push({ start: pairs[i].openAt, end: pairs[i].openAt + pairs[i].openLen, text: "" })
    edits.push({ start: pairs[i].closeAt, end: pairs[i].closeAt + pairs[i].closeLen, text: "" })
  }
  edits.sort(function(a, b) { return a.start - b.start })
  var newText = ""
  var cursor = 0
  for (var e = 0; e < edits.length; e++) {
    newText += oldText.slice(cursor, edits[e].start)
    cursor = edits[e].end
  }
  newText += oldText.slice(cursor)
  return finish(oldText, newText, mapOffset(edits, start), mapOffset(edits, end))
}

function planInline(oldText, mark, start, end, name) {
  var pairs = inlinePairs(oldText, mark, lineStartAt(oldText, start), lineEndAt(oldText, end))

  if (start === end) {
    var around = null
    for (var i = 0; i < pairs.length; i++) {
      var pair = pairs[i]
      if (start >= pair.openAt + pair.openLen && start <= pair.closeAt) {
        if (!around || pair.openAt > around.openAt) around = pair
      }
    }
    if (around) return removePairs(oldText, [around], start, end)
    return finish(oldText, oldText.slice(0, start) + mark.open + mark.close
      + oldText.slice(start), start + mark.open.length, start + mark.open.length)
  }

  var covered = null
  var enclosing = null
  for (var j = 0; j < pairs.length; j++) {
    var candidate = pairs[j]
    if (candidate.openAt === start && candidate.closeAt + candidate.closeLen === end) {
      covered = candidate
      break
    }
    if (start >= candidate.openAt + candidate.openLen && end <= candidate.closeAt) {
      if (!enclosing || candidate.openAt > enclosing.openAt) enclosing = candidate
    }
  }
  if (covered) return removePairs(oldText, [covered], start, end)
  if (enclosing) return removePairs(oldText, [enclosing], start, end)
  if (hasInlineMarker(oldText, mark, start, end)) {
    return fail("Cannot toggle " + String(name || "formatting") + " across existing markers")
  }
  // Wrapping next to an existing run would fuse the markers into one longer
  // run, which Markdown resolves unpredictably. Refuse instead.
  var char = mark.kind === "tag" ? "" : mark.open.charAt(0)
  if (char !== "" && (oldText.charAt(start) === char || oldText.charAt(end - 1) === char
    || oldText.charAt(start - 1) === char || oldText.charAt(end) === char)) {
    return fail("Cannot toggle " + String(name || "formatting") + " next to existing markers")
  }
  var carried = oldText.slice(0, start) + mark.open + oldText.slice(start, end)
    + mark.close + oldText.slice(end)
  var wrappedStart = start + mark.open.length
  var wrappedEnd = end + mark.open.length
  // A tag mark (underline, sup, sub) wraps with real tags, so it can cross a
  // tag pair on either side of the selection. Marker marks cannot.
  if (mark.kind === "tag") return finishSpan(oldText, carried, wrappedStart, wrappedEnd)
  return finish(oldText, carried, wrappedStart, wrappedEnd)
}


// ------------------------------------------------------------------- lists

function lineObjects(text) {
  var raw = text.split("\n")
  var lines = []
  var offset = 0
  for (var i = 0; i < raw.length; i++) {
    var value = raw[i]
    var cr = value.charAt(value.length - 1) === "\r"
    lines.push({
      index: i,
      start: offset,
      end: offset + value.length - (cr ? 1 : 0),
      text: cr ? value.slice(0, -1) : value,
      cr: cr
    })
    offset += value.length + 1
  }
  return lines
}

function lineIndexAt(lines, position) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (position >= lines[i].start) return i
  }
  return 0
}

function selectedLines(text, start, end) {
  var lines = lineObjects(text)
  var first = lineIndexAt(lines, start)
  var last = lineIndexAt(lines, end)
  if (end > start && end === lines[last].start && last > first) last -= 1
  return { lines: lines, first: first, last: last }
}

function lineParts(line) {
  var match = line.text.match(/^(\s*)(.*)$/)
  return { indent: match[1], rest: match[2] }
}

function listPrefix(rest) {
  if (/^[-*+]\s+\[[ xX]\]\s+/.test(rest)) {
    return { kind: "task", match: rest.match(/^[-*+]\s+\[[ xX]\]\s+/) }
  }
  if (/^[-*+]\s+/.test(rest)) {
    return { kind: "bullet", match: rest.match(/^[-*+]\s+/) }
  }
  if (/^\d+[.)]\s+/.test(rest)) {
    return { kind: "number", match: rest.match(/^\d+[.)]\s+/) }
  }
  if (/^>\s?/.test(rest)) {
    return { kind: "quote", match: rest.match(/^>\s?/) }
  }
  return null
}

function headingPrefix(rest) {
  var match = rest.match(/^(#{1,6})\s+/)
  if (!match) return null
  return { level: match[1].length, length: match[0].length, text: match[0] }
}

function planList(oldText, start, end, kind) {
  var chosen = selectedLines(oldText, start, end)
  var lines = chosen.lines
  var indices = []
  for (var i = chosen.first; i <= chosen.last; i++) {
    if (lines[i].text.trim() === "" && !(start === end && i === chosen.first)) continue
    indices.push(i)
  }
  if (indices.length === 0) return finish(oldText, oldText, start, end)

  var allowed = indices.every(function(index) {
    var parts = lineParts(lines[index])
    var prefix = listPrefix(parts.rest)
    if (kind === "number") return prefix && prefix.kind === "number"
    if (kind === "task") return prefix && prefix.kind === "task"
    if (kind === "quote") return prefix && prefix.kind === "quote"
    return prefix && prefix.kind === "bullet"
  })

  var edits = []
  var number = 1
  for (var j = 0; j < indices.length; j++) {
    var line = lines[indices[j]]
    var parts = lineParts(line)
    var prefix = listPrefix(parts.rest)
    var removeLength = 0
    if (prefix) {
      if (kind === "quote") {
        if (prefix.kind === "quote") removeLength = prefix.match[0].length
      } else if (kind === "task" && prefix.kind === "task") {
        removeLength = allowed ? prefix.match[0].length : 0
      } else {
        removeLength = prefix.match[0].length
      }
    }
    var replacement = ""
    var keepTask = kind === "task" && !allowed && prefix && prefix.kind === "task"
    if (!allowed && !keepTask) {
      var indent = parts.indent
      if (kind === "bullet") replacement = "- "
      else if (kind === "number") replacement = (number++) + ". "
      else if (kind === "task") replacement = "- [ ] "
      else if (kind === "quote") replacement = "> "
    }
    var at = line.start + parts.indent.length
    edits.push({ start: at, end: at + removeLength, text: replacement })
  }
  var newText = applyEdits(oldText, edits)
  var selectionStart = mapOffset(edits, start, "end")
  var selectionEnd = mapOffset(edits, end, "end")
  return finish(oldText, newText, selectionStart, selectionEnd)
}

function planHeading(oldText, start, end, level) {
  // 0 removes a heading, 1..6 add/change ATX levels.
  level = clamp(Math.floor(Number(level) || 0), 0, 6)
  var chosen = selectedLines(oldText, start, end)
  var lines = chosen.lines
  var indices = []
  for (var i = chosen.first; i <= chosen.last; i++) {
    if (lines[i].text.trim() === "" && !(start === end && i === chosen.first)) continue
    indices.push(i)
  }
  if (indices.length === 0) return finish(oldText, oldText, start, end)
  var allowed = indices.every(function(index) {
    var parts = lineParts(lines[index])
    var heading = headingPrefix(parts.rest)
    return heading && heading.level === level
  })
  var edits = []
  for (var j = 0; j < indices.length; j++) {
    var line = lines[indices[j]]
    var parts = lineParts(line)
    var heading = headingPrefix(parts.rest)
    var removeLength = heading ? heading.length : 0
    // Level 0 means "no heading": drop any existing prefix and never add one.
    var replacement = allowed || level === 0 ? "" : repeat("#", level) + " "
    var at = line.start + parts.indent.length
    edits.push({ start: at, end: at + removeLength, text: replacement })
  }
  var newText = applyEdits(oldText, edits)
  return finish(oldText, newText, mapOffset(edits, start, "end"), mapOffset(edits, end, "end"))
}

// -------------------------------------------------------------------- spans

function planSpan(oldText, start, end, key, value) {
  var marked = markSelection(oldText, start, end)
  var left = marked.indexOf(SEL_OPEN)
  var right = marked.indexOf(SEL_CLOSE)
  var target = value === "" ? null : value
  var cssKey = key === "color" ? "color"
    : key === "background-color" ? "background-color" : "font-size"
  var open = '<span style="' + cssKey + ": " + value + ';">'
  if (left < 0 || right < 0) return fail("Cannot apply formatting across a tag")

  // Caret only: recolour the span under the cursor in place. A caret outside
  // any same-key span inserts an empty pair, matching the other inline marks.
  if (start === end) {
    var spans = collectSpans(marked)
    var inside = null
    for (var i = 0; i < spans.length; i++) {
      var candidate = spans[i]
      if (!hasProp(candidate, key)) continue
      if (candidate.openEnd <= left && left <= candidate.closeStart) {
        if (!inside || candidate.openStart > inside.openStart) inside = candidate
      }
    }
    if (inside) {
      var updated = replaceSpanProperty(marked, inside, key, target)
      var extracted = extractSelection(updated)
      return finishSpan(oldText, extracted.text, extracted.selectionStart,
        extracted.selectionEnd)
    }
    if (value === "") return finish(oldText, oldText, start, end)
    var inserted = insertWrapped(marked, open, "</span>")
    var empty = extractSelection(inserted)
    return finishSpan(oldText, empty.text, empty.selectionStart, empty.selectionEnd)
  }

  // Same-key spans that touch the selected range. The selection sentinels sit
  // immediately outside the selected text, so content overlap is
  // [openEnd, closeStart) versus (left, right).
  var all = collectSpans(marked)
  var targets = []
  var tagEdits = []
  var fullCount = 0
  var full = null
  for (var t = 0; t < all.length; t++) {
    var span = all[t]
    if (!hasProp(span, key)) continue
    var hasContent = span.openEnd < right && span.closeStart > left + 1
    if (!hasContent) {
      // A tag can sit inside the selection while its content is outside it
      // (for example the stop of span A and the start of span B). Move such a
      // tag out of the selected range so the new span cannot colour text the
      // user did not select.
      var openInside = span.openStart >= left && span.openEnd <= right
      var closeInside = span.closeStart >= left && span.closeEnd <= right
      if (openInside && closeInside) {
        tagEdits.push({ start: span.openStart, end: span.openEnd, text: "" })
        tagEdits.push({ start: span.closeStart, end: span.closeEnd, text: "" })
      } else if (openInside) {
        tagEdits.push({ start: span.openStart, end: span.openEnd, text: "" })
        tagEdits.push({ start: right + 1, end: right + 1, text: span.tag })
      } else if (closeInside) {
        tagEdits.push({ start: span.closeStart, end: span.closeEnd, text: "" })
        tagEdits.push({ start: left, end: left, text: "</span>" })
      }
      continue
    }
    targets.push(span)
    if (left <= span.openEnd && right + 1 >= span.closeStart) {
      fullCount += 1
      full = span
    }
  }

  // Selecting only the tags between two same-key spans changes no visible
  // text, so leave the note exactly as it is.
  if (targets.length === 0 && tagEdits.length > 0) {
    return finish(oldText, oldText, start, end)
  }

  // One span whose whole content is selected: rewrite its numbers in place,
  // never nesting a second span of the same property.
  if (targets.length === 1 && fullCount === 1) {
    var replaced = replaceSpanProperty(marked, full, key, target)
    var selection = extractSelection(replaced)
    return finishSpan(oldText, selection.text, selection.selectionStart, selection.selectionEnd)
  }

  // Selection inside one span: split it into before / selected / after so only
  // the middle piece changes. Nested markup cannot be cut safely, so the
  // documented fallback recolours the whole outer span instead.
  var partial = partialSpan(collectSpans(oldText), start, end, key)
  if (partial) {
    var content = oldText.slice(partial.openEnd, partial.closeStart)
    if (content.indexOf("<") < 0) {
      var split = splitSpanText(oldText, partial, start, end, key, value)
      return finishSpan(oldText, split.text, split.selectionStart, split.selectionEnd)
    }
    var partialProps = propsWith(partial.props, key, target)
    var oldOpenLength = partial.openEnd - partial.openStart
    var newOpenLength = partialProps.length === 0 ? 0 : spanTag(partialProps).length
    var shift = newOpenLength - oldOpenLength
    var whole = replaceSpanPropertyRaw(oldText, partial, key, target)
    return finishSpan(oldText, whole, start + shift, end + shift)
  }

  // General case: split every touched span at the selection boundary. The
  // selected part loses the old property and the parts outside it keep their
  // original span tag; the new span is added once around the whole selection.
  // This also covers selections that straddle two adjacent same-key spans.
  var edits = tagEdits.slice()
  for (var g = 0; g < targets.length; g++) {
    var current = targets[g]
    var isFull = left <= current.openEnd && right + 1 >= current.closeStart
    if (isFull) {
      var remaining = propsWith(current.props, key, null)
      if (remaining.length === 0) {
        edits.push({ start: current.openStart, end: current.openEnd, text: "" })
        edits.push({ start: current.closeStart, end: current.closeEnd, text: "" })
      } else {
        edits.push({ start: current.openStart, end: current.openEnd, text: spanTag(remaining) })
      }
      continue
    }
    // A boundary that falls inside nested markup cannot be split without
    // breaking nesting; refuse rather than emit malformed note text.
    if (marked.slice(current.openEnd, current.closeStart).indexOf("<") >= 0) {
      return fail("Cannot apply formatting across a tag")
    }
    var before = current.openEnd < left
    var after = right + 1 < current.closeStart
    if (before) {
      edits.push({ start: left, end: left, text: "</span>" })
    } else {
      edits.push({ start: current.openStart, end: current.openEnd, text: "" })
    }
    if (after) {
      edits.push({ start: right + 1, end: right + 1, text: current.tag })
    } else {
      edits.push({ start: current.closeStart, end: current.closeEnd, text: "" })
    }
  }
  var next = applyEdits(marked, edits)
  if (value !== "") next = insertWrapped(next, open, "</span>")
  var result = extractSelection(next)
  return finishSpan(oldText, result.text, result.selectionStart, result.selectionEnd)
}

// --------------------------------------------------------------------- link

function escapeLabel(value) {
  return textOf(value).replace(/\\/g, "\\\\").replace(/\[/g, "\\[").replace(/\]/g, "\\]")
}

// Find the link that owns a caret or selection. The destination may contain
// balanced parentheses (valid Markdown, common in wiki URLs), so it is scanned
// with a depth counter rather than stopping at the first `)`.
function linkAt(text, start, end) {
  var source = String(text || "")
  var index = 0
  while (index < source.length) {
    var open = source.indexOf("[", index)
    if (open < 0) return null
    index = open + 1
    if (open > 0 && source.charAt(open - 1) === "\\") continue
    var labelEnd = open + 1
    var closedLabel = false
    while (labelEnd < source.length) {
      var labelChar = source.charAt(labelEnd)
      if (labelChar === "\\") { labelEnd += 2; continue }
      if (labelChar === "\n") break
      if (labelChar === "]") { closedLabel = true; break }
      labelEnd += 1
    }
    if (!closedLabel || source.charAt(labelEnd + 1) !== "(") continue
    var urlStart = labelEnd + 2
    var depth = 1
    var cursor = urlStart
    var urlEnd = -1
    while (cursor < source.length) {
      var urlChar = source.charAt(cursor)
      if (urlChar === "\\") { cursor += 2; continue }
      if (urlChar === "\n") break
      if (urlChar === "(") depth += 1
      else if (urlChar === ")") {
        depth -= 1
        if (depth === 0) { urlEnd = cursor; break }
      }
      cursor += 1
    }
    if (urlEnd < 0) continue
    var closeEnd = urlEnd + 1
    var labelStart = open + 1
    var inside = start >= labelStart && end <= labelEnd
    // A caret or selection in the destination belongs to the same link. It is
    // still the link, so editing the URL must replace it rather than nest a
    // second link inside the old destination.
    var inUrl = start >= urlStart && end <= urlEnd
    var exact = start === open && end === closeEnd
    if (inside || inUrl || exact) {
      return {
        open: open, closeEnd: closeEnd,
        labelStart: labelStart, labelEnd: labelEnd,
        urlStart: urlStart, urlEnd: urlEnd,
        url: source.slice(urlStart, urlEnd)
      }
    }
    index = closeEnd
  }
  return null
}

function currentLinkURL(text, start, end) {
  var link = linkAt(text, start, end)
  return link ? link.url : ""
}

function planLink(oldText, start, end, url) {
  var target = textOf(url).trim()
  if (target === "") return fail("Enter a link URL")
  var link = linkAt(oldText, start, end)
  if (link) {
    var updated = oldText.slice(0, link.urlStart) + target + oldText.slice(link.urlEnd)
    return finish(oldText, updated, link.labelStart, link.labelEnd)
  }
  var label = start === end ? "Link" : oldText.slice(start, end)
  var safeLabel = escapeLabel(label)
  var insertion = "[" + safeLabel + "](" + target + ")"
  var next = oldText.slice(0, start) + insertion + oldText.slice(end)
  var labelStart = start + 1
  return finish(oldText, next, labelStart, labelStart + safeLabel.length)
}

// Insert a pre-formatted date/time. The caller owns the clock: keeping the
// value as an argument makes these actions pure and node-testable.
function planDate(oldText, start, end, value) {
  var day = textOf(value).trim()
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return fail("Invalid date")
  var next = oldText.slice(0, start) + day + oldText.slice(end)
  var caret = start + day.length
  return finish(oldText, next, caret, caret)
}

function planTime(oldText, start, end, value) {
  var clock = textOf(value).trim()
  if (!/^\d{2}:\d{2}$/.test(clock)) return fail("Invalid time")
  var next = oldText.slice(0, start) + clock + oldText.slice(end)
  var caret = start + clock.length
  return finish(oldText, next, caret, caret)
}

// Insert one emoji glyph at the caret, replacing the selection. The glyph is
// plain text: markup characters are rejected so a picker entry can never
// inject a tag or a link. Multi-code-point sequences (ZWJ, variation
// selectors, skin tones) are ordinary characters and stay intact.
function planEmoji(oldText, start, end, value) {
  var glyph = textOf(value).trim()
  if (glyph === "") return fail("Choose an emoji")
  if (/[\r\n]/.test(glyph)) return fail("Emoji cannot contain a line break")
  if (/[<>\[\]`]/.test(glyph)) return fail("Emoji contains invalid characters")
  var next = oldText.slice(0, start) + glyph + oldText.slice(end)
  var caret = start + glyph.length
  return finish(oldText, next, caret, caret)
}

// Insert a wiki-style note link and leave the title selected so typing
// replaces it. A non-empty selection is used as the title.
function planNoteLink(oldText, start, end, value) {
  var selected = start < end ? oldText.slice(start, end) : ""
  var title = selected !== "" ? selected : textOf(value)
  // One line only: a note title cannot contain a line break.
  title = title.replace(/[\r\n]+/g, " ").trim()
  if (title === "") return fail("Enter a note title")
  if (title.indexOf("]]") >= 0) return fail("Note title cannot contain ]]")
  var insertion = "[[" + title + "]]"
  var next = oldText.slice(0, start) + insertion + oldText.slice(end)
  var titleStart = start + 2
  return finish(oldText, next, titleStart, titleStart + title.length)
}

// --------------------------------------------------------- blocks and tables

function ensureBlankPrefix(text, position) {
  if (position === 0) return ""
  if (text.charAt(position - 1) !== "\n") return "\n\n"
  var before = text.slice(0, position - 1)
  var previousStart = before.lastIndexOf("\n") + 1
  if (before.slice(previousStart).trim() !== "") return "\n"
  return ""
}

function ensureBlankSuffix(text, position) {
  if (position >= text.length) return ""
  if (text.charAt(position) === "\n") {
    var rest = text.slice(position + 1, lineEndAt(text, position + 1))
    return rest.trim() === "" ? "" : "\n"
  }
  return "\n\n"
}

function planCodeBlock(oldText, start, end) {
  var prefix = ensureBlankPrefix(oldText, start)
  var suffix = ensureBlankSuffix(oldText, end)
  var inner = oldText.slice(start, end)
  var head = "```\n"
  var tail = "\n```"
  var insertion = prefix + head + inner + tail + suffix
  var next = oldText.slice(0, start) + insertion + oldText.slice(end)
  var contentStart = start + prefix.length + head.length
  return finish(oldText, next, contentStart, contentStart + inner.length)
}

function planHorizontalRule(oldText, start, end) {
  var prefix = ensureBlankPrefix(oldText, start)
  var suffix = ensureBlankSuffix(oldText, end)
  var insertion = prefix + "---" + (suffix === "" ? "\n" : suffix)
  var next = oldText.slice(0, start) + insertion + oldText.slice(end)
  var caret = start + prefix.length + 3
  return finish(oldText, next, caret, caret)
}

function planTable(oldText, start, end, value) {
  var rows = clamp(Math.floor(Number(value && value.rows) || 1), 1, 8)
  var columns = clamp(Math.floor(Number(value && value.columns) || 1), 1, 8)
  var header = "|"
  var divider = "|"
  for (var c = 0; c < columns; c++) {
    header += "  |"
    divider += " --- |"
  }
  var body = []
  for (var r = 0; r < rows; r++) {
    var row = "|"
    for (var j = 0; j < columns; j++) row += "  |"
    body.push(row)
  }
  var table = [header, divider].concat(body).join("\n")
  var prefix = ensureBlankPrefix(oldText, start)
  var suffix = ensureBlankSuffix(oldText, end)
  var insertion = prefix + table + (suffix === "" ? "\n" : suffix)
  var next = oldText.slice(0, start) + insertion + oldText.slice(end)
  var caret = start + prefix.length + 2
  return finish(oldText, next, caret, caret)
}

// --------------------------------------------------------- clear formatting

var CLEAR_WRAPPERS = [
  { open: "**", close: "**" },
  { open: "__", close: "__" },
  { open: "~~", close: "~~" },
  { open: "`", close: "`" },
  { open: "*", close: "*" },
  { open: "_", close: "_" },
  { open: "<u>", close: "</u>" },
  { open: "==", close: "==" },
  { open: "<sup>", close: "</sup>" },
  { open: "<sub>", close: "</sub>" }
]

function stripInlineMarkers(value) {
  var escapes = []
  var text = String(value).replace(/\\([\\`*_{}\[\]()#+.!~<>-])/g, function(match) {
    var marker = "\uE300" + escapes.length + "\uE301"
    escapes.push(match)
    return marker
  })
  // Code spans are literal: their contents must survive the stripping pass
  // untouched, so park them behind placeholders (the backticks are dropped,
  // the characters inside are not).
  var codes = []
  text = text.replace(/`([^`\n]+)`/g, function(match, inner) {
    var marker = "\uE310" + codes.length + "\uE311"
    codes.push(inner)
    return marker
  })
  var previous = null
  while (text !== previous) {
    previous = text
    text = text.replace(/<span\s+style="[^"]*">([\s\S]*?)<\/span>/gi, "$1")
    text = text.replace(/<u>([\s\S]*?)<\/u>/gi, "$1")
    text = text.replace(/<sup>([\s\S]*?)<\/sup>/gi, "$1")
    text = text.replace(/<sub>([\s\S]*?)<\/sub>/gi, "$1")
    text = text.replace(/==(?![\s=])([^=\n]*?[^\s=])==/g, "$1")
    text = text.replace(/\*\*\*([^*]+)\*\*\*/g, "$1")
    text = text.replace(/___([^_]+)___/g, "$1")
    text = text.replace(/\*\*(?![\s*])([^*]*?[^\s*])\*\*/g, "$1")
    text = text.replace(/__(?![\s_])([^_]*?[^\s_])__/g, "$1")
    text = text.replace(/~~(?![\s~])([^~]*?[^\s~])~~/g, "$1")
    text = text.replace(/\*(?![\s*])([^*\n]*?[^\s*])\*/g, "$1")
    text = text.replace(/(^|[^A-Za-z0-9_])_(?![\s_])([^_\n]*?[^\s_])_/g, "$1$2")
  }
  for (var c = 0; c < codes.length; c++) {
    text = text.split("\uE310" + c + "\uE311").join(codes[c])
  }
  for (var i = 0; i < escapes.length; i++) {
    text = text.split("\uE300" + i + "\uE301").join(escapes[i])
  }
  return text
}

function planClear(oldText, start, end) {
  var marked = markSelection(oldText, start, end)
  var changed = true
  // Pull in markers/spans that immediately surround the selection so a
  // selection inside **bold** or a colour span is fully cleared.
  while (changed) {
    changed = false
    var left = marked.indexOf(SEL_OPEN)
    var right = marked.indexOf(SEL_CLOSE)
    for (var i = 0; i < CLEAR_WRAPPERS.length; i++) {
      var wrapper = CLEAR_WRAPPERS[i]
      if (left >= wrapper.open.length && right + wrapper.close.length <= marked.length
        && marked.slice(left - wrapper.open.length, left) === wrapper.open
        && marked.slice(right + 1, right + 1 + wrapper.close.length) === wrapper.close) {
        marked = marked.slice(0, left - wrapper.open.length) + marked.slice(left, right + 1)
          + marked.slice(right + 1 + wrapper.close.length)
        changed = true
        break
      }
    }
  }
  var spans = collectSpans(marked)
  var l = marked.indexOf(SEL_OPEN)
  var r = marked.indexOf(SEL_CLOSE)
  var remove = []
  for (var s = 0; s < spans.length; s++) {
    if (spans[s].openStart < r && spans[s].closeEnd > l) remove.push(spans[s])
  }
  remove.sort(function(a, b) { return b.openStart - a.openStart })
  for (var k = 0; k < remove.length; k++) {
    var current = collectSpans(marked)
    for (var c = 0; c < current.length; c++) {
      if (current[c].openStart === remove[k].openStart && current[c].closeEnd === remove[k].closeEnd) {
        // The selection boundary can fall inside a tag (for example 15
        // characters into a colour span). Removing that tag would take the
        // sentinel with it, and the empty marker would leak into the note as
        // an invisible U+E100. Refuse instead of corrupting the document.
        var openPart = marked.slice(current[c].openStart, current[c].openEnd)
        var closePart = marked.slice(current[c].closeStart, current[c].closeEnd)
        if (openPart.indexOf(SEL_OPEN) >= 0 || openPart.indexOf(SEL_CLOSE) >= 0
          || closePart.indexOf(SEL_OPEN) >= 0 || closePart.indexOf(SEL_CLOSE) >= 0) {
          return fail("Select within the formatted text")
        }
        marked = marked.slice(0, current[c].openStart) + marked.slice(current[c].openEnd, current[c].closeStart)
          + marked.slice(current[c].closeEnd)
        break
      }
    }
  }
  l = marked.indexOf(SEL_OPEN)
  r = marked.indexOf(SEL_CLOSE)
  if (l < 0 || r < 0 || r <= l) return fail("Select within the formatted text")
  var inner = marked.slice(l + 1, r)
  var cleaned = stripInlineMarkers(inner)
  var nextMarked = marked.slice(0, l + 1) + cleaned + marked.slice(r)
  if (nextMarked.indexOf(SEL_OPEN) < 0 || nextMarked.indexOf(SEL_CLOSE) < 0) {
    return fail("Select within the formatted text")
  }
  var result = extractSelection(nextMarked)
  if (result.text.indexOf(SEL_OPEN) >= 0 || result.text.indexOf(SEL_CLOSE) >= 0) {
    return fail("Select within the formatted text")
  }
  return finishSpan(oldText, result.text, result.selectionStart, result.selectionEnd)
}

// --------------------------------------------------------------------- plan

function plan(text, start, end, action, value) {
  var source = textOf(text)
  var selection = normaliseSelection(source, start, end)
  var s = selection.start
  var e = selection.end
  var name = String(action || "")

  // Inline actions can be handed selections that end inside a tag (for
  // example one character into "</span>"). Block actions and clear/undo keep
  // their whole-line behaviour and are not clamped.
  var inlineAction = name === "bold" || name === "italic" || name === "underline"
    || name === "strike" || name === "code" || name === "highlight"
    || name === "superscript" || name === "subscript" || name === "color"
    || name === "noColour" || name === "noColor" || name === "size"
    || name === "noSize" || name === "highlightColor" || name === "noHighlightColor"
    || name === "link" || name === "date"
    || name === "time" || name === "noteLink" || name === "emoji"
  if (inlineAction) {
    var safe = clampOutsideTags(source, s, e)
    s = safe.start
    e = safe.end
  }

  if (INLINE_MARKS[name]) return planInline(source, INLINE_MARKS[name], s, e, name)

  if (name === "color") {
    var colour = normaliseColour(value)
    if (colour === null) return fail("Enter a colour like #e06c75 or rgb(224, 62, 45)")
    return planSpan(source, s, e, "color", colour)
  }
  if (name === "noColour" || name === "noColor") return planSpan(source, s, e, "color", "")
  if (name === "highlightColor") {
    var background = normaliseColour(value)
    if (background === null) return fail("Enter a colour like #e06c75 or rgb(224, 62, 45)")
    return planSpan(source, s, e, "background-color", background)
  }
  if (name === "noHighlightColor") return planSpan(source, s, e, "background-color", "")
  if (name === "size") {
    var size = String(value || "")
    if (size === "normal" || size === "") return planSpan(source, s, e, "font-size", "")
    var sizes = { small: "10px", large: "18px", xlarge: "22px" }
    if (!sizes[size]) return fail("Unknown text size")
    return planSpan(source, s, e, "font-size", sizes[size])
  }
  if (name === "noSize") return planSpan(source, s, e, "font-size", "")

  if (name === "bullet") return planList(source, s, e, "bullet")
  if (name === "number") return planList(source, s, e, "number")
  if (name === "task") return planList(source, s, e, "task")
  if (name === "quote") return planList(source, s, e, "quote")
  if (name === "heading") {
    // 0 = normal paragraph (remove any heading prefix), 1..6 = ATX headings.
    // A missing value keeps the historical H1 default.
    var requested = value === undefined || value === null || value === "" ? 1 : Number(value)
    var level = isFinite(requested) ? clamp(Math.floor(requested), 0, 6) : 1
    return planHeading(source, s, e, level)
  }
  if (name === "link") return planLink(source, s, e, value)
  if (name === "date") return planDate(source, s, e, value)
  if (name === "time") return planTime(source, s, e, value)
  if (name === "noteLink") return planNoteLink(source, s, e, value)
  if (name === "emoji") return planEmoji(source, s, e, value)
  if (name === "codeblock") return planCodeBlock(source, s, e)
  if (name === "hr") return planHorizontalRule(source, s, e)
  if (name === "table") return planTable(source, s, e, value)
  if (name === "clear") return planClear(source, s, e)

  return fail("Unknown formatting action: " + name)
}
