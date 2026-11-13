'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { ROOT, deepEqual } = require('./helpers/load')
const { CodeHighlight, PALETTE } = require('./helpers/render')

const GOLDEN = path.join(ROOT, 'tests', 'js', 'golden', 'code')
const LANGUAGES = [
  'javascript', 'python', 'bash', 'json', 'yaml', 'html', 'css', 'sql',
  'rust', 'c', 'go', 'markdown', 'diff'
]
const CANONICAL = LANGUAGES.concat(['typescript']).sort()

function read (name) {
  return fs.readFileSync(path.join(GOLDEN, name), 'utf8')
}

// Undo the escaping and drop the wrappers: what remains must be the source
// byte for byte, including newlines and a trailing newline.
function sourceOf (html) {
  return html
    .replace(/<span style="[^"]*">/g, '')
    .replace(/<\/span>/g, '')
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
}

test('golden highlighting for every supported language', () => {
  for (const language of LANGUAGES) {
    const source = read(language + '.txt')
    assert.equal(CodeHighlight.toHtml(source, language, PALETTE), read(language + '.html'), language)
  }
})

test('source survives highlighting exactly for every language', () => {
  for (const language of LANGUAGES) {
    const source = read(language + '.txt')
    assert.equal(sourceOf(CodeHighlight.toHtml(source, language, null)), source, language)
  }
})

test('unknown and empty languages stay plain escaped text', () => {
  for (const language of ['', 'nonsense', null, undefined]) {
    assert.equal(CodeHighlight.toHtml('<b> & "x"</b>', language, null), '&lt;b&gt; &amp; &quot;x&quot;&lt;/b&gt;')
  }
})

test('empty input, CRLF and non-ASCII are preserved', () => {
  assert.equal(CodeHighlight.toHtml('', 'js', null), '')
  const crlf = 'var x = 1\r\nif (x) {\r\n  return "héllo"\r\n}\r\n'
  assert.equal(sourceOf(CodeHighlight.toHtml(crlf, 'js', null)), crlf)
  const unicode = 'const café = "naïve" // 日本語\n'
  assert.equal(sourceOf(CodeHighlight.toHtml(unicode, 'javascript', null)), unicode)
})

test('language aliases and case normalise to canonical keys', () => {
  assert.equal(CodeHighlight.normaliseLanguage('js'), 'javascript')
  assert.equal(CodeHighlight.normaliseLanguage('JSX'), 'javascript')
  assert.equal(CodeHighlight.normaliseLanguage('c++'), 'c')
  assert.equal(CodeHighlight.normaliseLanguage('yml'), 'yaml')
  assert.equal(CodeHighlight.normaliseLanguage('.py'), 'python')
  assert.equal(CodeHighlight.normaliseLanguage('nonsense'), '')
  deepEqual(CodeHighlight.languages().sort(), CANONICAL)
})

test('palette overrides take effect and keywords stay bold', () => {
  const html = CodeHighlight.toHtml('if (ready) {}', 'javascript', { keyword: '#ff0000' })
  assert.match(html, /<span style="color:#ff0000; font-weight:bold">if<\/span>/)
  const fallback = CodeHighlight.toHtml('if (ready) {}', 'javascript', { keyword: 'not a colour' })
  assert.match(fallback, /color:#c792ea; font-weight:bold/)
})

test('a span can never overlap or straddle another span', () => {
  const html = CodeHighlight.toHtml('const s = "a // not a comment"', 'js', null)
  assert.match(html, /<span style="color:#a3d17a">&quot;a \/\/ not a comment&quot;<\/span>/)
  assert.equal((html.match(/<span/g) || []).length, (html.match(/<\/span>/g) || []).length)
})

test('unclosed multi-line comments and strings do not throw', () => {
  assert.doesNotThrow(() => CodeHighlight.toHtml('/* never closed', 'c', null))
  assert.match(CodeHighlight.toHtml('/* never closed', 'c', null), /color:#6b7280/)
  assert.doesNotThrow(() => CodeHighlight.toHtml('"""never closed', 'python', null))
  assert.match(CodeHighlight.toHtml('"""never closed', 'python', null), /color:#a3d17a/)
  assert.doesNotThrow(() => CodeHighlight.toHtml('<!-- never closed', 'html', null))
})

test('SQL keywords are case-insensitive and word boundaries hold', () => {
  const html = CodeHighlight.toHtml('Select notify FROM notes', 'sql', null)
  assert.match(html, />Select<\/span>/)
  assert.match(html, />FROM<\/span>/)
  assert.doesNotMatch(html, /<span[^>]*>notify/)
})
