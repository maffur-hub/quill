// Syntax highlighting for fenced code in Quill's Markdown preview.
//
// Qt's Text.MarkdownText does not colour code, so the preview wraps this
// module's output in a <pre>. This is deliberately not a parser: each language
// gets 5-10 regular expressions that make the common shape of the code
// recognisable on a dark background. Ambiguous text is left plain, and an
// empty or unknown language returns escapeHtml(code) with no spans at all
// rather than guessing, because a wrong guess is more distracting than no
// colour.
//
// Output contract: the source is reproduced exactly — whitespace, tabs,
// indentation, newlines, a trailing newline and all — with only <span> wrappers
// added. collect() finds candidate matches per token class, choose() sorts by
// start offset (then priority) and greedily takes non-overlapping matches, so
// a span can never straddle another one.
//
// Plain ES5 with no Qt imports, so node tests can load it with vm.

var DEFAULT_PALETTE = {
  comment: "#6b7280",
  keyword: "#c792ea",
  string: "#a3d17a",
  number: "#e0a458",
  literal: "#e0a458",
  function: "#7aa2f7",
  type: "#7dcfff",
  tag: "#f07178",
  attribute: "#e0af68",
  punctuation: "#9aa0a6"
}

var ALIASES = {
  javascript: "javascript",
  js: "javascript",
  jsx: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  typescript: "typescript",
  ts: "typescript",
  tsx: "typescript",
  python: "python",
  py: "python",
  bash: "bash",
  sh: "bash",
  shell: "bash",
  zsh: "bash",
  console: "bash",
  json: "json",
  yaml: "yaml",
  yml: "yaml",
  html: "html",
  xml: "html",
  svg: "html",
  htm: "html",
  css: "css",
  scss: "css",
  sql: "sql",
  rust: "rust",
  rs: "rust",
  c: "c",
  h: "c",
  cpp: "c",
  "c++": "c",
  cc: "c",
  hpp: "c",
  go: "go",
  markdown: "markdown",
  md: "markdown",
  diff: "diff",
  patch: "diff"
}

var LANGUAGES = [
  "javascript", "typescript", "python", "bash", "json", "yaml", "html",
  "css", "sql", "rust", "c", "go", "markdown", "diff"
]

