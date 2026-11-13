'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual } = require('./helpers/load')

const extras = load('MarkdownExtras.js')

test('scanFences marks both fence lines and every interior line', () => {
  deepEqual(extras.scanFences(['before', '```js', 'x', '```', 'after']),
    [false, true, true, true, false])
})

test('a shorter fence does not close a longer one', () => {
  deepEqual(extras.scanFences(['````', '```', 'still code', '`````', 'after']),
    [true, true, true, true, false])
})

test('tilde and backtick fences only close against their own character', () => {
  deepEqual(extras.scanFences(['```', '~~~', 'code', '```', 'after']),
    [true, true, true, true, false])
  deepEqual(extras.scanFences(['~~~', '```', 'code', '~~~', 'after']),
    [true, true, true, true, false])
})

test('an unclosed fence runs to the end of the note', () => {
  deepEqual(extras.scanFences(['```', 'a', 'b']), [true, true, true])
})

test('up to three spaces of indentation are allowed', () => {
  deepEqual(extras.scanFences(['   ```', 'x', '   ```']), [true, true, true])
  deepEqual(extras.scanFences(['    ```', 'x']), [false, false])
})

test('codeBlocks reads info strings, including attribute shorthand', () => {
  const blocks = extras.codeBlocks([
    '```js title="x"',
    'const a = 1',
    '```',
    '```{.PYTHON}',
    'print(1)',
    '```',
    '```c++{1,3}',
    'int x;',
    '```',
    '```',
    'plain',
    '```'
  ])
  deepEqual(blocks.map(block => block.language), ['js', 'python', 'c++', ''])
  assert.equal(blocks[0].code, 'const a = 1')
  assert.equal(blocks[0].startLine, 0)
  assert.equal(blocks[0].endLine, 2)
})

test('an unclosed code block ends at the last line', () => {
  const blocks = extras.codeBlocks(['before', '```sh', 'echo hi'])
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].startLine, 1)
  assert.equal(blocks[0].endLine, 2)
  assert.equal(blocks[0].language, 'sh')
  assert.equal(blocks[0].code, 'echo hi')
})

test('codeBlocks ignores a fence inside a blockquote', () => {
  const blocks = extras.codeBlocks(['> ```', '> code', '> ```', '```go', 'x', '```'])
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].startLine, 3)
  assert.equal(blocks[0].language, 'go')
})

test('parseFootnotes keeps multi-line, indented and blank-separated text', () => {
  const parsed = extras.parseFootnotes([
    'body[^a]',
    '',
    '[^a]: first line',
    '  continued line',
    '',
    '  after a blank',
    'outside'
  ])
  deepEqual(parsed.definitions, [{
    label: 'a',
    text: 'first line\ncontinued line\n\nafter a blank',
    startLine: 2,
    endLine: 5
  }])
  deepEqual(parsed.skip, [false, false, true, true, true, true, false])
})

test('a blank line followed by unindented text ends the definition', () => {
  const parsed = extras.parseFootnotes(['[^a]: text', '', 'next paragraph'])
  assert.equal(parsed.definitions[0].endLine, 0)
  deepEqual(parsed.skip, [true, false, false])
})

test('CRLF definition lines parse without a stray carriage return', () => {
  const parsed = extras.parseFootnotes(['[^a]: first\r', '  second\r'])
  assert.equal(parsed.definitions[0].text, 'first\nsecond')
})

test('parseFootnotes does not scan inside fences', () => {
  const parsed = extras.parseFootnotes(['```', '[^a]: not a note', '```'])
  deepEqual(parsed.definitions, [])
  deepEqual(parsed.skip, [false, false, false])
})

test('labels cannot contain whitespace', () => {
  const parsed = extras.parseFootnotes(['[^a b]: nope'])
  deepEqual(parsed.definitions, [])
})

