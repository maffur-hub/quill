'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, plain } = require('./helpers/load')

const { plan } = load('MarkdownFormat.js')

test('bold wraps a selection and keeps the surrounding text', () => {
  const result = plan('hello world', 0, 5, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, '**hello** world')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 2, end: 7 })
  assert.deepEqual(plain(result.edits), [{ start: 0, end: 5, text: '**hello**' }])
})

test('italic wraps a selection with single asterisks', () => {
  const result = plan('hello world', 6, 11, 'italic')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hello *world*')
})

test('inline code wraps a selection with backticks', () => {
  const result = plan('run it', 0, 3, 'code')
  assert.equal(result.ok, true)
  assert.equal(result.text, '`run` it')
})

test('bold toggles off when the selection is already wrapped', () => {
  const result = plan('**hello** world', 2, 7, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hello world')
})

test('heading adds an ATX prefix at the requested level', () => {
  const result = plan('hello', 0, 0, 'heading', 2)
  assert.equal(result.ok, true)
  assert.equal(result.text, '## hello')
  assert.equal(result.selectionStart, 3)
})

test('heading level 0 removes an existing prefix', () => {
  const result = plan('### hello', 0, 9, 'heading', 0)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hello')
})

test('heading with level 0 on an unstyled line is a no-op', () => {
  const result = plan('hello', 0, 5, 'heading', 0)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hello')
  assert.deepEqual(plain(result.edits), [])
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 0, end: 5 })
})

test('bullet list applies to every selected line', () => {
  const result = plan('alpha\nbeta', 0, 10, 'bullet')
  assert.equal(result.ok, true)
  assert.equal(result.text, '- alpha\n- beta')
})

test('numbered list counts selected lines', () => {
  const result = plan('alpha\nbeta\ngamma', 0, 16, 'number')
  assert.equal(result.ok, true)
  assert.equal(result.text, '1. alpha\n2. beta\n3. gamma')
})

test('bullet toggles an existing bullet list back to plain lines', () => {
  const result = plan('- alpha\n- beta', 0, 14, 'bullet')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'alpha\nbeta')
})

test('link wraps the selected text and selects its label', () => {
  const result = plan('see docs', 4, 8, 'link', 'https://example.test')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'see [docs](https://example.test)')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 5, end: 9 })
})

test('link at a caret inserts a Link placeholder', () => {
  const result = plan('', 0, 0, 'link', 'https://example.test')
  assert.equal(result.ok, true)
  assert.equal(result.text, '[Link](https://example.test)')
})

test('an empty link URL is rejected', () => {
  const result = plan('hello', 0, 5, 'link', '')
  assert.equal(result.ok, false)
  assert.match(result.error, /link URL/i)
})

test('code block inserts fenced code and selects the inner text', () => {
  const result = plan('', 0, 0, 'codeblock')
  assert.equal(result.ok, true)
  assert.equal(result.text, '```\n\n```')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 4, end: 4 })
})

test('table insert uses the requested rows and columns', () => {
  const result = plan('', 0, 0, 'table', { rows: 2, columns: 2 })
  assert.equal(result.ok, true)
  assert.equal(result.text, '|  |  |\n| --- | --- |\n|  |  |\n|  |  |\n')
})

test('horizontal rule inserts a rule and leaves the caret after it', () => {
  const result = plan('', 0, 0, 'hr')
  assert.equal(result.ok, true)
  assert.equal(result.text, '---\n')
  assert.equal(result.selectionStart, 3)
})

test('clear formatting strips bold markers around the selection', () => {
  const result = plan('**bold**', 2, 6, 'clear')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'bold')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 0, end: 4 })
})

test('selection replacement edits only the selected range', () => {
  const result = plan('one two three', 4, 7, 'code')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'one `two` three')
  assert.equal(result.edits.length, 1)
  assert.equal(result.edits[0].start, 4)
  assert.equal(result.edits[0].end, 7)
})

test('unknown actions fail rather than throwing', () => {
  const result = plan('hello', 0, 5, 'not-a-real-action')
  assert.equal(result.ok, false)
  assert.match(result.error, /Unknown formatting action/)
})

test('reversed selections are normalised before formatting', () => {
  const result = plan('hello world', 5, 0, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, '**hello** world')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 2, end: 7 })
})
