'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { load, plain, deepEqual, ROOT } = require('./helpers/load')

const PreviewBlocks = load('PreviewBlocks.js')
const ImageSizing = load('ImageSizing.js')
const TableEngine = load('TableEngine.js')
const MathSyntax = load('MathSyntax.js')
const MarkdownFormat = load('MarkdownFormat.js')
const MarkdownExtras = load('MarkdownExtras.js')

const deps = {
  image: ImageSizing,
  table: TableEngine,
  math: MathSyntax,
  format: MarkdownFormat,
  extras: MarkdownExtras
}

const GOLDEN = path.join(ROOT, 'tests', 'js', 'golden', 'markdown')

function kinds (blocks) {
  return blocks.map(block => block.kind)
}

test('block assembly matches the golden JSON for a mixed note', () => {
  const markdown = fs.readFileSync(path.join(GOLDEN, 'blocks.md'), 'utf8')
  const expected = JSON.parse(fs.readFileSync(path.join(GOLDEN, 'blocks.json'), 'utf8'))
  deepEqual(PreviewBlocks.build(markdown, deps), expected)
})

test('footnote definitions never leak into text, table or maths blocks', () => {
  const markdown = [
    'Body[^a].',
    '',
    '[^a]: A note with a table:',
    '  | X | Y |',
    '  | --- | --- |',
    '  | 1 | 2 |'
  ].join('\n')
  const blocks = plain(PreviewBlocks.build(markdown, deps))
  const text = blocks.filter(block => block.kind === 'text').map(block => block.text).join('\n')
  assert.doesNotMatch(text, /\[\^a\]:/)
  assert.doesNotMatch(text, /\| X \|/)
  assert.equal(blocks.filter(block => block.kind === 'table').length, 0)
  assert.equal(blocks.filter(block => block.kind === 'math').length, 0)
  deepEqual(blocks[blocks.length - 1], {
    kind: 'footnotes',
    items: [{ label: 'a', number: 1, text: 'A note with a table:\n| X | Y |\n| --- | --- |\n| 1 | 2 |' }],
    startLine: -1,
    endLine: -1
  })
})

test('a display-maths marker inside a definition is not a maths block', () => {
  const markdown = 'Body[^a].\n\n[^a]: first\n  $$\n  x\n  $$'
  const blocks = plain(PreviewBlocks.build(markdown, deps))
  assert.equal(blocks.filter(block => block.kind === 'math').length, 0)
  assert.match(blocks[0].text, /Body\[\^a\]/)
})

test('code lines never leak into text, images, tables or tasks', () => {
  const markdown = [
    'before',
    '',
    '```js',
    'const x = 1',
    '![not an image](x.png)',
    '| not | table |',
    '| --- | --- |',
    '- [ ] not a task',
    '```',
    '',
    'after'
  ].join('\n')
  const blocks = plain(PreviewBlocks.build(markdown, deps))
  deepEqual(kinds(blocks), ['text', 'code', 'text'])
  assert.equal(blocks[1].language, 'js')
  assert.match(blocks[1].code, /!\[not an image\]/)
  assert.match(blocks[1].code, /\[ \] not a task/)
  assert.equal(blocks.filter(block => block.kind === 'image').length, 0)
  assert.equal(blocks.filter(block => block.kind === 'table').length, 0)
  assert.equal(blocks.filter(block => block.kind === 'tasks').length, 0)
  assert.doesNotMatch(blocks[0].text, /const x/)
  assert.doesNotMatch(blocks[2].text, /const x/)
})

test('the footnotes block appears once, at the end, only with definitions', () => {
  const withNotes = plain(PreviewBlocks.build('One[^a].\n\n[^a]: note', deps))
  assert.equal(withNotes.filter(block => block.kind === 'footnotes').length, 1)
  assert.equal(withNotes[withNotes.length - 1].kind, 'footnotes')
  const withoutNotes = plain(PreviewBlocks.build('Just text', deps))
  assert.equal(withoutNotes.filter(block => block.kind === 'footnotes').length, 0)
})

test('unreferenced definitions are still numbered and rendered', () => {
  const blocks = plain(PreviewBlocks.build('Text[^used].\n\n[^used]: one\n[^unused]: two', deps))
  const notes = blocks[blocks.length - 1]
  deepEqual(notes.items.map(item => [item.label, item.number]), [['used', 1], ['unused', 2]])
})

test('fenced blocks survive as code blocks even when empty or unclosed', () => {
  const empty = plain(PreviewBlocks.build('```js\n```', deps))
  deepEqual(empty[0], { kind: 'code', language: 'js', code: '', startLine: 0, endLine: 1 })
  const open = plain(PreviewBlocks.build('```\nstill code', deps))
  deepEqual(open[0], { kind: 'code', language: '', code: 'still code', startLine: 0, endLine: 1 })
})

test('build tolerates entirely or partially missing deps', () => {
  assert.doesNotThrow(() => PreviewBlocks.build('hello\n\n```js\nx\n```', {}))
  const blocks = plain(PreviewBlocks.build('hello\n\n```js\nx\n```', {}))
  deepEqual(kinds(blocks), ['text'])
  const partial = plain(PreviewBlocks.build('```js\nx\n```', { extras: MarkdownExtras }))
  deepEqual(kinds(partial), ['code'])
  deepEqual(PreviewBlocks.build(undefined, {}), [])
})

test('hasMarkdownLink recognises Markdown and raw HTML links', () => {
  assert.equal(PreviewBlocks.hasMarkdownLink('[a](b)'), true)
  assert.equal(PreviewBlocks.hasMarkdownLink('<a href="b">a</a>'), true)
  assert.equal(PreviewBlocks.hasMarkdownLink('plain'), false)
})

test('markFences delegates to MarkdownExtras after a build', () => {
  PreviewBlocks.build('', deps)
  deepEqual(PreviewBlocks.markFences(['```', 'x', '```', 'y']), [true, true, true, false])
})
