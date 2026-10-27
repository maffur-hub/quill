// Spreadsheet tables for Quill.
//
// Plain ES5 with no Qt imports, so the parser, the formula engine and the
// structural helpers can all be exercised from node (see the test harness).
// The on-disk format stays GitHub-flavoured Markdown: a header line, a
// delimiter line and zero or more pipe rows.
//
// Supported source details:
//   | a | b |            outer pipes are optional
//   | a \| b | c |       escaped pipes stay in one cell
//   | `a|b` | c |        pipes inside inline code stay in one cell
//   |:---|:---:|---:|    left / center / right
//
// Formula cells start with "=" and are evaluated by computeTable(). The raw
// formula text is what is written back; the computed value only exists for
// display. Sorting rows does NOT rewrite cell references.

var FENCE_RE = /^\s*(`{3,}|~{3,})/
var DELIMITER_CELL_RE = /^:?-+:?$/
var REF_RE = /^\$?([A-Za-z]+)\$?([0-9]+)$/
var NUMBER_TEXT_RE = /^-?\d+(\.\d+)?$/

function stripCR(line) {
  var text = String(line === undefined || line === null ? "" : line)
  return text.charAt(text.length - 1) === "\r" ? text.slice(0, -1) : text
}

function repeat(value, count) {
  var output = ""
  for (var i = 0; i < count; i++) output += value
  return output
}

function isFence(line, state) {
  var text = stripCR(line)
  var match = text.match(FENCE_RE)
  if (!match) return false
  var marker = match[1]
  if (!state.open) return true
  // A closing fence has no info string: ```python inside a block stays code.
  if (text.slice(match[0].length).trim() !== "") return false
  return marker.charAt(0) === state.character && marker.length >= state.length
}

// Split one table line into raw cell text. Escaped pipes and pipes inside
// inline code spans do not separate cells. The returned values keep their
// escapes and code markers so serialisation can round-trip them.
function splitCells(line) {
  var text = stripCR(line)
  var cells = []
  var current = ""
  var escaped = false
  var codeRun = 0

  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (escaped) {
      current += ch
      escaped = false
      continue
    }
    if (ch === "\\") {
      current += ch
      escaped = true
      continue
    }
    if (ch === "`") {
      var run = 1
      while (i + 1 < text.length && text.charAt(i + 1) === "`") {
        run += 1
        i += 1
      }
      current += repeat("`", run)
      if (codeRun === 0) codeRun = run
      else if (run === codeRun) codeRun = 0
      continue
    }
    if (ch === "|" && codeRun === 0) {
      cells.push(current)
      current = ""
      continue
    }
    current += ch
  }
  cells.push(current)

  // An outer pipe produces one empty cell at each end; drop only those.
  if (cells.length > 0 && cells[0].trim() === "") cells.shift()
  if (cells.length > 0 && cells[cells.length - 1].trim() === "") cells.pop()

  for (var j = 0; j < cells.length; j++) cells[j] = cells[j].trim()
  return cells
}

function hasDelimiterPipe(line) {
  var text = stripCR(line)
  var escaped = false
  var codeRun = 0
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (escaped) {
      escaped = false
      continue
    }
    if (ch === "\\") {
      escaped = true
      continue
    }
    if (ch === "`") {
      var run = 1
      while (i + 1 < text.length && text.charAt(i + 1) === "`") {
        run += 1
        i += 1
      }
      if (codeRun === 0) codeRun = run
      else if (run === codeRun) codeRun = 0
      continue
    }
    if (ch === "|" && codeRun === 0) return true
  }
  return false
}

function delimiterAligns(line) {
  var parsed = parseDelimiterLine(line)
  return parsed ? parsed.aligns : null
}

// Keep the original delimiter text so an untouched table round-trips exactly.
// Parsed left columns written with `---` stay `---`; new or realigned columns
// use the canonical `:---` / `:---:` / `---:` forms.
function parseDelimiterLine(line) {
  if (!hasDelimiterPipe(line)) return null
  var cells = splitCells(line)
  if (cells.length === 0) return null
  var aligns = []
  for (var i = 0; i < cells.length; i++) {
    var value = cells[i]
    if (!DELIMITER_CELL_RE.test(value)) return null
    var left = value.charAt(0) === ":"
    var right = value.charAt(value.length - 1) === ":"
    aligns.push(left && right ? "center" : right ? "right" : "left")
  }
  return { aligns: aligns, cells: cells }
}

