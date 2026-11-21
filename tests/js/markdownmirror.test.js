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

// --------------------------------------------------- inline marks over a break
//
// A soft line break stays inside one paragraph, and the preview renders these
// marks across it. The underlay has to paint the same state on both lines or
// the styled text and the caret disagree about what is emphasised.
// (The preview does not render ==highlight== across a soft break, so the
// mirror keeps it per-line; the row below pins that agreement.)

test('italic carries across a soft line break', () => {
  assert.equal(highlight('*alpha\nbeta*'),
    MUTED + '*</span><i>alpha<br/>beta</i>' + MUTED + '*</span>')
})

test('bold carries across a soft line break, even mid-line', () => {
  assert.equal(highlight('one **alpha\nbeta** two'),
    'one ' + MUTED + '**</span><b>alpha<br/>beta</b>' + MUTED + '**</span> two')
})

test('strike and code carry across a soft line break', () => {
  assert.equal(highlight('~~alpha\nbeta~~'),
    MUTED + '~~</span><s>alpha<br/>beta</s>' + MUTED + '~~</span>')
  assert.equal(highlight('`alpha\nbeta`'),
    ACCENT + '`alpha<br/>beta`</span>')
})

test('the tag marks carry across a soft line break', () => {
  assert.equal(highlight('<u>alpha\nbeta</u>'),
    MUTED + '&lt;u&gt;</span><u>alpha<br/>beta</u>' + MUTED + '&lt;/u&gt;</span>')
  assert.equal(highlight('<sup>alpha\nbeta</sup>'),
    MUTED + '&lt;sup&gt;</span><sup>alpha<br/>beta</sup>'
    + MUTED + '&lt;/sup&gt;</span>')
})

test('a highlight does not carry across a soft line break', () => {
  // The preview leaves the markers literal here, so the underlay must too.
  assert.equal(highlight('==alpha\nbeta=='), '==alpha<br/>beta==')
})

test('a blank line ends the carried state', () => {
  assert.equal(highlight('*alpha\n\nbeta*'), '*alpha<br/><br/>beta*')
})

test('carried state never leaks into or out of a fenced block', () => {
  const html = highlight('**open\n```\nclose**\n```')
  assert.doesNotMatch(html, /<b>/)
  assert.match(html, /close\*\*/)
})

// ------------------------------------------------------------ span font size
//
// MarkdownFormat stores a size as font-size on the span; the underlay painted
// the colour and dropped the size, so S/L/XL read differently in the editor
// and the preview.

test('a span font-size reaches the painted style', () => {
  const html = highlight('<span style="color: rgb(224, 62, 45); font-size: 18px;">big</span>')
  assert.match(html, /<span style="color:#e03e2d; font-size: 18px;">big<\/span>/)
})

test('the painted font-size comes from the span, not a size table', () => {
  const html = highlight('<span style="font-size: 17px;">big</span>')
  assert.match(html, /font-size: 17px/)
  assert.doesNotMatch(html, /font-size: 18px/)
})

test('an out-of-range font-size is still dropped', () => {
  const html = highlight('<span style="font-size: 999px;">big</span>')
  // The span is not whitelisted, so its tag text stays literal (escaped) and
  // no painted span carries the size.
  assert.doesNotMatch(html, /<span style="[^"]*font-size:\s*999px/)
})

test('the painted span style reads back through the same validator', () => {
  const html = highlight('<span style="color: rgb(224, 62, 45); font-size: 18px;">big</span>')
  const painted = html.match(/<span style="(color:[^"]*font-size:[^"]*)">/)
  assert.ok(painted, html)
  const props = plain(mirror.safeInlineSpanStyle(' style="' + painted[1] + '"'))
  assert.deepEqual(props, [
    { key: 'color', value: '#e03e2d' },
    { key: 'font-size', value: '18px' }
  ])
})
