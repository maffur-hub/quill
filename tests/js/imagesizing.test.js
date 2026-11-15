'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual } = require('./helpers/load')

const sizing = load('ImageSizing.js')

test('a plain image line has no explicit size', () => {
  const parsed = sizing.splitLine('![alt](pic.png)')
  assert.equal(parsed.source, 'pic.png')
  assert.equal(parsed.alt, 'alt')
  assert.equal(parsed.width, null)
  assert.equal(parsed.height, null)
  assert.equal(parsed.hasSize, false)
})

test('{width=NNN} and the px suffix are both supported', () => {
  assert.equal(sizing.splitLine('![alt](pic.png){width=320}').width, 320)
  assert.equal(sizing.splitLine('![alt](pic.png){width=320px}').width, 320)
})

test('height-only and combined width/height forms are supported', () => {
  const heightOnly = sizing.splitLine('![alt](pic.png){height=200}')
  assert.equal(heightOnly.height, 200)
  assert.equal(heightOnly.width, null)
  const both = sizing.splitLine('![alt](pic.png){width=320 height=200}')
  assert.equal(both.width, 320)
  assert.equal(both.height, 200)
})

test('Obsidian |NNN alt width is read as a size', () => {
  const parsed = sizing.splitLine('![alt|320](pic.png)')
  assert.equal(parsed.width, 320)
  assert.equal(parsed.alt, 'alt')
  assert.equal(parsed.altRaw, 'alt|320')
})

test('angle-bracket sources may contain spaces', () => {
  const parsed = sizing.splitLine('![alt](<my pic.png>){width=100 height=50}')
  assert.equal(parsed.source, 'my pic.png')
  assert.equal(parsed.width, 100)
  assert.equal(parsed.height, 50)
})

test('non-image lines and inline images are not image blocks', () => {
  assert.equal(sizing.splitLine('text ![x](y)'), null)
  assert.equal(sizing.splitLine('plain text'), null)
})

test('splitBlocks separates image-only lines from text', () => {
  const blocks = sizing.splitBlocks('text\n![a](b.png)\nmore')
  deepEqual(blocks.map(block => block.kind), ['text', 'image', 'text'])
  assert.equal(blocks[1].source, 'b.png')
  assert.equal(blocks[1].line, 1)
})

test('displayFor resolves an explicit width against the pane', () => {
  const size = sizing.splitLine('![a](b.png){width=320}')
  deepEqual(sizing.displayFor(size, 500, 2), { mode: 'width', width: 320, height: 160 })
  deepEqual(sizing.displayFor(size, 200, 2), { mode: 'width', width: 200, height: 100 })
})

test('displayFor returns null without a size', () => {
  assert.equal(sizing.displayFor(sizing.splitLine('![a](b.png)'), 500, 2), null)
})

test('setWidth rewrites the suffix and normalises Obsidian width', () => {
  assert.equal(sizing.setWidth('![alt](pic.png)', 400), '![alt](pic.png){width=400}')
  assert.equal(sizing.setWidth('![alt|320](pic.png)', 400), '![alt](pic.png){width=400}')
  assert.equal(sizing.setWidth('not an image', 400), null)
})

test('clearSize removes brace and Obsidian sizes', () => {
  assert.equal(sizing.clearSize('![alt](pic.png){width=320}'), '![alt](pic.png)')
  assert.equal(sizing.clearSize('![alt|320](pic.png)'), '![alt](pic.png)')
  assert.equal(sizing.clearSize('not an image'), null)
})

test('a pipe in the alt text is not mistaken for an Obsidian width', () => {
  const parsed = sizing.splitLine('![Chart | 2024](pic.png)')
  assert.equal(parsed.hasSize, false)
  assert.equal(parsed.alt, 'Chart | 2024')
  assert.equal(sizing.setWidth('![Chart | 2024](pic.png)', 320), '![Chart | 2024](pic.png){width=320}')
  assert.equal(sizing.clearSize('![Chart | 2024](pic.png)'), '![Chart | 2024](pic.png)')
})
