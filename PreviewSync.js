.pragma library

// Linked scrolling between the editor and the preview.
//
// The preview is a column of blocks and each one records the source lines it
// renders, so block edges anchor source lines to pixel offsets. Between two
// anchors a line is interpolated: exact at block edges, and close enough
// inside a block because both panes wrap the same text at similar widths.

// Anchors are { line, endLine, y, height } in document order, with `line` and
// `endLine` inclusive source lines and `y`/`height` the block's content pixels.

function usable(anchor) {
  return !!anchor && isFinite(anchor.line) && anchor.line >= 0
    && isFinite(anchor.endLine) && anchor.endLine >= anchor.line
    && isFinite(anchor.y) && isFinite(anchor.height) && anchor.height > 0
}

// The source line shown at pixel `y`.
function lineForY(anchors, y) {
  var list = anchors || []
  var value = Number(y) || 0
  var found = null
  var first = null
  for (var i = 0; i < list.length; i++) {
    if (!usable(list[i])) continue
    if (!first) first = list[i]
    if (value >= list[i].y) found = list[i]
    else break
  }
  if (!found) return first ? first.line : 0
  var span = found.endLine - found.line + 1
  var fraction = Math.max(0, Math.min(1, (value - found.y) / found.height))
  return Math.max(found.line, Math.min(found.endLine,
    found.line + Math.floor(fraction * span)))
}

// The pixel offset where `line` starts.
function yForLine(anchors, line) {
  var list = anchors || []
  var value = Number(line) || 0
  var found = null
  var first = null
  for (var i = 0; i < list.length; i++) {
    if (!usable(list[i])) continue
    if (!first) first = list[i]
    if (value > list[i].endLine) {
      found = list[i]
      continue
    }
    if (value >= list[i].line) found = list[i]
    break
  }
  if (!found) return first ? first.y : 0
  var span = found.endLine - found.line + 1
  var fraction = Math.max(0, Math.min(1, (value - found.line) / span))
  return found.y + fraction * found.height
}
