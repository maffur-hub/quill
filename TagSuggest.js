// Contextual tag suggestions for Quill.
//
// Plain ES5 with no Qt imports, so the library UI and the node tests share one
// extractor. Suggestions come from the note's own title, headings and body:
// the folder name is never consulted and the existing library vocabulary is
// only a small ranking boost for a concept that already appears in the text.
// Nothing here mutates a note; the UI decides what to apply.
//
// The output is a deterministic list of 0-5 lowercase tags, best first, scored
// by frequency with a strong title/heading boost. Adjacent-word bigrams are
// preferred when they read like a phrase ("project planning" ->
// "project-planning").

var MAX_ANALYSIS = 100000
var MAX_TAG_LENGTH = 40
var MAX_SUGGESTIONS = 5

var FENCE_RE = /^\s{0,3}(`{3,}|~{3,})/
var HEADING_RE = /^\s{0,3}#{1,6}\s+/
var LIST_MARK_RE = /^\s{0,3}(?:[-+*]|\d+[.)])\s+/

// Broad English stopword list, plus Markdown/note-taking vocabulary that would
// make useless tags ("note", "markdown", "screenshot", ...).
var STOPWORDS = {}
var STOPWORD_TEXT = (
  "a an the and or but if then than so as at by for from in into of off on onto " +
  "out over under to up with within without via per about above across after " +
  "against along among around before behind below beneath beside between beyond " +
  "during except inside near outside since through throughout toward towards " +
  "until upon while amid despite down past " +
  "i me my mine myself we us our ours ourselves you your yours yourself " +
  "yourselves he him his himself she her hers herself it its itself they them " +
  "their theirs themselves who whom whose what which that this these those " +
  "there here where when why how all any both each few more most other some " +
  "such no nor not only own same very can cannot could may might must shall " +
  "should will would am is are was were be been being have has had having do " +
  "does did doing done get gets got gotten make makes made also just even still " +
  "again ever never always often sometimes usually already yet soon later now " +
  "one two three first second next last another every either neither " +
  "because although though unless whether whereas therefore however moreover " +
  "furthermore otherwise instead rather quite too much many lot lots " +
  "it's i'm i've i'd you're you've we're we've they're they've that's there's " +
  "don't doesn't didn't isn't aren't wasn't weren't won't wouldn't can't " +
  "couldn't shouldn't haven't hasn't hadn't " +
  "note notes noting markdown quill frontmatter front-matter yaml heading " +
  "headings title titles text body content contents document documents page " +
  "pages line lines word words paragraph paragraphs section sections list " +
  "lists item items bullet bullets checkbox checkboxes todo to-do task tasks " +
  "table tables row rows column columns cell cells image images picture " +
  "pictures screenshot screenshots link links url urls code snippet snippets " +
  "block blocks quote quotes example examples sample samples untitled " +
  "http https www html css json xml png jpg jpeg gif svg pdf file files " +
  "folder folders directory read write edit editor copy paste click clicked " +
  "open opened close closed update updated add added remove removed change " +
  "changed new old use used using user users"
)
var STOPWORD_LIST = STOPWORD_TEXT.split(/\s+/)
for (var s = 0; s < STOPWORD_LIST.length; s++) {
  var word = STOPWORD_LIST[s]
  if (word) STOPWORDS[word] = true
}

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function listOf(value) {
  return Array.isArray(value) ? value : []
}

// Fold the common Latin-1/Extended-A accents to ASCII so tags stay compatible
// with the backend's ASCII tag normaliser. Other scripts are left alone and
// simply dropped by the tokeniser instead of crashing it.
var ACCENTS = {
  "à": "a", "á": "a", "â": "a", "ã": "a", "ä": "a", "å": "a", "æ": "ae",
  "ç": "c", "è": "e", "é": "e", "ê": "e", "ë": "e", "ì": "i", "í": "i",
  "î": "i", "ï": "i", "ð": "d", "ñ": "n", "ò": "o", "ó": "o", "ô": "o",
  "õ": "o", "ö": "o", "ø": "o", "œ": "oe", "š": "s", "ù": "u", "ú": "u",
  "û": "u", "ü": "u", "ý": "y", "ÿ": "y", "ž": "z", "þ": "th",
  "ß": "ss"
}

function foldAccents(value) {
  var text = textOf(value)
  var output = ""
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    var lower = ch.toLowerCase()
    var mapped = ACCENTS[lower]
    if (mapped !== undefined) {
      output += mapped
    } else if (lower !== ch) {
      // Uppercase letters without an accent entry stay as they are.
      output += ch
    } else {
      output += ch
    }
  }
  return output
}

function stripFrontmatter(value) {
  var text = textOf(value)
  if (text.slice(0, 3) !== "---") return text
  var lines = text.split("\n")
  if (!lines.length || lines[0].replace(/\s+$/, "") !== "---") return text
  for (var i = 1; i < Math.min(lines.length, 400); i++) {
    if (lines[i].replace(/\s+$/, "") === "---") {
      return lines.slice(i + 1).join("\n")
    }
  }
  // Unclosed frontmatter is not frontmatter; keep the text.
  return text
}

function stripFences(value) {
  var lines = textOf(value).split("\n")
  var output = []
  var inCode = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (FENCE_RE.test(line)) {
      inCode = !inCode
      output.push("")
      continue
    }
    output.push(inCode ? "" : line)
  }
  return output.join("\n")
}

// Remove things that must never become tags: inline code, HTML, images,
// URLs/autolinks, link destinations. Visible link labels are kept.
function stripMarkup(value) {
  var text = textOf(value)
  text = text.replace(/<!--[\s\S]*?-->/g, " ")
  text = text.replace(/<\/?[A-Za-z][^>\n]*>/g, " ")
  // Inline code, including multi-backtick spans.
  text = text.replace(/`+[^`\n]*`+/g, " ")
  // Images (alt text is metadata, not note prose).
  text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
  // Markdown links: keep the label, drop the destination.
  text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
  // Wiki links: keep the alias/target, drop the brackets and anchor.
  text = text.replace(/\[\[([^\]]+)\]\]/g, function (whole, inner) {
    var target = textOf(inner)
    var pipe = target.indexOf("|")
    var label = pipe >= 0 ? target.slice(pipe + 1) : target
    var hash = label.indexOf("#")
    if (hash >= 0) label = label.slice(0, hash)
    return " " + label + " "
  })
  // Autolinks, bare URLs, www hosts and e-mail addresses.
  text = text.replace(/<[^>\s]+@[^>\s]+>/g, " ")
  text = text.replace(/\b(?:https?|ftp):\/\/[^\s<>()\[\]{}]+/gi, " ")
  text = text.replace(/\bwww\.[^\s<>()\[\]{}]+/gi, " ")
  text = text.replace(/\b[^\s@<>]+@[^\s@<>]+\.[A-Za-z]{2,}\b/g, " ")
  // Markdown punctuation and emphasis markers.
  text = text.replace(/[#*_~>|[\]{}()\\]/g, " ")
  return text
}

function cleanToken(raw) {
  var token = textOf(raw).toLowerCase()
  // Possessives read as the plain noun.
  token = token.replace(/'s$/, "")
  token = token.replace(/^[-']+|[-']+$/g, "")
  if (token.length < 3) return ""
  if (!/[a-z]/.test(token)) return ""
  if (/^[0-9][0-9'\-]*$/.test(token)) return ""
  if (STOPWORDS[token]) return ""
  return token
}

function tokensOf(value) {
  var text = foldAccents(value)
  var found = text.match(/[A-Za-z0-9\u00c0-\u024f][A-Za-z0-9\u00c0-\u024f'\-]*/g)
  var output = []
  if (!found) return output
  for (var i = 0; i < found.length; i++) {
    var token = cleanToken(found[i])
    if (token) output.push(token)
  }
  return output
}

function normalizeTag(value) {
  var tag = foldAccents(value).toLowerCase()
  tag = tag.replace(/['’]/g, "")
  tag = tag.replace(/[\s_]+/g, "-")
  tag = tag.replace(/[^a-z0-9\-]/g, "")
  tag = tag.replace(/-+/g, "-").replace(/^-+|-+$/g, "")
  if (tag.length > MAX_TAG_LENGTH) {
    tag = tag.slice(0, MAX_TAG_LENGTH).replace(/-+$/g, "")
  }
  return tag
}

function keyOf(value) {
  return normalizeTag(value)
}

function tagList(value) {
  var list = listOf(value)
  var output = []
  for (var i = 0; i < list.length; i++) {
    output.push(list[i])
  }
  return output
}

function existingKeys(existingTags) {
  var keys = {}
  var list = tagList(existingTags)
  for (var i = 0; i < list.length; i++) {
    var key = keyOf(list[i])
    if (key) keys[key] = true
  }
  return keys
}

function knownKeys(knownTags) {
  var keys = {}
  var list = tagList(knownTags)
  for (var i = 0; i < list.length; i++) {
    var raw = list[i]
    // The library hands over {tag, count} rows; accept plain strings too.
    if (raw && typeof raw === "object") raw = raw.tag
    var key = keyOf(raw)
    if (key) keys[key] = true
  }
  return keys
}

function addCount(map, key, amount) {
  if (!key) return
  map[key] = (map[key] || 0) + amount
}

// Walk one logical line, recording unigrams and adjacent-word bigrams. The
// bigram pair is formed before stopword filtering so "project for planning"
// is not mistaken for "project-planning".
function scanLine(line, body, title, heading) {
  var words = tokensOf(line)
  for (var i = 0; i < words.length; i++) {
    if (body) addCount(body, words[i], 1)
    if (title) addCount(title, words[i], 1)
    if (heading) addCount(heading, words[i], 1)
  }
  if (words.length < 2) return
  var raw = foldAccents(line).toLowerCase().match(/[a-z0-9\u00c0-\u024f][a-z0-9\u00c0-\u024f'\-]*/g) || []
  var sequence = []
  for (var r = 0; r < raw.length; r++) {
    var token = cleanToken(raw[r])
    // Keep placeholders only to preserve adjacency; stopwords break a phrase.
    sequence.push(token)
  }
  for (var j = 0; j + 1 < sequence.length; j++) {
    var left = sequence[j]
    var right = sequence[j + 1]
    if (!left || !right) continue
    if (STOPWORDS[left] || STOPWORDS[right]) continue
    var key = left + "-" + right
    if (body) addCount(body, key, 1)
    if (title) addCount(title, key, 1)
    if (heading) addCount(heading, key, 1)
  }
}

function trimBody(value) {
  var text = textOf(value)
  return text.length > MAX_ANALYSIS ? text.slice(0, MAX_ANALYSIS) : text
}

function collect(title, content) {
  var bodyCounts = {}
  var titleCounts = {}
  var headingCounts = {}

  var titleText = stripMarkup(foldAccents(textOf(title)))
  scanLine(titleText, bodyCounts, titleCounts, 0)

  var text = stripFences(stripFrontmatter(trimBody(content)))
  var lines = text.split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (HEADING_RE.test(line)) {
      var headingText = line.replace(HEADING_RE, "")
      scanLine(stripMarkup(headingText), bodyCounts, 0, headingCounts)
      continue
    }
    line = line.replace(LIST_MARK_RE, "")
    scanLine(stripMarkup(line), bodyCounts, 0, 0)
  }
  return {
    body: bodyCounts,
    title: titleCounts,
    headings: headingCounts
  }
}

function scoreOf(counts, key, weight) {
  return (counts[key] || 0) * weight
}

function suggest(title, content, existingTags, knownTags) {
  var counts = collect(title, content)
  var excluded = existingKeys(existingTags)
  var known = knownKeys(knownTags)
  var candidates = {}

  function consider(key) {
    var tag = normalizeTag(key)
    if (!tag || excluded[tag]) return
    candidates[tag] = true
  }

  var key
  for (key in counts.body) {
    if (!Object.prototype.hasOwnProperty.call(counts.body, key)) continue
    // Bigrams need repetition, or a title/heading occurrence, before they
    // read like a phrase; a single incidental pair is not a good tag.
    if (key.indexOf("-") >= 0
        && (counts.body[key] || 0) < 2
        && !counts.title[key] && !counts.headings[key]) continue
    consider(key)
  }

  var scored = []
  for (var tag in candidates) {
    if (!Object.prototype.hasOwnProperty.call(candidates, tag)) continue
    var phrase = tag.indexOf("-") >= 0
    var bodyWeight = phrase ? 1.6 : 1
    var titleWeight = phrase ? 7 : 6
    var headingWeight = phrase ? 3 : 2.5
    var score = scoreOf(counts.body, tag, bodyWeight)
      + scoreOf(counts.title, tag, titleWeight)
      + scoreOf(counts.headings, tag, headingWeight)
    if (known[tag]) score += 2
    // Very long tails are noise, but a title word always deserves a look.
    if (score < 1) continue
    scored.push({ tag: tag, score: score })
  }

  scored.sort(function (left, right) {
    if (right.score !== left.score) return right.score - left.score
    if (left.tag < right.tag) return -1
    if (left.tag > right.tag) return 1
    return 0
  })

  var output = []
  var seen = {}
  for (var i = 0; i < scored.length && output.length < MAX_SUGGESTIONS; i++) {
    var value = scored[i].tag
    if (seen[value]) continue
    seen[value] = true
    output.push(value)
  }
  return output
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { suggest: suggest, normalizeTag: normalizeTag }
}