test('hasFootnoteRefs ignores inline code and definitions', () => {
  assert.equal(extras.hasFootnoteRefs('text[^a]'), true)
  assert.equal(extras.hasFootnoteRefs('`[^a]`'), false)
  assert.equal(extras.hasFootnoteRefs('[^a]: definition only'), false)
  assert.equal(extras.hasFootnoteRefs('\\[^a]'), false)
})

test('footnote numbers follow first references, then unused definitions', () => {
  const lines = ['b[^two] a[^one]', '[^one]: first', '[^two]: second', '[^unused]: kept']
  const parsed = extras.parseFootnotes(lines)
  const numbered = extras.footnoteNumbers(lines, parsed.definitions, parsed.skip)
  deepEqual(numbered.numbers, { two: 1, one: 2, unused: 3 })
  deepEqual(numbered.order, ['two', 'one', 'unused'])
})

test('references in fenced or inline code are not numbered', () => {
  const lines = ['`[^a]`', '```', '[^b]', '```', 'real[^c]', '[^a]: x', '[^b]: y', '[^c]: z']
  const parsed = extras.parseFootnotes(lines)
  const numbered = extras.footnoteNumbers(lines, parsed.definitions, parsed.skip)
  deepEqual(numbered.order, ['c', 'a', 'b'])
})

test('an unknown reference is not numbered', () => {
  const lines = ['text[^missing]', '[^known]: x']
  const parsed = extras.parseFootnotes(lines)
  const numbered = extras.footnoteNumbers(lines, parsed.definitions, parsed.skip)
  deepEqual(numbered.numbers, { known: 1 })
})

test('definitionListAt recognises : and ~ groups with multiple definitions', () => {
  const block = extras.definitionListAt(['Term', ': one', '~ two', 'Other', ': three'], 0)
  deepEqual(block, {
    startLine: 0,
    endLine: 4,
    groups: [
      { term: 'Term', definitions: ['one', 'two'] },
      { term: 'Other', definitions: ['three'] }
    ]
  })
})

test('a blank line splits definition-list blocks', () => {
  const lines = ['One', ': first', '', 'Two', ': second']
  const block = extras.definitionListAt(lines, 0)
  assert.equal(block.endLine, 1)
  assert.equal(block.groups.length, 1)
  assert.equal(extras.definitionListAt(lines, 3).groups[0].term, 'Two')
})

test('definition-list terms cannot start with a block marker', () => {
  assert.equal(extras.definitionListAt(['# Heading', ': x'], 0), null)
  assert.equal(extras.definitionListAt(['> quote', ': x'], 0), null)
  assert.equal(extras.definitionListAt(['- item', ': x'], 0), null)
  assert.equal(extras.definitionListAt(['1. item', ': x'], 0), null)
  assert.equal(extras.definitionListAt(['```', ': x'], 0), null)
  assert.equal(extras.definitionListAt(['[^a]: note', ': x'], 0), null)
})

test('definitionListAt needs a definition line immediately below the term', () => {
  assert.equal(extras.definitionListAt(['Term', '', ': text'], 0), null)
  assert.equal(extras.definitionListAt(['Term', 'plain'], 0), null)
})

test('definitionListAt trims edges but keeps inline markup in terms', () => {
  const block = extras.definitionListAt(['  *Term*  ', ': one   ', '~  two  '], 0)
  deepEqual(block.groups, [{ term: '*Term*', definitions: ['one', 'two'] }])
})

test('footnoteSectionHtml emits entries only, leaving the rule to QML', () => {
  const html = extras.footnoteSectionHtml([
    { label: 'a', number: 1, text: 'first' },
    { label: 'b', number: 2, text: 'second' }
  ], value => '<b>' + value + '</b>')
  assert.match(html, /^<p style="margin-top:10px; font-size:90%"><sup>1<\/sup> <b>first<\/b><br>/)
  assert.match(html, /<sup>2<\/sup> <b>second<\/b><\/p>$/)
  assert.doesNotMatch(html, /\u2014|<hr/i)
  assert.equal(extras.footnoteSectionHtml([], value => value), '')
})
