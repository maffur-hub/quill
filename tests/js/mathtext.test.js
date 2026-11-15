'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { load, ROOT } = require('./helpers/load')
const { render, PALETTE } = require('./helpers/render')

const MathText = load('MathText.js')
const MathSyntax = load('MathSyntax.js')
const CodeHighlight = load('CodeHighlight.js')
const GOLDEN = path.join(ROOT, 'tests', 'js', 'golden', 'markdown')

function golden (name) {
  const markdown = fs.readFileSync(path.join(GOLDEN, name + '.md'), 'utf8')
  return {
    markdown,
    html: fs.readFileSync(path.join(GOLDEN, name + '.html'), 'utf8')
  }
}

test('raw HTML allowlist golden: kbd, mark, del and ins', () => {
  const pair = golden('kbd')
  assert.equal(render(pair.markdown), pair.html)
})

test('kbd becomes a key-cap span with the default colours', () => {
  const html = MathText.toHtml('<kbd>Ctrl</kbd>', null, MathSyntax)
  assert.equal(html, '<p style="margin-top:7px; margin-bottom:0px">'
    + '<span style="background-color:#2a2d31; color:#e6e6e6">Ctrl</span></p>')
})

test('a custom kbd palette changes both colours', () => {
  const html = MathText.toHtml('<kbd>Ctrl</kbd>', null, MathSyntax, {
    palette: { kbdBackground: '#123456', kbdText: '#ABCDEF' }
  })
  assert.match(html, /<span style="background-color:#123456; color:#abcdef">Ctrl<\/span>/)
})

test('an invalid kbd palette falls back to the default pair as a unit', () => {
  for (const palette of [
    { kbdBackground: 'red', kbdText: '#abcdef' },
    { kbdBackground: '#123456', kbdText: 'not-a-colour' },
    { kbdBackground: '#123456' },
    {}
  ]) {
    const html = MathText.toHtml('<kbd>Ctrl</kbd>', null, MathSyntax, { palette })
    assert.match(html, /<span style="background-color:#2a2d31; color:#e6e6e6">Ctrl<\/span>/)
  }
})

test('kbd content still goes through the inline formatting pipeline', () => {
  const html = MathText.toHtml('<kbd>**Ctrl** `C` & \\*</kbd>', null, MathSyntax)
  assert.match(html,
    /<span style="background-color:#2a2d31; color:#e6e6e6"><b>Ctrl<\/b> <tt>C<\/tt> &amp; \*<\/span>/)
})

test('nested blockquote golden', () => {
  const pair = golden('nested-quote')
  assert.equal(render(pair.markdown), pair.html)
})

test('highlighted fenced code golden', () => {
  const pair = golden('highlighted-code')
  assert.equal(render(pair.markdown), pair.html)
})

test('footnotes golden: links, numbering and the trailing section', () => {
  const pair = golden('footnotes')
  assert.equal(render(pair.markdown), pair.html)
})

test('definition lists render as a readable structure dump in the golden pipeline', () => {
  // No deflist.html golden: Qt RichText flattens <dl>, so the renderer proves
  // grouping with a deterministic text dump of the parsed block instead.
  const markdown = fs.readFileSync(path.join(GOLDEN, 'deflist.md'), 'utf8')
  assert.equal(render(markdown),
    '[deflist] Term :: First definition. | Second definition.\n'
    + '[deflist] Other term :: Tilde definition.')
})

test('task list golden', () => {
  const pair = golden('tasks')
  assert.equal(render(pair.markdown), pair.html)
})

test('rejected raw HTML stays escaped literal text', () => {
  const script = MathText.toHtml('<script>alert(1)</script>', null, MathSyntax)
  assert.match(script, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/)
  assert.doesNotMatch(script, /<script/)

  const handler = MathText.toHtml('<kbd onclick="x">K</kbd>', null, MathSyntax)
  assert.match(handler, /&lt;kbd onclick=&quot;x&quot;&gt;K&lt;\/kbd&gt;/)
  assert.doesNotMatch(handler, /<kbd/)

  const unbalanced = MathText.toHtml('<kbd>open', null, MathSyntax)
  assert.match(unbalanced, /&lt;kbd&gt;open/)
  assert.doesNotMatch(unbalanced, /<kbd>/)
})

test('the simple tags pair only with themselves', () => {
  const html = MathText.toHtml('<b>bold</b> <i>it</i> <code>x</code>', null, MathSyntax)
  assert.match(html, /<b>bold<\/b> <i>it<\/i> <code>x<\/code>/)
  const stray = MathText.toHtml('<b>bold<i>both</b></i>', null, MathSyntax)
  assert.doesNotMatch(stray, /<b>/)
})

test('br and br/ become a void RichText br', () => {
  const html = MathText.toHtml('a<br>b<br/>c<br />d', null, MathSyntax)
  assert.match(html, /a<br>b<br>c<br>d/)
})

test('footnote references use the supplied numbers and keep unknown labels', () => {
  const html = MathText.toHtml('one[^a] two[^missing] `[^a]`', null, MathSyntax, {
    footnotes: { numbers: { a: 3 } }
  })
  assert.match(html, /one<a href="#fn-a" name="fnref-a"><sup>3<\/sup><\/a>/)
  assert.match(html, /two\[\^missing\]/)
  assert.match(html, /<tt>\[\^a\]<\/tt>/)
})

test('fenced code without a highlighter stays escaped plain text', () => {
  const html = MathText.toHtml('```js\nconst x = 1 < 2\n```', null, MathSyntax)
  assert.match(html, /<pre style="margin-top:7px; margin-bottom:0">const x = 1 &lt; 2<\/pre>/)
  assert.doesNotMatch(html, /<span/)
})

test('fenced code with a highlighter inside a blockquote gains spans', () => {
  const html = MathText.toHtml('> ```js\n> const x = 1\n> ```', null, MathSyntax, {
    highlight: CodeHighlight,
    palette: PALETTE
  })
  assert.match(html, /<pre style="margin-top:7px; margin-bottom:0">/)
  assert.match(html, /<span style="color:#c792ea; font-weight:bold">const<\/span>/)
  assert.match(html, /<span style="color:#e0a458">1<\/span>/)
})

test('a fence or definition list inside a quote does not crash', () => {
  assert.doesNotThrow(() => MathText.toHtml('> ```\n> x\n> ```', null, MathSyntax))
  assert.doesNotThrow(() => MathText.toHtml('> Term\n> : definition', null, MathSyntax))
})

test('the existing span style colour path is unchanged', () => {
  const html = MathText.toHtml('<span style="color:#ff0000">red</span>', null, MathSyntax)
  assert.equal(html,
    '<p style="margin-top:7px; margin-bottom:0px"><span style="color:#ff0000">red</span></p>')
})

test('hasFormatting routes the new HTML and footnote syntax through RichText', () => {
  assert.equal(MathText.hasFormatting('<kbd>K</kbd>'), true)
  assert.equal(MathText.hasFormatting('<mark>K</mark>'), true)
  assert.equal(MathText.hasFormatting('<del>old</del>'), true)
  assert.equal(MathText.hasFormatting('text[^note]'), true)
  assert.equal(MathText.hasFormatting('> ```js'), true)
  assert.equal(MathText.hasFormatting('plain prose'), false)
})

test('an ordered list keeps the number it starts from', () => {
  const started = MathText.toHtml('5. five\n6. six', null, MathSyntax)
  assert.match(started, /^<ol start="5"/)
  const natural = MathText.toHtml('1. one\n2. two', null, MathSyntax)
  assert.match(natural, /^<ol/)
  assert.doesNotMatch(natural, /start=/)
})
