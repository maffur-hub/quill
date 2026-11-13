// Tag hierarchy for the library sidebar.
//
// Plain ES5 with no Qt imports, so the sidebar and the node tests share one
// builder. The store reports tags as flat paths ("work/projects/quill"), but
// the sidebar shows them as a tree: each path segment is a node, a node that
// is also a real tag stays selectable, and a node that exists only because a
// deeper tag was written is a pure parent.
//
// build() returns a flat depth-first list so a Repeater can render it without
// nested models:
//
//   {path, label, depth, count, direct, isLeaf}
//
//   path    full joined prefix ("work/projects")
//   label   last segment ("projects")
//   depth   number of segments minus one (0 for a root)
//   count   direct notes plus every descendant's direct count
//   direct  notes carrying exactly this tag (0 for a pure parent)
//   isLeaf  direct > 0, meaning the node is a real tag that can be renamed
//           or deleted; pure parents are selection-only
//
// Parents always come before their children and siblings are ordered
// case-insensitively; equal labels keep their input order.

function tagText(value) {
  return String(value === undefined || value === null ? "" : value)
}

// Accept both {tag, count} entries (the store's shape) and plain strings.
// A bare string is one occurrence; an object without a count is one too.
function entryTag(entry) {
  if (entry !== null && typeof entry === "object") return tagText(entry.tag)
  return tagText(entry)
}

function entryCount(entry) {
  if (entry === null || typeof entry !== "object") return 1
  if (entry.count === undefined || entry.count === null) return 1
  var count = Number(entry.count)
  if (!isFinite(count) || count <= 0) return 0
  return Math.floor(count)
}

function segments(tag) {
  var parts = tagText(tag).split("/")
  var output = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] !== "") output.push(parts[i])
  }
  return output
}

function compareNodes(left, right) {
  var a = left.label.toLowerCase()
  var b = right.label.toLowerCase()
  if (a < b) return -1
  if (a > b) return 1
  return left.sequence - right.sequence
}

function sortTree(nodes) {
  nodes.sort(compareNodes)
  for (var i = 0; i < nodes.length; i++) sortTree(nodes[i].children)
}

function sumTree(node) {
  var total = node.direct
  for (var i = 0; i < node.children.length; i++) total += sumTree(node.children[i])
  node.count = total
  return total
}

function flatten(nodes, output) {
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    output.push({
      path: node.path,
      label: node.label,
      depth: node.depth,
      count: node.count,
      direct: node.direct,
      isLeaf: node.direct > 0
    })
    flatten(node.children, output)
  }
}

function build(tags) {
  var input = tags && typeof tags.length === "number" ? tags : []
  var roots = []
  // A null-prototype map so tag names such as "constructor" or "__proto__"
  // are ordinary paths rather than inherited object properties.
  var byPath = Object.create(null)
  var sequence = 0

  for (var i = 0; i < input.length; i++) {
    var entry = input[i]
    var parts = segments(entryTag(entry))
    if (parts.length === 0) continue
    var count = entryCount(entry)
    var children = roots
    var path = ""
    for (var depth = 0; depth < parts.length; depth++) {
      path = path === "" ? parts[depth] : path + "/" + parts[depth]
      var node = byPath[path]
      if (!node) {
        node = {
          path: path,
          label: parts[depth],
          depth: depth,
          direct: 0,
          count: 0,
          children: [],
          sequence: sequence
        }
        sequence += 1
        byPath[path] = node
        children.push(node)
      }
      if (depth === parts.length - 1) node.direct += count
      children = node.children
    }
  }

  sortTree(roots)
  var output = []
  for (var r = 0; r < roots.length; r++) sumTree(roots[r])
  flatten(roots, output)
  return output
}

// A sidebar subtree prefix: exact match or a descendant of it. The comparison
// is case-sensitive on the display string, matching the tags the store emits.
function prefixMatches(tag, prefix) {
  var value = tagText(tag)
  var head = tagText(prefix)
  if (value === head) return true
  if (head === "") return false
  return value.indexOf(head + "/") === 0
}

// Total direct count of every tag in the subtree. Duplicate entries add up,
// just as they do while building the tree.
function countFor(tags, prefix) {
  var input = tags && typeof tags.length === "number" ? tags : []
  var total = 0
  for (var i = 0; i < input.length; i++) {
    if (prefixMatches(entryTag(input[i]), prefix)) total += entryCount(input[i])
  }
  return total
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    build: build,
    prefixMatches: prefixMatches,
    segments: segments,
    countFor: countFor
  }
}