function normalizeAlign(value) {
  return value === "center" || value === "right" ? value : "left"
}

// Parse the table whose header is at `lines[index]`. Returns null when the
// header/delimiter pair is not a table.
function parseTableAt(lines, index) {
  if (index < 0 || index >= lines.length) return null
  var header = splitCells(lines[index])
  var delimiter = parseDelimiterLine(lines[index + 1])
  if (delimiter === null || header.length === 0) return null
  var aligns = delimiter.aligns
  if (header.length !== aligns.length) return null

  var rows = []
  var endLine = index + 1
  var i = index + 2
  while (i < lines.length) {
    var line = stripCR(lines[i])
    if (line.trim() === "") break
    if (delimiterAligns(line) !== null) break
    if (!hasDelimiterPipe(line)) break
    var cells = splitCells(line)
    while (cells.length < header.length) cells.push("")
    rows.push(cells.slice(0, header.length))
    endLine = i
    i += 1
  }

  return {
    startLine: index,
    endLine: endLine,
    header: header.slice(0),
    aligns: aligns.slice(0),
    delimiters: delimiter.cells.slice(0),
    rows: rows
  }
}

// Find every table outside fenced code blocks. Line numbers are zero-based
// and refer to the supplied array (the note text, not the preview text).
function findTables(lines) {
  var source = lines || []
  var tables = []
  var fence = { open: false, character: "", length: 0 }
  var i = 0
  while (i < source.length) {
    var line = stripCR(source[i])
    if (isFence(line, fence)) {
      if (!fence.open) {
        var marker = line.match(FENCE_RE)[1]
        fence.open = true
        fence.character = marker.charAt(0)
        fence.length = marker.length
      } else {
        fence.open = false
        fence.character = ""
        fence.length = 0
      }
      i += 1
      continue
    }
    if (fence.open) { i += 1; continue }

    var table = parseTableAt(source, i)
    if (table) {
      tables.push(table)
      i = table.endLine + 1
      continue
    }
    i += 1
  }
  return tables
}

// QML hands nested QVariantLists to JS, and Array.isArray() is false for
// those even though they index and report .length like an array. Duck-type
// list-shaped values so the same engine works from node and from QML.
function isList(value) {
  return !!value && typeof value === "object" && typeof value.length === "number"
}

function copyList(value) {
  var output = []
  if (!isList(value)) return output
  for (var i = 0; i < value.length; i++) output.push(value[i])
  return output
}

function normalizeModel(model) {
  var source = model || {}
  var header = copyList(source.header)
  var aligns = copyList(source.aligns)
  var delimiters = copyList(source.delimiters)
  var rowsSource = copyList(source.rows)

  var columns = Math.max(header.length, aligns.length, 1)
  for (var r = 0; r < rowsSource.length; r++) {
    var row = copyList(rowsSource[r])
    if (row.length > columns) columns = row.length
  }

  while (header.length < columns) header.push("")
  header = header.slice(0, columns)
  for (var c = 0; c < columns; c++) aligns[c] = normalizeAlign(aligns[c])
  aligns = aligns.slice(0, columns)
  while (delimiters.length < columns) delimiters.push("")
  delimiters = delimiters.slice(0, columns)

  var rows = []
  for (var i = 0; i < rowsSource.length; i++) {
    var input = copyList(rowsSource[i])
    var copy = []
    for (var j = 0; j < columns; j++) copy.push(input[j] === undefined || input[j] === null ? "" : String(input[j]))
    rows.push(copy)
  }
  return { header: header, aligns: aligns, delimiters: delimiters, rows: rows }
}

function cloneModel(model) {
  return normalizeModel(model)
}

function columnLabel(index) {
  var value = Math.max(0, Math.floor(Number(index) || 0))
  var label = ""
  do {
    label = String.fromCharCode(65 + (value % 26)) + label
    value = Math.floor(value / 26) - 1
  } while (value >= 0)
  return label
}

