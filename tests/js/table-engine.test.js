'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual } = require('./helpers/load')

const engine = load('TableEngine.js')

function model (rows, header) {
  return { header: header || ['A', 'B', 'C'], aligns: [], delimiters: [], rows }
}

function displays (rows, header) {
  return engine.computeTable(model(rows, header)).map(row => row.map(cell => cell.display))
}

test('findTables parses a GFM table with alignments and line bounds', () => {
  const lines = [
    'intro',
    '| A | B |',
    '| --- | ---: |',
    '| 1 | 2 |',
    '| 3 | 4 |',
    'outro'
  ]
  const tables = engine.findTables(lines)
  assert.equal(tables.length, 1)
  deepEqual(tables[0].header, ['A', 'B'])
  deepEqual(tables[0].aligns, ['left', 'right'])
  deepEqual(tables[0].rows, [['1', '2'], ['3', '4']])
  assert.equal(tables[0].startLine, 1)
  assert.equal(tables[0].endLine, 4)
})

test('findTables ignores tables inside fenced code blocks', () => {
  const lines = [
    '```',
    '| A | B |',
    '| --- | --- |',
    '| 1 | 2 |',
    '```',
    '| C | D |',
    '| --- | --- |',
    '| 3 | 4 |'
  ]
  const tables = engine.findTables(lines)
  assert.equal(tables.length, 1)
  deepEqual(tables[0].header, ['C', 'D'])
})

test('serializeTable round-trips a parsed table', () => {
  const lines = ['| A | B |', '| --- | ---: |', '| 1 | 2 |']
  const table = engine.findTables(lines)[0]
  deepEqual(engine.serializeTable(table), lines)
})

test('parsing keeps cells wider than the header', () => {
  const table = engine.findTables(['| A | B |', '| --- | --- |', '| 1 | 2 | 3 |'])[0]
  assert.equal(table.header.length, 3)
  deepEqual(table.rows, [['1', '2', '3']])
})

test('escaped pipes survive parse and serialise', () => {
  const lines = ['| A | B |', '| --- | --- |', '| x \\| y | z |']
  const table = engine.findTables(lines)[0]
  assert.equal(table.rows[0][0], 'x \\| y')
  deepEqual(engine.serializeTable(table), lines)
})

test('an unpaired backtick does not swallow the cells after it', () => {
  const lines = ['| A | B |', '| --- | --- |', '| a `b | c |']
  const table = engine.findTables(lines)[0]
  deepEqual(table.rows, [['a `b', 'c']])
  deepEqual(engine.serializeTable(table), lines)
})

test('pipes inside a paired code span stay in one cell', () => {
  const lines = ['| A | B |', '| --- | --- |', '| `x | y` | z |']
  const table = engine.findTables(lines)[0]
  deepEqual(table.rows, [['`x | y`', 'z']])
  deepEqual(engine.serializeTable(table), lines)
})

test('insertRow and deleteRow change only the data rows', () => {
  const base = model([['1'], ['2']], ['A'])
  const inserted = engine.insertRow(base, 1)
  assert.equal(inserted.rows.length, 3)
  deepEqual(inserted.rows[1], [''])
  const deleted = engine.deleteRow(inserted, 1)
  deepEqual(deleted.rows, [['1'], ['2']])
})

test('insertColumn and deleteColumn update header and every row', () => {
  const inserted = engine.insertColumn(model([['1', '2']], ['A', 'B']), 1)
  deepEqual(inserted.header, ['A', '', 'B'])
  deepEqual(inserted.rows, [['1', '', '2']])
  const deleted = engine.deleteColumn(inserted, 1)
  deepEqual(deleted.header, ['A', 'B'])
  deepEqual(deleted.rows, [['1', '2']])
})

test('setCell, setAlign and sortRows update the model', () => {
  const updated = engine.setCell(model([['1']], ['A']), 0, 0, '=SUM(1,2)')
  assert.equal(updated.rows[0][0], '=SUM(1,2)')
  const aligned = engine.setAlign(model([], ['A']), 0, 'center')
  assert.equal(aligned.aligns[0], 'center')
  const sorted = engine.sortRows(model([['3'], ['1'], ['2']], ['A']), 0, 'asc')
  deepEqual(sorted.rows, [['1'], ['2'], ['3']])
})

test('column labels and A1 references convert both ways', () => {
  assert.equal(engine.columnLabel(0), 'A')
  assert.equal(engine.columnLabel(25), 'Z')
  assert.equal(engine.columnLabel(26), 'AA')
  deepEqual(engine.refToIndex('B3'), { row: 2, col: 1 })
  assert.equal(engine.indexToRef(2, 1), 'B3')
  assert.equal(engine.refToIndex('not-a-ref'), null)
})

test('SUM, AVERAGE, MIN, MAX and COUNT evaluate over ranges', () => {
  const rows = [
    ['1', '2', '=SUM(A1:B1)'],
    ['3', '4', '=AVERAGE(A1:B2)'],
    ['5', '6', '=MIN(A1:B3)'],
    ['7', '8', '=MAX(A1:B5)'],
    ['9', '10', '=COUNT(A1:B5)']
  ]
  deepEqual(displays(rows).map(row => row[2]), [
    '3', '2.5', '1', '10', '10'
  ])
})

test('ROUND, ABS and IF return computed values', () => {
  const rows = [
    ['=ROUND(3.14159,2)', '=ABS(-5)', '=IF(A1>3,"yes","no")'],
    ['=ROUND(1234,-2)', '=ABS(0)', '=IF(0,"yes","no")']
  ]
  deepEqual(displays(rows, ['A', 'B', 'C']), [
    ['3.14', '5', 'yes'],
    ['1200', '0', 'no']
  ])
})

test('ROUND rounds halves away from zero', () => {
  deepEqual(displays([
    ['=ROUND(-1.5,0)', '=ROUND(2.5,0)', '=ROUND(-0.05,1)']
  ]), [['-2', '3', '-0.1']])
})

test('a value smaller than a millionth is not displayed as zero', () => {
  deepEqual(displays([
    ['=0.0000001*1', '=0.00000025*1', '=0.1234567*1']
  ]), [['0.0000001', '0.00000025', '0.123457']])
})

test('formula errors surface with Excel-compatible codes', () => {
  const rows = [
    ['=A1', '=1+"x"', '=IF(1,2,3)'],
    ['=10/0', '=SUM(A1:A9)', '=BOGUS()'],
    ['=1+', '=C1', '=ABS(-5)']
  ]
  deepEqual(displays(rows), [
    ['#CYCLE!', '#VALUE!', '2'],
    ['#DIV/0!', '#REF!', '#NAME?'],
    ['#PARSE!', '2', '5']
  ])
})

test('formula cells expose both raw text and display value', () => {
  const cell = engine.computeTable(model([['=1+2']], ['A']))[0][0]
  assert.equal(cell.raw, '=1+2')
  assert.equal(cell.value, 3)
  assert.equal(cell.display, '3')
  assert.equal(cell.error, null)
})

test('tableLines returns only the table source lines', () => {
  const text = 'before\n| A |\n| --- |\n| 1 |\nafter'
  const table = engine.findTables(text.split('\n'))[0]
  deepEqual(engine.tableLines(text, table), ['| A |', '| --- |', '| 1 |'])
})
