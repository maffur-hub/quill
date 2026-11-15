.pragma library

// UTF-8 byte length for Quill note bodies.
//
// The store measures a note by the size of its UTF-8 encoding and refuses a
// body at or over MAX_NOTE_BYTES. JavaScript strings are UTF-16, so
// String.length counts code units rather than bytes and cannot answer that
// question: an emoji is one pair of units but four bytes, while a lone
// surrogate is one unit and three bytes once encoded. Keep this file ES5-only:
// QML loads it as old-style JavaScript, and the node tests evaluate it in a
// bare context.

// Bytes written for the code unit at `index`; a high surrogate followed by a
// low one is a pair, so the caller advances one extra unit.
function countBytes(text, stopAt) {
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var unit = text.charCodeAt(i)
    if (unit < 0x80) {
      bytes += 1
    } else if (unit < 0x800) {
      bytes += 2
    } else if (unit >= 0xD800 && unit <= 0xDFFF) {
      var next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0
      if (unit <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) {
        bytes += 4
        i += 1
      } else {
        // A lone surrogate encodes as the three-byte replacement character,
        // which is what Python writes for the same string.
        bytes += 3
      }
    } else {
      bytes += 3
    }
    if (bytes >= stopAt) return bytes
  }
  return bytes
}

function utf8Length(value) {
  if (value === null || value === undefined) return 0
  return countBytes(String(value), Infinity)
}

// True when `value` would reach the store's size limit. `limit` is compared
// with >= because the store rejects `size >= MAX_NOTE_BYTES`.
function exceeds(value, limit) {
  var max = Number(limit)
  if (!isFinite(max) || max < 0) return false
  if (value === null || value === undefined) return false
  var text = String(value)
  if (text.length === 0) return false
  return countBytes(text, max) >= max
}