function refToIndex(ref) {
  var match = String(ref === undefined || ref === null ? "" : ref).trim().match(REF_RE)
  if (!match) return null
  var letters = match[1].toUpperCase()
  var column = 0
  for (var i = 0; i < letters.length; i++) {
    column = column * 26 + (letters.charCodeAt(i) - 64)
  }
  var row = parseInt(match[2], 10)
  if (!isFinite(row) || row < 1) return null
  return { row: row - 1, col: column - 1 }
}

function indexToRef(row, col) {
  var r = Math.floor(Number(row) || 0)
  var c = Math.floor(Number(col) || 0)
  if (r < 0 || c < 0) return ""
  return columnLabel(c) + String(r + 1)
}

// Escape bare pipes outside inline code and leave existing `\|` escapes alone.
function escapePipes(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var output = ""
  var escaped = false
  var codeRun = 0
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (escaped) {
      output += ch
      escaped = false
      continue
    }
    if (ch === "\\") {
      output += ch
      escaped = true
      continue
    }
    if (ch === "`") {
      var run = 1
      while (i + 1 < text.length && text.charAt(i + 1) === "`") {
        run += 1
        i += 1
      }
      output += repeat("`", run)
      if (codeRun === 0) codeRun = run
      else if (run === codeRun) codeRun = 0
      continue
    }
    if (ch === "|" && codeRun === 0) {
      output += "\\|"
      continue
    }
    output += ch
  }
  return output
}

function delimiterCell(align) {
  if (align === "center") return ":---:"
  if (align === "right") return "---:"
  return ":---"
}

function alignOfDelimiterCell(value) {
  var text = String(value || "")
  if (!DELIMITER_CELL_RE.test(text)) return null
  var left = text.charAt(0) === ":"
  var right = text.charAt(text.length - 1) === ":"
  return left && right ? "center" : right ? "right" : "left"
}

function delimiterFor(model, column) {
  var original = model.delimiters && model.delimiters[column] ? String(model.delimiters[column]) : ""
  if (original && alignOfDelimiterCell(original) === model.aligns[column]) return original
  return delimiterCell(model.aligns[column])
}

function serializeRow(cells, columns) {
  var parts = []
  for (var i = 0; i < columns; i++) {
    var value = cells && cells[i] !== undefined && cells[i] !== null ? String(cells[i]) : ""
    parts.push(escapePipes(value))
  }
  return "| " + parts.join(" | ") + " |"
}

function serializeTable(model) {
  var m = normalizeModel(model)
  var columns = m.header.length
  var lines = [serializeRow(m.header, columns)]
  var delimiter = []
  for (var c = 0; c < columns; c++) delimiter.push(delimiterFor(m, c))
  lines.push("| " + delimiter.join(" | ") + " |")
  for (var r = 0; r < m.rows.length; r++) lines.push(serializeRow(m.rows[r], columns))
  return lines
}

// --------------------------------------------------------------- formulas

function formatNumber(value) {
  if (!isFinite(value)) return "#NUM!"
  var number = Number(value)
  if (number === 0) number = 0
  if (Math.floor(number) === number && Math.abs(number) < 1e21) return String(number)
  var output = number.toFixed(6).replace(/0+$/, "").replace(/\.$/, "")
  return output === "-0" ? "0" : output
}

function makeError(code) {
  return { kind: "error", value: code, display: code, error: code }
}

function makeNumber(value) {
  if (!isFinite(value)) return makeError("#VALUE!")
  return { kind: "number", value: value, display: formatNumber(value), error: null }
}

function makeString(value) {
  return { kind: "string", value: value, display: String(value), error: null }
}

function makeBoolean(value) {
  return { kind: "boolean", value: !!value, display: value ? "TRUE" : "FALSE", error: null }
}

function makeEmpty() {
  return { kind: "empty", value: 0, display: "", error: null }
}

function literalValue(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text === "") return makeEmpty()
  if (NUMBER_TEXT_RE.test(text)) return makeNumber(Number(text))
  return makeString(text)
}

