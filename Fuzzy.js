// Fuzzy subsequence matching for the quick switcher.
//
// Plain ES5 with no Qt imports, so the popup and the node tests share one
// scorer. The switcher cares about intent, not spelling: "qp" should find
// "Quick Preview", and a match on word starts should beat one buried in the
// middle of a word. Everything here is read-only and case-insensitive.
//
// score() returns -1 for no match, otherwise a number where higher is better.
// rank() keeps the caller's array intact and falls back to original order for
// ties, so an unchanged query never reshuffles the list.

function fuzzyText(value) {
  return value === null || value === undefined ? "" : String(value)
}

function fuzzyLower(value) {
  return fuzzyText(value).toLowerCase()
}

// Characters that end a word in a title or folder path. A match right after
// one of these (or at the very start) earns a word-start bonus.
function fuzzySeparator(character) {
  return character === "/" || character === "-" || character === "_" ||
    character === " " || character === "."
}

function fuzzyBoundary(text, index) {
  if (index === 0) return true
  return fuzzySeparator(text.charAt(index - 1))
}

// Find the next occurrence of one query character. A contiguous match wins
// outright; otherwise prefer a later word-start occurrence over an earlier
// one inside a word ("qp" should take the "P" of "Preview", not the "p" of
// "Quadruple"). Falls back to the earliest occurrence when neither applies.
function fuzzyNextMatch(text, character, from, previous, preferBoundaries) {
  var at = text.indexOf(character, from)
  if (at < 0) return -1
  if (!preferBoundaries) return at
  if (previous >= 0 && at === previous + 1) return at
  if (fuzzyBoundary(text, at)) return at
  var scan = at
  while ((scan = text.indexOf(character, scan + 1)) >= 0) {
    if (fuzzyBoundary(text, scan)) return scan
  }
  return at
}

// Walk the needle over the haystack once. Boundary preference is a heuristic
// and can rarely paint itself into a corner, so score() retries the whole
// walk greedily before declaring no match.
function fuzzyScan(needle, haystack, preferBoundaries) {
  var total = 0
  var cursor = 0
  var previous = -1
  var first = -1

  for (var i = 0; i < needle.length; i++) {
    var at = fuzzyNextMatch(haystack, needle.charAt(i), cursor, previous, preferBoundaries)
    if (at < 0) return -1
    total += 1
    if (fuzzyBoundary(haystack, at)) total += 6
    if (previous >= 0) {
      if (at === previous + 1) total += 8
      else total -= Math.min(4, (at - previous - 1) * 0.25)
    }
    if (first < 0) first = at
    previous = at
    cursor = at + 1
  }

  total -= first * 0.4
  total -= haystack.length * 0.05
  // Keep every real match non-negative so -1 always means "no match".
  return Math.max(0, total)
}

// Score one query against one haystack. Base points per matched character,
// plus bonuses for word starts and contiguous runs, minus a small penalty for
// gaps and for a late first match or a long haystack. A long title should not
// outrank a short, precise one just because it contains more characters.
function score(query, text) {
  var needle = fuzzyLower(query)
  if (needle === "") return 0
  var haystack = fuzzyLower(text)
  if (haystack === "") return -1

  var value = fuzzyScan(needle, haystack, true)
  if (value >= 0) return value
  return fuzzyScan(needle, haystack, false)
}

// Rank a copy of `entries` best-first. `textFor` maps an entry to its
// searchable text; a plain array of strings works when it is omitted.
function rank(entries, query, textFor) {
  var source = entries && typeof entries.length === "number" ? entries : []
  var output = []
  for (var i = 0; i < source.length; i++) output.push(source[i])
  if (fuzzyText(query).trim() === "") return output

  var scored = []
  for (var j = 0; j < output.length; j++) {
    var entry = output[j]
    var text = typeof textFor === "function" ? textFor(entry) : entry
    var value = score(query, text)
    if (value >= 0) scored.push({ entry: entry, score: value, index: j })
  }
  scored.sort(function(left, right) {
    if (left.score !== right.score) return right.score - left.score
    return left.index - right.index
  })

  var ranked = []
  for (var k = 0; k < scored.length; k++) ranked.push(scored[k].entry)
  return ranked
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { score: score, rank: rank }
}
