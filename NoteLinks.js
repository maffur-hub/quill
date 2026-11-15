// Link classification for Quill windows.
//
// The store rewrites wiki links and inline tags into quill:// links, and
// Markdown files can also link to a sibling note by path. A window that opens
// such a link needs the note id, not an OS handler: `quill://note/…` passed to
// xdg-open is dead, and a relative `.md` path is resolved against the note's
// own folder. Everything else stays an external URL.
//
// Plain ES5 with no Qt imports, so the detached window and the node tests
// share one definition.

var SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:/

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function decode(value) {
  try {
    return decodeURIComponent(value)
  } catch (error) {
    return value
  }
}

// A link that names a note file, resolved to a note id relative to the notes
// root. Returns "" when the link is not a note reference (an attachment, a
// URL, an anchor, or a path that climbs out of the root).
function noteIdForLink(link, noteId, dataRoot) {
  var value = decode(textOf(link)).trim()
  if (value === "" || value.charAt(0) === "#") return ""
  if (SCHEME_RE.test(value)) return ""
  var hash = value.indexOf("#")
  if (hash >= 0) value = value.slice(0, hash)
  if (value === "") return ""
  var notesRoot = textOf(dataRoot) + "/notes/"
  var relative = ""
  if (value.indexOf(notesRoot) === 0) {
    relative = value.slice(notesRoot.length)
  } else if (value.charAt(0) === "/" || value.charAt(0) === "~") {
    return ""
  } else {
    var current = textOf(noteId)
    var folder = current.lastIndexOf("/")
    relative = (folder >= 0 ? current.slice(0, folder + 1) : "") + value
  }
  if (!/\.md$/i.test(relative)) return ""
  var segments = []
  var parts = relative.split("/")
  for (var i = 0; i < parts.length; i += 1) {
    var part = parts[i]
    if (part === "" || part === ".") continue
    if (part === "..") {
      if (segments.length === 0) return ""
      segments.pop()
      continue
    }
    segments.push(part)
  }
  return segments.length > 0 ? segments.join("/") : ""
}

// { kind, value } with kind one of:
//   "note"     value is a note id to open
//   "missing"  value is the link text that resolved to no note
//   "tag"      value is a tag name to browse
//   "anchor"   an in-page anchor, left to the renderer
//   "external" value is the original link, unchanged
//   "empty"    value is ""
function classify(link, noteId, dataRoot) {
  var value = textOf(link).trim()
  if (value === "") return { kind: "empty", value: "" }
  if (value.indexOf("quill://note/") === 0) {
    return { kind: "note", value: decode(value.slice("quill://note/".length)) }
  }
  if (value.indexOf("quill://missing/") === 0) {
    return { kind: "missing", value: decode(value.slice("quill://missing/".length)) }
  }
  if (value.indexOf("quill://tag/") === 0) {
    return { kind: "tag", value: decode(value.slice("quill://tag/".length)) }
  }
  if (value.charAt(0) === "#") return { kind: "anchor", value: value }
  var id = noteIdForLink(value, noteId, dataRoot)
  if (id !== "") return { kind: "note", value: id }
  return { kind: "external", value: value }
}