function tokenize(source) {
  var text = String(source)
  var tokens = []
  var i = 0
  while (i < text.length) {
    var ch = text.charAt(i)
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") { i += 1; continue }

    if (ch >= "0" && ch <= "9") {
      var number = text.slice(i).match(/^\d+(\.\d+)?([eE][+\-]?\d+)?/)
      tokens.push({ type: "number", value: Number(number[0]) })
      i += number[0].length
      continue
    }

    if (ch === "." && /[0-9]/.test(text.charAt(i + 1))) {
      var decimal = text.slice(i).match(/^\.\d+([eE][+\-]?\d+)?/)
      tokens.push({ type: "number", value: Number(decimal[0]) })
      i += decimal[0].length
      continue
    }

    if (ch === "\"") {
      var value = ""
      i += 1
      var closed = false
      while (i < text.length) {
        if (text.charAt(i) === "\"") {
          if (text.charAt(i + 1) === "\"") { value += "\""; i += 2; continue }
          i += 1
          closed = true
          break
        }
        value += text.charAt(i)
        i += 1
      }
      if (!closed) return null
      tokens.push({ type: "string", value: value })
      continue
    }

    if (ch === "$" || /[A-Za-z]/.test(ch)) {
      var rest = text.slice(i)
      var ref = rest.match(/^\$?[A-Za-z]+\$?[0-9]+/)
      if (ref) {
        tokens.push({ type: "ref", value: ref[0] })
        i += ref[0].length
        continue
      }
      var name = rest.match(/^[A-Za-z_][A-Za-z0-9_.]*/)
      if (name) {
        tokens.push({ type: "name", value: name[0] })
        i += name[0].length
        continue
      }
    }

    var pair = text.slice(i, i + 2)
    if (pair === "<=" || pair === ">=" || pair === "<>") {
      tokens.push({ type: "op", value: pair })
      i += 2
      continue
    }

    if ("+-*/%^=<>(),:".indexOf(ch) >= 0) {
      tokens.push({ type: "op", value: ch })
      i += 1
      continue
    }

    return null
  }
  return tokens
}

function parserPeek(p) {
  return p.index < p.tokens.length ? p.tokens[p.index] : null
}

function parserNext(p) {
  var token = parserPeek(p)
  if (token) p.index += 1
  return token
}

function parserOperator(p, value) {
  var token = parserPeek(p)
  if (token && token.type === "op" && token.value === value) {
    p.index += 1
    return true
  }
  return false
}

function parseExpression(p) { return parseComparison(p) }

function parseComparison(p) {
  var left = parseAdditive(p)
  if (!left) return null
  var token = parserPeek(p)
  if (token && token.type === "op"
    && (token.value === "=" || token.value === "<>" || token.value === "<"
      || token.value === ">" || token.value === "<=" || token.value === ">=")) {
    parserNext(p)
    var right = parseAdditive(p)
    if (!right) return null
    return { type: "binary", op: token.value, left: left, right: right }
  }
  return left
}

function parseAdditive(p) {
  var node = parseMultiplicative(p)
  if (!node) return null
  while (true) {
    var token = parserPeek(p)
    if (!token || token.type !== "op" || (token.value !== "+" && token.value !== "-")) return node
    parserNext(p)
    var right = parseMultiplicative(p)
    if (!right) return null
    node = { type: "binary", op: token.value, left: node, right: right }
  }
}

function parseMultiplicative(p) {
  var node = parseUnary(p)
  if (!node) return null
  while (true) {
    var token = parserPeek(p)
    if (!token || token.type !== "op" || (token.value !== "*" && token.value !== "/" && token.value !== "%")) return node
    parserNext(p)
    var right = parseUnary(p)
    if (!right) return null
    node = { type: "binary", op: token.value, left: node, right: right }
  }
}

function parseUnary(p) {
  var token = parserPeek(p)
  if (token && token.type === "op" && (token.value === "-" || token.value === "+")) {
    parserNext(p)
    var operand = parseUnary(p)
    if (!operand) return null
    return { type: "unary", op: token.value, operand: operand }
  }
  return parsePower(p)
}

function parsePower(p) {
  var node = parsePrimary(p)
  if (!node) return null
  if (parserOperator(p, "^")) {
    var right = parseUnary(p)
    if (!right) return null
    return { type: "binary", op: "^", left: node, right: right }
  }
  return node
}

