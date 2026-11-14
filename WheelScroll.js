.pragma library

// Wheel scrolling for the note editor.
//
// Qt's Flickable moves a fixed number of pixels per wheel notch. In a long note
// that is either too slow (a whole note takes dozens of flicks) or, if tuned
// up, too coarse for reading. Trackpads already send pixel deltas and need none
// of this, so they pass straight through.
//
// The rest is speed-sensitive: notches that arrive close together ramp the
// step, and the factor decays when the wheel slows down, so a hard spin covers
// ground while a single deliberate roll stays precise.

var BASE = 56   // pixels per 120-unit notch at factor 1
var MAX = 16    // ceiling for the multiplier (16 x 56 px = 896 px per notch)

function create() {
  return { factor: 1, last: 0 }
}

// Returns the number of pixels to scroll for one wheel event. Positive means
// the content should move down (the caller applies it to contentY), so the sign
// follows the wheel delta exactly as Flickable would have applied it.
function step(state, angleDelta, pixelDelta, now) {
  // Trackpad or kinetic input: honour it literally, and start fresh so a later
  // wheel spin does not inherit a stale multiplier.
  if (pixelDelta) {
    state.factor = 1
    state.last = now
    return pixelDelta
  }
  if (!angleDelta) return 0

  var gap = state.last ? now - state.last : 1000
  state.last = now
  if (gap < 40) state.factor = Math.min(MAX, state.factor * 1.6)
  else if (gap < 90) state.factor = Math.min(MAX, state.factor * 1.35)
  else if (gap < 160) state.factor = Math.min(MAX, state.factor * 1.15)
  else if (gap < 350) state.factor = Math.max(1, state.factor * 0.72)
  else state.factor = 1

  return Math.round(angleDelta / 120 * BASE * state.factor)
}
