.pragma library

// Pure helpers shared by Library.qml and Detached.qml.
//
// A harness may instantiate the real library against a disposable data root,
// but it must never write to the user's live root. Production entry points opt
// in explicitly (Panel.qml permits it only when QUILL_E2E is not set;
// scripts/quill-window exports QUILL_ALLOW_REAL_DATA for Detached.qml, which
// also refuses when QUILL_E2E=1). Keep this file ES5-only: QML loads it as
// old-style JavaScript.

function stringValue(value) {
  if (value === null || value === undefined) return ""
  return String(value)
}

// Expand ~, decode file:// URLs, collapse repeated slashes, remove trailing
// slashes and resolve "." / ".." lexically (without touching the filesystem).
function normalizePath(value, home) {
  var raw = stringValue(value).trim()
  if (!raw) return ""
  if (raw.slice(0, 7) === "file://") {
    raw = raw.slice(7)
    if (raw.slice(0, 10) === "localhost/") raw = "/" + raw.slice(10)
    try { raw = decodeURIComponent(raw) } catch (error) { /* keep raw */ }
  }
  var base = stringValue(home).trim().replace(/\\/g, "/").replace(/\/+$/, "")
  if (raw === "~") raw = base
  else if (raw.slice(0, 2) === "~/") raw = base + raw.slice(1)
  raw = raw.replace(/\\/g, "/")

  var absolute = raw.charAt(0) === "/"
  var parts = raw.split("/")
  var output = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (!part || part === ".") continue
    if (part === "..") {
      if (output.length > 0 && output[output.length - 1] !== "..") output.pop()
      else if (!absolute) output.push("..")
      continue
    }
    output.push(part)
  }
  var normalized = (absolute ? "/" : "") + output.join("/")
  if (!normalized) return absolute ? "/" : "."
  return normalized
}

function samePath(left, right, home) {
  return normalizePath(left, home) === normalizePath(right, home)
}

function realDataRoot(home) {
  var base = stringValue(home).trim().replace(/\\/g, "/").replace(/\/+$/, "")
  return normalizePath(base + "/.local/share/quill", home)
}

function isRealDataRoot(value, home) {
  var normalized = normalizePath(value, home)
  return normalized !== "" && normalized === realDataRoot(home)
}

// Empty roots are read-only by design: a caller that forgot to pass a root
// must not be treated as a clone. Only the live root needs allowRealData.
function writesAllowed(dataRoot, allowRealData, home) {
  var normalized = normalizePath(dataRoot, home)
  if (!normalized) return false
  if (isRealDataRoot(normalized, home)) return allowRealData === true
  return true
}

function refusalMessage() {
  return "Read-only: refusing to write to the real Quill data root in a test or harness window"
}

function isMutatingArgs(args) {
  if (!args || typeof args.length !== "number" || args.length === 0) return false
  var command = stringValue(args[0])
  if (command === "folder") return true
  if (command === "draft") return stringValue(args[1]) === "discard"
  if (command === "attachment") return stringValue(args[1]) !== "list"
  var mutating = {
    "write": 1,
    "create": 1,
    "rename": 1,
    "move": 1,
    "trash": 1,
    "restore": 1,
    "delete": 1,
    "empty-trash": 1,
    "pin": 1,
    "tag-rename": 1,
    "import-omanano": 1,
    "index": 1,
    "restore-version": 1
  }
  return Object.prototype.hasOwnProperty.call(mutating, command)
}