function parseArguments(p) {
  var args = []
  if (parserOperator(p, ")")) return args
  while (true) {
    var arg = parseExpression(p)
    if (!arg) return null
    args.push(arg)
    if (parserOperator(p, ")")) return args
    if (!parserOperator(p, ",")) return null
  }
}

function parsePrimary(p) {
  var token = parserPeek(p)
  if (!token) return null

  if (token.type === "number") {
    parserNext(p)
    return { type: "number", value: token.value }
  }
  if (token.type === "string") {
    parserNext(p)
    return { type: "string", value: token.value }
  }
  if (token.type === "ref") {
    parserNext(p)
    if (parserOperator(p, ":")) {
      var end = parserNext(p)
      if (!end || end.type !== "ref") return null
      return { type: "range", from: token.value, to: end.value }
    }
    return { type: "ref", ref: token.value }
  }
  if (token.type === "name") {
    parserNext(p)
    if (!parserOperator(p, "(")) return { type: "name", name: token.value }
    var args = parseArguments(p)
    if (!args) return null
    return { type: "call", name: token.value, args: args }
  }
  if (token.type === "op" && token.value === "(") {
    parserNext(p)
    var inner = parseExpression(p)
    if (!inner) return null
    if (!parserOperator(p, ")")) return null
    return inner
  }
  return null
}

function truthy(value) {
  if (value.kind === "error") return false
  if (value.kind === "number") return value.value !== 0
  if (value.kind === "boolean") return value.value === true
  if (value.kind === "string") {
    var text = String(value.value).toLowerCase()
    return text !== "" && text !== "false"
  }
  return false
}

function numberFor(value) {
  if (value.kind === "error") return null
  if (value.kind === "number") return value.value
  if (value.kind === "boolean") return value.value ? 1 : 0
  if (value.kind === "empty") return 0
  if (value.kind === "string") {
    var text = String(value.value).trim()
    if (NUMBER_TEXT_RE.test(text)) return Number(text)
    return null
  }
  return null
}