// Comment wins over a string that starts at the same offset, a string wins
// over a keyword-looking word inside it, and so on. Earliest start still
// dominates: a string beginning at column 0 swallows a "//" inside it.
var P = {
  comment: 100,
  key: 95,
  string: 90,
  number: 80,
  literal: 75,
  keyword: 70,
  tag: 65,
  type: 60,
  attribute: 55,
  func: 50,
  punctuation: 10
}

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function escapeHtml(value) {
  return textOf(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function has(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key)
}

function normaliseLanguage(name) {
  var key = textOf(name).trim().toLowerCase()
  if (key === "") return ""
  if (key.charAt(0) === ".") key = key.slice(1)
  return has(ALIASES, key) ? ALIASES[key] : ""
}

function languages() {
  return LANGUAGES.slice(0)
}

// The palette comes from QML, but never trust a value that lands inside a
// style attribute: anything unrecognised falls back to the dark-theme default.
function safeColour(value, fallback) {
  var colour = textOf(value).trim()
  if (/^#[0-9a-fA-F]{3}$|^#[0-9a-fA-F]{6}$|^#[0-9a-fA-F]{8}$/.test(colour)) return colour
  if (/^rgba?\(\s*[0-9]{1,3}\s*,\s*[0-9]{1,3}\s*,\s*[0-9]{1,3}\s*(?:,\s*(?:0|1|0?\.[0-9]+)\s*)?\)$/i.test(colour)) return colour
  if (/^[A-Za-z]{3,20}$/.test(colour)) return colour
  return fallback
}

// Rules use the short key "func"; the palette (and the QML caller) use the
// full word "function". Everything else is named identically.
function paletteKey(key) {
  return key === "func" ? "function" : key
}

function colourFor(palette, key) {
  var name = paletteKey(key)
  var fallback = has(DEFAULT_PALETTE, name) ? DEFAULT_PALETTE[name] : DEFAULT_PALETTE.punctuation
  if (palette && has(palette, name)) return safeColour(palette[name], fallback)
  return fallback
}

function spanFor(key, value, palette) {
  var style = "color:" + colourFor(palette, key)
  // Keywords carry the only weight change: colour alone is enough for the
  // other classes, and bold strings/comments read as noise in a preview.
  if (key === "keyword") style += "; font-weight:bold"
  return "<span style=\"" + style + "\">" + escapeHtml(value) + "</span>"
}

// Turn one rule into non-overlapping candidate matches. `group` lets a rule
// colour only part of a match (a YAML key without its indentation, say).
function collect(code, rules) {
  var tokens = []
  for (var r = 0; r < rules.length; r++) {
    var rule = rules[r]
    var flags = "g"
    if (rule.re.ignoreCase) flags += "i"
    if (rule.re.multiline) flags += "m"
    var re = new RegExp(rule.re.source, flags)
    var match
    while ((match = re.exec(code)) !== null) {
      var value = rule.group ? match[rule.group] : match[0]
      if (value === undefined || value === null || value === "") {
        re.lastIndex += 1
        continue
      }
      var at = rule.group
        ? match.index + match[0].indexOf(value)
        : match.index
      tokens.push({
        start: at,
        end: at + value.length,
        key: rule.key,
        priority: rule.priority === undefined ? P[rule.key] : rule.priority
      })
    }
  }
  return tokens
}

function choose(tokens) {
  tokens.sort(function(a, b) {
    if (a.start !== b.start) return a.start - b.start
    if (a.priority !== b.priority) return b.priority - a.priority
    return (b.end - b.start) - (a.end - a.start)
  })
  var chosen = []
  var cursor = 0
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].start < cursor) continue
    chosen.push(tokens[i])
    cursor = tokens[i].end
  }
  return chosen
}

function toHtml(code, language, palette) {
  var source = textOf(code)
  var key = normaliseLanguage(language)
  if (key === "" || !has(RULES, key)) return escapeHtml(source)

  var chosen = choose(collect(source, RULES[key]))
  if (chosen.length === 0) return escapeHtml(source)

  var html = ""
  var at = 0
  for (var i = 0; i < chosen.length; i++) {
    html += escapeHtml(source.slice(at, chosen[i].start))
    html += spanFor(chosen[i].key, source.slice(chosen[i].start, chosen[i].end), palette)
    at = chosen[i].end
  }
  html += escapeHtml(source.slice(at))
  return html
}

// --- rule helpers ---------------------------------------------------------

function wordList(source, flags) {
  return new RegExp("\\b(?:" + source + ")\\b", flags || "")
}

function words(list, flags) {
  return wordList(list.join("|"), flags)
}

