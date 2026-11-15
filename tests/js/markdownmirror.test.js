'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, plain } = require('./helpers/load')

const mirror = load('MarkdownMirror.js')

// Fixed colours keep the assertions stable. The component resolves the same
// shape from the live theme in mirrorPalette().
const PALETTE = {
  foreground: '#e6e6e6',
  accent: '#7aa2f7',
  muted: 'rgba(230,230,230,0.52)',
  code: 'rgba(230,230,230,0.6)'
}
const ACCENT = '<span style="color:' + PALETTE.accent + ';">'
const MUTED = '<span style="color:' + PALETTE.muted + ';">'

function highlight (value) {
  return mirror.highlighted(value, PALETTE)
}

test('a heading keeps its marker spacing and colours the hashes separately', () => {
  assert.equal(highlight('##   Title'),
    ACCENT + '##</span>&nbsp;&nbsp;&nbsp;'
    + '<span style="color:#e6e6e6; font-weight:600;">Title</span>')
})

test('a bullet keeps its spacing and a task box is marked', () => {
  assert.equal(highlight('-   item'), ACCENT + '-</span>&nbsp;&nbsp;&nbsp;item')
  assert.equal(highlight('- [x] done'),
    '- <span style="color:#7aa2f7; font-weight:600;">[x]</span>&nbsp;done')
})

test('a bracket word after a bullet is not a task', () => {
  // Regression: "- [x]ylophone" used to be highlighted as a checked task.
  const html = highlight('- [x]ylophone')
  assert.equal(html, ACCENT + '-</span>&nbsp;[x]ylophone')
  assert.doesNotMatch(html, /font-weight:600/)
})

test('runs of spaces are protected; indentation protects every space', () => {
  assert.equal(highlight('a  b'), 'a&nbsp; b')
  assert.equal(highlight('    indented  x'),
    '&nbsp;&nbsp;&nbsp;&nbsp;indented&nbsp; x')
  assert.equal(highlight('\tindented  x'),
    '&nbsp;&nbsp;&nbsp;&nbsp;indented&nbsp; x')
})

test('whitelisted inline HTML is protected instead of escaped', () => {
  assert.equal(highlight('<sup>2</sup>'),
    MUTED + '&lt;sup&gt;</span><sup>2</sup>'
    + MUTED + '&lt;/sup&gt;</span>')
  assert.equal(highlight('<sub>x</sub>'),
    MUTED + '&lt;sub&gt;</span><sub>x</sub>'
    + MUTED + '&lt;/sub&gt;</span>')
  assert.equal(highlight('<u>u</u>'),
    MUTED + '&lt;u&gt;</span><u>u</u>'
    + MUTED + '&lt;/u&gt;</span>')
})

test('inline HTML inside backticks stays literal', () => {
  const html = highlight('`<sup>2</sup>`')
  assert.equal(html, ACCENT + '`&lt;sup&gt;2&lt;/sup&gt;`</span>')
  assert.doesNotMatch(html, /<sup>/)
})

test('fenced code uses the muted code colour and gets no inline formatting', () => {
  const html = highlight('```js\n**not bold**\n```')
  assert.equal(html,
    ACCENT + '```js</span><br/>'
    + '<span style="color:' + PALETTE.code + ';">**not bold**</span><br/>'
    + ACCENT + '```</span>')
  assert.doesNotMatch(html, /<b>/)
})

test('escapeHtml escapes ampersand, angle brackets and quote', () => {
  assert.equal(mirror.escapeHtml('& < > "'), '&amp; &lt; &gt; &quot;')
  assert.equal(mirror.escapeHtml(null), '')
  assert.equal(mirror.escapeHtml(undefined), '')
})

test('safeInlineSpanStyle accepts the whitelisted properties', () => {
  assert.deepEqual(
    plain(mirror.safeInlineSpanStyle(
      ' style="color: rgb(224, 62, 45); background-color: #FFF; font-size: 14px"')),
    [
      { key: 'color', value: '#e03e2d' },
      { key: 'background-color', value: '#ffffff' },
      { key: 'font-size', value: '14px' }
    ])
})

test('safeInlineSpanStyle rejects anything outside the allowlist', () => {
  for (const attributes of [
    ' style="color: red"',
    ' style="background-color: url(javascript:alert(1))"',
    ' style="font-size: 12"',
    ' style="text-align: center"',
    ' style="color: rgb(300, 0, 0)"',
    ' style="color: #fff" onclick="x"',
    'style="color: #fff"',
    ' style=""'
  ]) {
    assert.equal(mirror.safeInlineSpanStyle(attributes), null, attributes)
  }
})

test('inline Markdown still wraps its markers', () => {
  assert.equal(highlight('**bold**'),
    MUTED + '**</span><b>bold</b>' + MUTED + '**</span>')
  assert.equal(highlight('*italic*'),
    MUTED + '*</span><i>italic</i>' + MUTED + '*</span>')
  assert.equal(highlight('~~strike~~'),
    MUTED + '~~</span><s>strike</s>' + MUTED + '~~</span>')
  assert.equal(highlight('`code`'), ACCENT + '`code`</span>')
  assert.equal(highlight('==highlight=='),
    MUTED + '==</span>'
    + '<span style="background-color:#f5e663; color:#1f1f1f;">highlight</span>'
    + MUTED + '==</span>')
})

test('every colour comes from the supplied palette', () => {
  const html = mirror.highlighted('## T', {
    foreground: '#010203',
    accent: '#040506',
    muted: '#070809',
    code: '#0a0b0c'
  })
  assert.match(html, /color:#040506/)
  assert.match(html, /color:#010203/)
})