function compareNumbers(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function compareForOperator(left, right, op) {
  if (left.kind === "range" || right.kind === "range") return makeError("#VALUE!")
  if (left.kind === "error") return left
  if (right.kind === "error") return right
  var a = numberFor(left)
  var b = numberFor(right)
  if (op === "=" || op === "<>") {
    var equal
    if (a !== null && b !== null) equal = a === b
    else if (left.kind === "string" && right.kind === "string") {
      equal = String(left.value).toLowerCase() === String(right.value).toLowerCase()
    } else if (left.kind === "empty" && right.kind === "empty") equal = true
    else equal = String(left.value) === String(right.value)
    return makeBoolean(op === "=" ? equal : !equal)
  }
  var result
  if (a !== null && b !== null) {
    result = compareNumbers(a, b)
  } else if (left.kind === "string" && right.kind === "string") {
    var x = String(left.value).toLowerCase()
    var y = String(right.value).toLowerCase()
    result = x < y ? -1 : x > y ? 1 : 0
  } else {
    return makeError("#VALUE!")
  }
  if (op === "<") return makeBoolean(result < 0)
  if (op === ">") return makeBoolean(result > 0)
  if (op === "<=") return makeBoolean(result <= 0)
  return makeBoolean(result >= 0)
}

function computeTable(model) {
  var m = normalizeModel(model)
  var rows = m.rows
  var columns = m.header.length
  var cache = {}
  var visiting = {}

  function key(row, column) { return row + "," + column }

  function literalResult(raw) {
    var text = String(raw === undefined || raw === null ? "" : raw)
    if (text.charAt(0) === "=") {
      if (text.length === 1) return makeError("#PARSE!")
      var tokens = tokenize(text.slice(1))
      if (!tokens) return makeError("#PARSE!")
      var parser = { tokens: tokens, index: 0 }
      var node = parseExpression(parser)
      if (!node || parser.index < tokens.length) return makeError("#PARSE!")
      return evaluateNode(node, null, false)
    }
    return literalValue(text)
  }

  function evaluateNode(node, owner, allowRange) {
    if (!node) return makeError("#PARSE!")

    if (node.type === "number") return makeNumber(node.value)
    if (node.type === "string") return makeString(node.value)
    if (node.type === "name") return makeError("#NAME?")

    if (node.type === "ref") {
      var index = refToIndex(node.ref)
      if (!index) return makeError("#REF!")
      return cellValue(index.row, index.col)
    }

    if (node.type === "range") {
      if (!allowRange) return makeError("#VALUE!")
      return { kind: "range", from: node.from, to: node.to, display: "", error: null }
    }

    if (node.type === "unary") {
      var operand = evaluateNode(node.operand, owner, false)
      if (operand.kind === "error") return operand
      if (operand.kind === "range") return makeError("#VALUE!")
      var numeric = numberFor(operand)
      if (numeric === null) return makeError("#VALUE!")
      return makeNumber(node.op === "-" ? -numeric : numeric)
    }

    if (node.type === "binary") {
      var left = evaluateNode(node.left, owner, false)
      if (left.kind === "error") return left
      var right = evaluateNode(node.right, owner, false)
      if (right.kind === "error") return right
      if (left.kind === "range" || right.kind === "range") return makeError("#VALUE!")

      if (node.op === "=" || node.op === "<>" || node.op === "<"
        || node.op === ">" || node.op === "<=" || node.op === ">=") {
        return compareForOperator(left, right, node.op)
      }

      var a = numberFor(left)
      var b = numberFor(right)
      if (a === null || b === null) return makeError("#VALUE!")

      if (node.op === "+") return makeNumber(a + b)
      if (node.op === "-") return makeNumber(a - b)
      if (node.op === "*") return makeNumber(a * b)
      if (node.op === "/") return b === 0 ? makeError("#DIV/0!") : makeNumber(a / b)
      if (node.op === "%") return b === 0 ? makeError("#DIV/0!") : makeNumber(a % b)
      if (node.op === "^") return makeNumber(Math.pow(a, b))
      return makeError("#PARSE!")
    }

    if (node.type === "call") {
      var name = String(node.name || "").toUpperCase()

      if (name === "IF") {
        if (node.args.length !== 3) return makeError("#PARSE!")
        var condition = evaluateNode(node.args[0], owner, false)
        if (condition.kind === "error") return condition
        return truthy(condition)
          ? evaluateNode(node.args[1], owner, false)
          : evaluateNode(node.args[2], owner, false)
      }

      var values = []
      var rangeValues = []
      var argIndex
      for (argIndex = 0; argIndex < node.args.length; argIndex++) {
        var argument = node.args[argIndex]
        if (argument.type === "range") {
          var resolved = resolveRange(argument)
          if (resolved.error) return resolved.error
          for (var r = resolved.r1; r <= resolved.r2; r++) {
            for (var c = resolved.c1; c <= resolved.c2; c++) {
              rangeValues.push({ cell: cellValue(r, c), inRange: true })
            }
          }
        } else {
          var value = evaluateNode(argument, owner, false)
          if (value.kind === "range") return makeError("#VALUE!")
          values.push({ cell: value, inRange: false })
        }
      }
      var all = rangeValues.concat(values)

      if (name === "SUM" || name === "AVERAGE" || name === "AVG" || name === "MIN" || name === "MAX" || name === "COUNT") {
        var numbers = []
        for (var i = 0; i < all.length; i++) {
          var entry = all[i]
          var cell = entry.cell
          if (cell.kind === "error") {
            if (name === "COUNT" && entry.inRange) continue
            return cell
          }
          if (cell.kind === "empty") continue
          var numeric = numberFor(cell)
          if (numeric === null) continue
          numbers.push(numeric)
        }
        if (name === "COUNT") return makeNumber(numbers.length)
        if (name === "SUM") {
          var sum = 0
          for (var s = 0; s < numbers.length; s++) sum += numbers[s]
          return makeNumber(sum)
        }
        if (name === "AVERAGE" || name === "AVG") {
          if (numbers.length === 0) return makeError("#DIV/0!")
          var total = 0
          for (var t = 0; t < numbers.length; t++) total += numbers[t]
          return makeNumber(total / numbers.length)
        }
        if (numbers.length === 0) return makeNumber(0)
        var best = numbers[0]
        for (var u = 1; u < numbers.length; u++) {
          if (name === "MIN" ? numbers[u] < best : numbers[u] > best) best = numbers[u]
        }
        return makeNumber(best)
      }

      if (name === "ROUND") {
        if (node.args.length !== 2) return makeError("#PARSE!")
        var roundValue = evaluateNode(node.args[0], owner, false)
        if (roundValue.kind === "error") return roundValue
        var roundDigits = evaluateNode(node.args[1], owner, false)
        if (roundDigits.kind === "error") return roundDigits
        var roundNumber = numberFor(roundValue)
        var digits = numberFor(roundDigits)
        if (roundNumber === null || digits === null) return makeError("#VALUE!")
        digits = Math.max(-10, Math.min(10, Math.round(digits)))
        var factor = Math.pow(10, digits)
        return makeNumber(Math.round(roundNumber * factor) / factor)
      }

      if (name === "ABS") {
        if (node.args.length !== 1) return makeError("#PARSE!")
        var absValue = evaluateNode(node.args[0], owner, false)
        if (absValue.kind === "error") return absValue
        var absNumber = numberFor(absValue)
        return absNumber === null ? makeError("#VALUE!") : makeNumber(Math.abs(absNumber))
      }

      return makeError("#NAME?")
    }

    return makeError("#PARSE!")
  }

  function resolveRange(node) {
    var from = refToIndex(node.from)
    var to = refToIndex(node.to)
    if (!from || !to) return { error: makeError("#REF!") }
    var r1 = Math.min(from.row, to.row)
    var r2 = Math.max(from.row, to.row)
    var c1 = Math.min(from.col, to.col)
    var c2 = Math.max(from.col, to.col)
    if (r2 >= rows.length || c2 >= columns) return { error: makeError("#REF!") }
    return { r1: r1, r2: r2, c1: c1, c2: c2 }
  }

  function cellValue(row, column) {
    if (row < 0 || row >= rows.length || column < 0 || column >= columns) return makeError("#REF!")
    var id = key(row, column)
    if (cache[id]) return cache[id]
    if (visiting[id]) return makeError("#CYCLE!")
    var raw = rows[row][column] === undefined ? "" : String(rows[row][column])
    var result
    if (raw.charAt(0) === "=") {
      visiting[id] = true
      result = literalResult(raw)
      delete visiting[id]
    } else {
      result = literalValue(raw)
    }
    cache[id] = result
    return result
  }

  var output = []
  for (var r = 0; r < rows.length; r++) {
    var line = []
    for (var c = 0; c < columns; c++) {
      var result = cellValue(r, c)
      var raw = rows[r][c]
      var isFormula = String(raw).charAt(0) === "="
      line.push({
        raw: raw,
        value: result.kind === "empty" ? "" : result.value,
        display: result.kind === "error" ? result.error : isFormula ? result.display : raw,
        error: result.kind === "error" ? result.error : null
      })
    }
    output.push(line)
  }
  return output
}

// ------------------------------------------------------- structural helpers

function insertRow(model, at) {
  var m = normalizeModel(model)
  var index = Math.floor(Number(at))
  if (!isFinite(index)) index = m.rows.length
  index = Math.max(0, Math.min(m.rows.length, index))
  var row = []
  for (var c = 0; c < m.header.length; c++) row.push("")
  m.rows.splice(index, 0, row)
  return m
}

function deleteRow(model, at) {
  var m = normalizeModel(model)
  var index = Math.floor(Number(at))
  if (!isFinite(index) || index < 0 || index >= m.rows.length) return m
  m.rows.splice(index, 1)
  return m
}

function insertColumn(model, at) {
  var m = normalizeModel(model)
  var index = Math.floor(Number(at))
  if (!isFinite(index)) index = m.header.length
  index = Math.max(0, Math.min(m.header.length, index))
  m.header.splice(index, 0, "")
  m.aligns.splice(index, 0, "left")
  m.delimiters.splice(index, 0, delimiterCell("left"))
  for (var r = 0; r < m.rows.length; r++) m.rows[r].splice(index, 0, "")
  return m
}

function deleteColumn(model, at) {
  var m = normalizeModel(model)
  if (m.header.length <= 1) return m
  var index = Math.floor(Number(at))
  if (!isFinite(index) || index < 0 || index >= m.header.length) return m
  m.header.splice(index, 1)
  m.aligns.splice(index, 1)
  m.delimiters.splice(index, 1)
  for (var r = 0; r < m.rows.length; r++) m.rows[r].splice(index, 1)
  return m
}

function setCell(model, row, column, raw) {
  var m = normalizeModel(model)
  var r = Math.floor(Number(row))
  var c = Math.floor(Number(column))
  if (!isFinite(r) || !isFinite(c) || r < 0 || r >= m.rows.length || c < 0 || c >= m.header.length) return m
  m.rows[r][c] = String(raw === undefined || raw === null ? "" : raw)
  return m
}

function sortRank(cell) {
  if (!cell) return 3
  if (cell.error) return 2
  if (cell.display === "" || cell.value === "") return 3
  return 1
}

function sortRows(model, column, direction) {
  var m = normalizeModel(model)
  var c = Math.floor(Number(column))
  if (!isFinite(c) || c < 0 || c >= m.header.length) return m
  var computed = computeTable(m)
  var decorated = []
  for (var i = 0; i < m.rows.length; i++) {
    decorated.push({ row: m.rows[i], index: i, cell: computed[i][c] })
  }
  var descending = String(direction || "asc").toLowerCase().indexOf("desc") === 0
  decorated.sort(function(a, b) {
    var rankA = sortRank(a.cell)
    var rankB = sortRank(b.cell)
    if (rankA !== rankB) {
      if (rankA === 3) return 1
      if (rankB === 3) return -1
      return rankA - rankB
    }
    if (rankA !== 1) return a.index - b.index
    var valueA = a.cell.value
    var valueB = b.cell.value
    var result
    if (typeof valueA === "number" && typeof valueB === "number") {
      result = valueA < valueB ? -1 : valueA > valueB ? 1 : 0
    } else {
      var textA = String(valueA).toLowerCase()
      var textB = String(valueB).toLowerCase()
      result = textA < textB ? -1 : textA > textB ? 1 : 0
    }
    if (result === 0) return a.index - b.index
    return descending ? -result : result
  })
  m.rows = []
  for (var d = 0; d < decorated.length; d++) m.rows.push(decorated[d].row)
  return m
}

function setAlign(model, column, align) {
  var m = normalizeModel(model)
  var c = Math.floor(Number(column))
  if (!isFinite(c) || c < 0 || c >= m.header.length) return m
  m.aligns[c] = normalizeAlign(align)
  m.delimiters[c] = delimiterCell(m.aligns[c])
  return m
}

// ------------------------------------------------------------ note rewriting

function rewriteNoteText(noteText, table, newTableLines) {
  var text = String(noteText === undefined || noteText === null ? "" : noteText)
  var crlf = text.indexOf("\r\n") >= 0
  var eol = crlf ? "\r\n" : "\n"
  var rawLines = text.split("\n")
  var lines = []
  for (var i = 0; i < rawLines.length; i++) lines.push(stripCR(rawLines[i]))

  var start = Math.max(0, Math.floor(Number(table.startLine)))
  var end = Math.max(start, Math.floor(Number(table.endLine)))
  var replacement = []
  var next = newTableLines || []
  for (var j = 0; j < next.length; j++) replacement.push(stripCR(next[j]))

  lines.splice(start, end - start + 1)
  var output = []
  for (var k = 0; k < start; k++) output.push(lines[k])
  for (var n = 0; n < replacement.length; n++) output.push(replacement[n])
  for (var m = start; m < lines.length; m++) output.push(lines[m])
  return output.join(eol)
}

function rewriteTableLines(sourceLines, table, newTableLines) {
  var text = (sourceLines || []).join("\n")
  return rewriteNoteText(text, table, newTableLines)
}

function tableLines(noteText, table) {
  var rawLines = String(noteText === undefined || noteText === null ? "" : noteText).split("\n")
  var lines = []
  for (var i = 0; i < rawLines.length; i++) lines.push(stripCR(rawLines[i]))
  var start = Math.max(0, Math.floor(Number(table.startLine)))
  var end = Math.min(lines.length - 1, Math.floor(Number(table.endLine)))
  return lines.slice(start, end + 1)
}

function sameLines(left, right) {
  var a = left || []
  var b = right || []
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (stripCR(a[i]) !== stripCR(b[i])) return false
  }
  return true
}