var STRING_DOUBLE = /"(?:[^"\\\n]|\\[\s\S])*"/g
var STRING_SINGLE = /'(?:[^'\\\n]|\\[\s\S])*'/g
var BACKTICK = /`[^`\n]*`/g
var NUMBER = /\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b/g

// --- JavaScript / TypeScript ---------------------------------------------

var JS_KEYWORDS = [
  "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
  "return", "function", "var", "let", "const", "new", "delete", "typeof",
  "instanceof", "in", "of", "class", "extends", "super", "this", "try",
  "catch", "finally", "throw", "async", "await", "yield", "import", "export",
  "from", "default", "static", "get", "set", "void", "with", "debugger"
]

var JS_LITERALS = ["true", "false", "null", "undefined", "NaN", "Infinity"]

var TS_KEYWORDS = JS_KEYWORDS.concat([
  "interface", "type", "enum", "implements", "declare", "abstract", "readonly",
  "namespace", "module", "as", "satisfies", "keyof", "infer", "asserts", "is",
  "public", "private", "protected", "override"
])

var TS_TYPES = [
  "string", "number", "boolean", "any", "unknown", "never", "object",
  "symbol", "bigint", "void"
]

var JS_RULES = [
  { key: "comment", re: /\/\/[^\n]*/g },
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: STRING_SINGLE },
  { key: "string", re: /`[\s\S]*?(?:`|$)/g },
  { key: "number", re: NUMBER },
  { key: "literal", re: words(JS_LITERALS) },
  { key: "keyword", re: words(JS_KEYWORDS) },
  { key: "func", re: /\b[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\()/g }
]

var TS_RULES = JS_RULES.concat([
  { key: "keyword", re: words(TS_KEYWORDS) },
  { key: "type", re: words(TS_TYPES) }
])

// --- Python ---------------------------------------------------------------

var PY_KEYWORDS = [
  "and", "as", "assert", "async", "await", "break", "class", "continue",
  "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
  "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
  "raise", "return", "try", "while", "with", "yield", "match", "case"
]

var PY_TYPES = [
  "int", "float", "str", "bytes", "list", "dict", "set", "tuple", "bool",
  "object", "type", "complex", "frozenset", "Exception", "BaseException"
]

var PY_RULES = [
  { key: "comment", re: /#[^\n]*/g },
  { key: "string", re: /(?:[rRuUbBfF]{0,2})(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$))/g },
  { key: "string", re: /(?:[rRuUbBfF]{0,2})(?:"(?:[^"\\\n]|\\[\s\S])*"|'(?:[^'\\\n]|\\[\s\S])*')/g },
  { key: "number", re: NUMBER },
  { key: "literal", re: /\b(?:True|False|None)\b/g },
  { key: "keyword", re: words(PY_KEYWORDS) },
  { key: "type", re: words(PY_TYPES) },
  { key: "func", re: /\bdef[ \t]+([A-Za-z_][A-Za-z0-9_]*)/g, group: 1 },
  { key: "type", re: /\bclass[ \t]+([A-Za-z_][A-Za-z0-9_]*)/g, group: 1 },
  { key: "func", re: /^[ \t]*(@[A-Za-z_][A-Za-z0-9_.]*)/gm, group: 1 }
]

// --- Bash -----------------------------------------------------------------

var BASH_KEYWORDS = [
  "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
  "case", "esac", "function", "in", "select", "time", "return", "exit",
  "local", "export", "source", "alias", "read", "set", "unset", "shift",
  "trap", "wait", "exec", "eval", "declare", "typeset"
]

var BASH_RULES = [
  { key: "comment", re: /#[^\n]*/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'[^'\n]*'/g },
  { key: "literal", re: /\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?$!*]/g },
  { key: "number", re: /\b\d+\b/g },
  { key: "keyword", re: words(BASH_KEYWORDS) },
  { key: "func", re: /\b(?:echo|printf|read|cd|pwd|ls|cat|grep|sed|awk|cp|mv|rm|mkdir|chmod|chown|find|which|curl|wget|git|node|npm|python3?)\b/g },
  { key: "punctuation", re: /[|&;<>()]+/g }
]

// --- JSON -----------------------------------------------------------------

var JSON_RULES = [
  { key: "attribute", re: /"(?:[^"\\\n]|\\[\s\S])*"(?=\s*:)/g, priority: P.key },
  { key: "string", re: STRING_DOUBLE },
  { key: "number", re: /-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/g },
  { key: "literal", re: /\b(?:true|false|null)\b/g },
  { key: "punctuation", re: /[{}\[\],:]/g }
]

// --- YAML -----------------------------------------------------------------

var YAML_RULES = [
  { key: "comment", re: /#[^\n]*/g },
  { key: "attribute", re: /(^|[\n\r])[ \t-]*([A-Za-z_$][\w.$-]*)(?=\s*:)/g, group: 2, priority: P.key },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'[^'\n]*'/g },
  { key: "number", re: /\b\d+(?:\.\d+)?\b/g },
  { key: "literal", re: /\b(?:true|false|null|yes|no|on|off|True|False|Null|YES|NO|ON|OFF)\b/g },
  { key: "punctuation", re: /^[ \t]*(?:---|\.\.\.)[ \t]*$/gm },
  { key: "punctuation", re: /^[ \t]*-[ \t]/gm }
]

// --- HTML -----------------------------------------------------------------

var HTML_RULES = [
  { key: "comment", re: /<!--[\s\S]*?(?:-->|$)/g },
  { key: "tag", re: /<!DOCTYPE[^>]*>/gi },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'[^'\n]*'/g },
  { key: "literal", re: /&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9a-fA-F]+);/g },
  { key: "tag", re: /<\/?[A-Za-z][A-Za-z0-9:-]*/g },
  { key: "attribute", re: /[A-Za-z_:][A-Za-z0-9_:.-]*(?=\s*=)/g }
]

// --- CSS ------------------------------------------------------------------

var CSS_RULES = [
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'[^'\n]*'/g },
  { key: "literal", re: /#[0-9a-fA-F]{3,8}\b/g },
  { key: "number", re: /\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr|pt)?\b/g },
  { key: "keyword", re: /@[A-Za-z-]+/g },
  { key: "attribute", re: /[-A-Za-z]+(?=\s*:)/g },
  { key: "tag", re: /[.#][A-Za-z_-][A-Za-z0-9_-]*/g },
  { key: "punctuation", re: /[{};:]/g }
]

// --- SQL ------------------------------------------------------------------

var SQL_KEYWORDS = [
  "select", "from", "where", "and", "or", "not", "insert", "into", "values",
  "update", "set", "delete", "create", "table", "alter", "drop", "index",
  "view", "join", "left", "right", "inner", "outer", "full", "cross", "on",
  "as", "group", "by", "order", "having", "limit", "offset", "union", "all",
  "distinct", "case", "when", "then", "else", "end", "null", "is", "in",
  "like", "between", "exists", "primary", "key", "foreign", "references",
  "default", "constraint", "unique", "check", "asc", "desc", "with", "returning"
]

var SQL_TYPES = [
  "int", "integer", "smallint", "bigint", "text", "varchar", "char", "boolean",
  "bool", "date", "time", "timestamp", "numeric", "decimal", "real", "double",
  "serial", "uuid", "json", "jsonb", "blob"
]

var SQL_RULES = [
  { key: "comment", re: /--[^\n]*/g },
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: /'(?:[^']|'')*'/g },
  { key: "attribute", re: /"(?:[^"]|"")*"/g },
  { key: "number", re: /\b\d+(?:\.\d+)?\b/g },
  { key: "keyword", re: words(SQL_KEYWORDS, "i") },
  { key: "type", re: words(SQL_TYPES, "i") },
  { key: "func", re: /\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/g },
  { key: "punctuation", re: /[;,()]/g }
]

// --- Rust -----------------------------------------------------------------

var RUST_KEYWORDS = [
  "as", "async", "await", "break", "const", "continue", "crate", "dyn",
  "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
  "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
  "static", "struct", "super", "trait", "type", "unsafe", "use", "where",
  "while", "yield"
]

var RUST_RULES = [
  { key: "comment", re: /\/\/[^\n]*/g },
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: /r#*"[\s\S]*?"#*/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'(?:[^'\\\n]|\\[\s\S])'/g },
  { key: "number", re: NUMBER },
  { key: "literal", re: /\b(?:true|false)\b/g },
  { key: "keyword", re: words(RUST_KEYWORDS) },
  { key: "type", re: /\b(?:i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|bool|char|str|String)\b/g },
  { key: "type", re: /\b[A-Z][A-Za-z0-9_]*\b/g },
  { key: "func", re: /\b[a-z_][a-z0-9_]*!/g }
]

// --- C / C++ --------------------------------------------------------------

var C_KEYWORDS = [
  "auto", "break", "case", "const", "continue", "default", "do", "else",
  "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
  "return", "sizeof", "static", "struct", "switch", "typedef", "union",
  "volatile", "while", "class", "namespace", "template", "typename", "using",
  "public", "private", "protected", "virtual", "override", "new", "delete",
  "nullptr", "this"
]

var C_TYPES = [
  "void", "char", "short", "int", "long", "float", "double", "signed",
  "unsigned", "bool", "size_t", "ssize_t", "int8_t", "int16_t", "int32_t",
  "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "uintptr_t"
]

var C_RULES = [
  { key: "keyword", re: /^[ \t]*#[ \t]*[A-Za-z]+/gm },
  { key: "comment", re: /\/\/[^\n]*/g },
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'(?:[^'\\\n]|\\[\s\S])'/g },
  { key: "number", re: NUMBER },
  { key: "literal", re: /\b(?:true|false|NULL)\b/g },
  { key: "keyword", re: words(C_KEYWORDS) },
  { key: "type", re: words(C_TYPES) },
  { key: "func", re: /\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/g }
]

// --- Go -------------------------------------------------------------------

var GO_KEYWORDS = [
  "break", "case", "chan", "const", "continue", "default", "defer", "else",
  "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
  "map", "package", "range", "return", "select", "struct", "switch", "type",
  "var"
]

var GO_TYPES = [
  "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
  "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8",
  "uint16", "uint32", "uint64", "uintptr", "any"
]

var GO_RULES = [
  { key: "comment", re: /\/\/[^\n]*/g },
  { key: "comment", re: /\/\*[\s\S]*?(?:\*\/|$)/g },
  { key: "string", re: /`[^`]*`/g },
  { key: "string", re: STRING_DOUBLE },
  { key: "string", re: /'(?:[^'\\\n]|\\[\s\S])'/g },
  { key: "number", re: NUMBER },
  { key: "literal", re: /\b(?:true|false|nil|iota)\b/g },
  { key: "keyword", re: words(GO_KEYWORDS) },
  { key: "type", re: words(GO_TYPES) },
  { key: "func", re: /\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/g }
]

