'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual } = require('./helpers/load')

const syntax = load('MathSyntax.js')

test('inline $...$ produces one span with its TeX source', () => {
  const spans = syntax.inlineSpans('before $x^2$ after')
  assert.equal(spans.length, 1)
  deepEqual(spans[0], { start: 7, end: 12, tex: 'x^2' })
})

test('multiple inline spans are found independently', () => {
  const spans = syntax.inlineSpans('a $x$ b $y+1$')
  deepEqual(spans.map(span => span.tex), ['x', 'y+1'])
})

test('display $$...$$ is not an inline span', () => {
  deepEqual(syntax.inlineSpans('$$x^2$$'), [])
  assert.equal(syntax.hasInlineMath('$$x^2$$'), false)
})

test('display blocks are line-oriented and keep exact TeX', () => {
  const blocks = syntax.findDisplayBlocks(['$$', 'x^2', '$$', 'text', '$$y$$'])
  deepEqual(blocks, [
    { startLine: 0, endLine: 2, tex: 'x^2' },
    { startLine: 4, endLine: 4, tex: 'y' }
  ])
})

test('inline maths is excluded inside fenced code blocks', () => {
  const source = '```\n$x$\n$$\ny\n$$\n```'
  deepEqual(syntax.inlineSpans(source), [])
  deepEqual(syntax.findDisplayBlocks(source.split('\n')), [])
})

test('inline maths is excluded inside inline code', () => {
  deepEqual(syntax.inlineSpans('`$x$`'), [])
})

test('currency is not treated as maths', () => {
  deepEqual(syntax.inlineSpans('cost $5 and $6'), [])
})

test('currency followed by words or a range stays text', () => {
  deepEqual(syntax.inlineSpans('it costs $5 a month'), [])
  deepEqual(syntax.inlineSpans('range $5 - $6'), [])
  deepEqual(syntax.inlineSpans('total $1,200.50 for the lot'), [])
})

test('a formula that starts with digits may contain spaces', () => {
  const spans = syntax.inlineSpans('$2x + 3y = 7$')
  assert.equal(spans.length, 1)
  assert.equal(spans[0].tex, '2x + 3y = 7')
  deepEqual(syntax.inlineSpans('$2 + 2 = 4$').map(span => span.tex), ['2 + 2 = 4'])
})

test('escaped dollars are literal', () => {
  deepEqual(syntax.inlineSpans('\\$x$'), [])
})

test('\\( ... \\) is accepted as inline maths', () => {
  const spans = syntax.inlineSpans(' \\(x\\) ')
  assert.equal(spans.length, 1)
  assert.equal(spans[0].tex, 'x')
})

test('scan returns ordered text and maths tokens', () => {
  deepEqual(syntax.scan('a $x$ b'), [
    { type: 'text', text: 'a ' },
    { type: 'math', tex: 'x' },
    { type: 'text', text: ' b' }
  ])
})

test('hasInlineMath reports presence correctly', () => {
  assert.equal(syntax.hasInlineMath('plain text'), false)
  assert.equal(syntax.hasInlineMath('a $x$'), true)
})
