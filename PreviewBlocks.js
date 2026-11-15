// Block splitter for Quill's Markdown preview.
//
// PreviewPane used to own this logic inline; it lives here so node tests can
// exercise the exact block shapes the QML renderer consumes. The module takes
// its dependencies explicitly (image sizing, tables, maths syntax, task
// parsing, Markdown extensions) so it has no imports at all and can be loaded
// by either QML or node:vm.
//
// Block order at each line is fixed: display maths first, then tables, then
// fenced code / definition lists / images / task lines, and finally plain
// text. The finders only report starts, so checking a more specific block
// first is what stops a pipe row or a $$ line from leaking into a
// MarkdownText paragraph.

var FENCE_RE = /^\s{0,3}(`{3,}|~{3,})/

var extrasModule = null

function textOf(value) {
  return String(value === undefined || value === null ? "" : value)
}

function stripCR(value) {
  var text = textOf(value)
  return text.charAt(text.length - 1) === "\r" ? text.slice(0, -1) : text
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key)
}

// TextEdit paints anchors with its own default blue, so link-bearing blocks
// go through the HTML converter and get the theme accent inline.
function hasMarkdownLink(value) {
  var text = textOf(value)
  return /\[[^\]]*\]\([^)]*\)/.test(text) || /<a\s[^>]*href=/i.test(text)
}

// Kept as a local fallback so PreviewBlocks works with partial deps. build()
// prefers deps.extras.scanFences — one implementation of fence matching.
function localClosesFence(line, marker) {
  var character = marker.charAt(0)
  var re = new RegExp("^\\s{0,3}" + (character === "`" ? "`" : "~")
    + "{" + marker.length + ",}\\s*$")
  return re.test(stripCR(line))
}

function localScanFences(lines) {
  var source = lines === undefined || lines === null ? [] : lines
  var mask = []
  var marker = ""
  for (var i = 0; i < source.length; i++) {
    if (marker === "") {
      var open = FENCE_RE.exec(stripCR(source[i]))
      mask[i] = !!open
      if (open) marker = open[1]
      continue
    }
    mask[i] = true
    if (localClosesFence(source[i], marker)) marker = ""
  }
  return mask
}

function markFences(lines) {
  if (extrasModule && typeof extrasModule.scanFences === "function") {
    return extrasModule.scanFences(lines)
  }
  return localScanFences(lines)
}

function fenceMask(lines, extras) {
  if (extras && typeof extras.scanFences === "function") return extras.scanFences(lines)
  return localScanFences(lines)
}

function startsAt(list, skip) {
  var map = {}
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    // A footnote definition anywhere inside a table or display-maths range
    // means the range is really note text, not a block.
    if (skip) {
      var blocked = false
      for (var line = item.startLine; line <= item.endLine; line++) {
        if (skip[line]) {
          blocked = true
          break
        }
      }
      if (blocked) continue
    }
    map[item.startLine] = item
  }
  return map
}

function build(value, deps) {
  var modules = deps || {}
  var extras = modules.extras || null
  var image = modules.image || null
  var table = modules.table || null
  var math = modules.math || null
  var format = modules.format || null

  var lines = textOf(value).split("\n")
  var fenced = fenceMask(lines, extras)

  // Footnotes are found first: their definition lines are not notes to the
  // other finders. A definition containing "|" or "$$" must not become a
  // table or a maths block, and it must never enter a text block.
  var parsed = extras && typeof extras.parseFootnotes === "function"
    ? extras.parseFootnotes(lines)
    : { definitions: [], skip: [] }
  var definitions = parsed.definitions || []
  var skip = parsed.skip || []

  var tableAt = startsAt(table && typeof table.findTables === "function"
    ? table.findTables(lines) : [], skip)
  var mathAt = startsAt(math && typeof math.findDisplayBlocks === "function"
    ? math.findDisplayBlocks(lines) : [], skip)

  var codeAt = {}
  if (extras && typeof extras.codeBlocks === "function") {
    var code = extras.codeBlocks(lines)
    for (var c = 0; c < code.length; c++) {
      if (!skip[code[c].startLine]) codeAt[code[c].startLine] = code[c]
    }
  }

  var result = []
  var buffer = []
  var bufferStart = -1
  var bufferEnd = -1
  var tasks = []
  var tasksStart = -1
  var tasksEnd = -1

  function flushText() {
    if (buffer.length === 0) return
    var joined = buffer.join("\n")
    var first = bufferStart
    var last = bufferEnd
    buffer = []
    bufferStart = -1
    bufferEnd = -1
    if (joined.trim() === "") return
    result.push({ kind: "text", text: joined, startLine: first, endLine: last })
  }

  function flushTasks() {
    if (tasks.length === 0) return
    result.push({
      kind: "tasks",
      items: tasks,
      startLine: tasksStart,
      endLine: tasksEnd
    })
    tasks = []
    tasksStart = -1
    tasksEnd = -1
  }

  var i = 0
  while (i < lines.length) {
    if (skip[i]) {
      flushText()
      flushTasks()
      i += 1
      continue
    }

    var mathBlock = mathAt[i]
    if (mathBlock) {
      flushText()
      flushTasks()
      result.push({
        kind: "math",
        tex: mathBlock.tex,
        startLine: mathBlock.startLine,
        endLine: mathBlock.endLine
      })
      i = mathBlock.endLine + 1
      continue
    }

    var tableBlock = tableAt[i]
    if (tableBlock) {
      flushText()
      flushTasks()
      result.push({
        kind: "table",
        table: tableBlock,
        startLine: tableBlock.startLine,
        endLine: tableBlock.endLine
      })
      i = tableBlock.endLine + 1
      continue
    }

    var codeBlock = codeAt[i]
    if (codeBlock) {
      flushText()
      flushTasks()
      result.push({
        kind: "code",
        language: codeBlock.language,
        code: codeBlock.code,
        startLine: codeBlock.startLine,
        endLine: codeBlock.endLine
      })
      i = codeBlock.endLine + 1
      continue
    }

    // Definition lists are only meaningful outside a fence. A fence inside a
    // blockquote never reaches here anyway (its line starts with ">").
    if (!fenced[i] && extras && typeof extras.definitionListAt === "function") {
      var definitionList = extras.definitionListAt(lines, i)
      if (definitionList) {
        flushText()
        flushTasks()
        result.push({
          kind: "deflist",
          block: definitionList,
          startLine: definitionList.startLine,
          endLine: definitionList.endLine
        })
        i = definitionList.endLine + 1
        continue
      }
    }

    // Fenced lines stay literal: an image-looking line inside ``` is code,
    // not an image block. Tables and display maths already skip fences via
    // their finders.
    var imageBlock = !fenced[i] && image && typeof image.splitLine === "function"
      ? image.splitLine(lines[i]) : null
    if (imageBlock) {
      flushText()
      flushTasks()
      result.push({
        kind: "image",
        source: imageBlock.source,
        alt: imageBlock.alt,
        size: imageBlock,
        line: i,
        startLine: i,
        endLine: i
      })
      i += 1
      continue
    }

    var task = !fenced[i] && format && typeof format.parseTaskLine === "function"
      ? format.parseTaskLine(lines[i]) : null
    if (task) {
      flushText()
      if (tasksStart < 0) tasksStart = i
      tasksEnd = i
      tasks.push({
        checked: task.checked,
        content: task.content,
        indent: task.indent,
        line: i
      })
      i += 1
      continue
    }

    flushTasks()
    if (bufferStart < 0) bufferStart = i
    bufferEnd = i
    buffer.push(lines[i])
    i += 1
  }
  flushText()
  flushTasks()

  // The footnote section is one block at the very end, and only when the note
  // actually defines notes. The numbers come from first references in the
  // body; parseFootnotes has already kept the definitions out of every other
  // block. build() may be called with partial deps, so this is skipped
  // entirely when MarkdownExtras is absent.
  if (definitions.length > 0 && extras && typeof extras.footnoteNumbers === "function") {
    var numbered = extras.footnoteNumbers(lines, definitions, skip)
    var byLabel = {}
    for (var d = 0; d < definitions.length; d++) {
      if (!hasOwn(byLabel, definitions[d].label)) {
        byLabel[definitions[d].label] = definitions[d].text
      }
    }
    var items = []
    for (var o = 0; o < numbered.order.length; o++) {
      var label = numbered.order[o]
      if (!hasOwn(byLabel, label)) continue
      items.push({
        label: label,
        number: numbered.numbers[label],
        text: byLabel[label]
      })
    }
    if (items.length > 0) {
      result.push({ kind: "footnotes", items: items, startLine: -1, endLine: -1 })
    }
  }

  // Remember the active extras module so the exported markFences() delegates
  // to the same implementation after a build() call.
  if (extras) extrasModule = extras
  return result
}