// --- Markdown -------------------------------------------------------------

var MARKDOWN_RULES = [
  { key: "keyword", re: /^[ \t]{0,3}#{1,6}(?:[ \t][^\n]*)?$/gm },
  { key: "keyword", re: /\*\*[^*\n]+\*\*/g },
  { key: "string", re: /`[^`\n]+`/g },
  { key: "attribute", re: /!?\[[^\]\n]*\]\([^)\n]*\)/g },
  { key: "punctuation", re: /^[ \t]{0,3}(?:[-*+]|\d+[.)])(?=[ \t])/gm },
  { key: "punctuation", re: /^[ \t]{0,3}>/gm }
]

// --- Diff -----------------------------------------------------------------

var DIFF_RULES = [
  { key: "comment", re: /^(?:diff |index |--- |\+\+\+ )[^\n]*/gm },
  { key: "keyword", re: /^@@[^\n]*/gm },
  { key: "string", re: /^\+[^\n]*/gm },
  { key: "tag", re: /^-[^\n]*/gm }
]

var RULES = {
  javascript: JS_RULES,
  typescript: TS_RULES,
  python: PY_RULES,
  bash: BASH_RULES,
  json: JSON_RULES,
  yaml: YAML_RULES,
  html: HTML_RULES,
  css: CSS_RULES,
  sql: SQL_RULES,
  rust: RUST_RULES,
  c: C_RULES,
  go: GO_RULES,
  markdown: MARKDOWN_RULES,
  diff: DIFF_RULES
}
