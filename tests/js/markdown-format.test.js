'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, plain } = require('./helpers/load')

const MarkdownFormat = load('MarkdownFormat.js')
const { plan } = MarkdownFormat

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

test('bold on a caret between two bold runs inserts markers instead of merging them', () => {
  const result = plan('**a** then **b**', 10, 10, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, '**a** then**** **b**')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 12, end: 12 })
})

test('bold refuses a selection that spans several bold runs', () => {
  const result = plan('**a** and **b**', 0, 15, 'bold')
  assert.equal(result.ok, false)
})

test('bold on part of a bold run clears the whole run', () => {
  const result = plan('**foo bar**', 2, 8, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'foo bar')
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd }, { start: 0, end: 6 })
})

test('bold on a whole marked run clears it', () => {
  const result = plan('**foo** bar', 0, 7, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'foo bar')
})

test('italic on the content of a triple run leaves the bold layer', () => {
  const result = plan('***foo***', 3, 6, 'italic')
  assert.equal(result.ok, true)
  assert.equal(result.text, '**foo**')
})

test('italic refuses a selection that spans two italic runs', () => {
  const result = plan('*a* and *b*', 0, 11, 'italic')
  assert.equal(result.ok, false)
})

test('clear formatting keeps the contents of a code span literal', () => {
  const result = plan('`a*b*c`', 0, 7, 'clear')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'a*b*c')
})

test('clear formatting leaves spaced asterisks alone', () => {
  const result = plan('2 * 3 * 4', 0, 9, 'clear')
  assert.equal(result.ok, true)
  assert.equal(result.text, '2 * 3 * 4')
  assert.deepEqual(plain(result.edits), [])
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

test('a link destination with balanced parentheses is edited whole', () => {
  const text = 'see [Foo](https://en.wikipedia.org/wiki/Foo_(bar)) now'
  const caret = text.indexOf('Foo')
  assert.equal(load('MarkdownFormat.js').currentLinkURL(text, caret, caret),
    'https://en.wikipedia.org/wiki/Foo_(bar)')
  const result = plan(text, caret, caret + 3, 'link', 'https://x.test/Foo_(baz)')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'see [Foo](https://x.test/Foo_(baz)) now')
})

test('a second link is not confused with the first', () => {
  const text = '[one](a) and [two](b_(c))'
  const caret = text.indexOf('two')
  assert.equal(load('MarkdownFormat.js').currentLinkURL(text, caret, caret), 'b_(c)')
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

// ------------------------------------------------- inline marks and paragraphs
//
// A paragraph break ends the inline context: the preview renders an emphasis
// pair that straddles one as literal markers ("**alpha" then "beta**"), so a
// wrap that would write one is refused before anything reaches the note.

const INLINE_MARKS = ['bold', 'italic', 'underline', 'strike', 'code', 'highlight',
  'superscript', 'subscript']

test('an inline mark refuses to wrap a selection across a paragraph break', () => {
  for (const action of INLINE_MARKS) {
    const result = plan('alpha\n\nbeta', 0, 11, action)
    assert.equal(result.ok, false, action + ' is refused')
    assert.equal(result.error, 'Select within one paragraph', action)
    // A refusal carries no text: the editor has nothing to apply.
    assert.equal('text' in result, false, action + ' carries no text')
    assert.equal('edits' in result, false, action + ' carries no edits')
  }
})

test('a paragraph break with trailing spaces is still a paragraph break', () => {
  for (const action of INLINE_MARKS) {
    const result = plan('alpha\n \t\nbeta', 0, 13, action)
    assert.equal(result.ok, false, action + ' is refused')
    assert.equal(result.error, 'Select within one paragraph', action)
  }
})

test('an inline mark still wraps a selection across a soft break', () => {
  // The refusal is only for paragraph breaks: one line ending keeps one
  // paragraph, and the preview renders these marks across it.
  for (const action of INLINE_MARKS) {
    const result = plan('alpha\nbeta', 0, 10, action)
    assert.equal(result.ok, true, action + ' still wraps')
  }
})

test('switching an inline mark off across a paragraph break stays allowed', () => {
  // Removing markers cannot create content the renderer cannot read.
  const result = plan('**alpha\n\nbeta**', 2, 13, 'bold')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'alpha\n\nbeta')
})

// Colour and size spans are paragraph-scoped for the same reason: the editor
// underlay renders a span that straddles a paragraph break as escaped raw
// markup, so a wrap that would write one is refused like an inline mark.
// Spans that already cross a break (written before this refusal existed) stay
// editable: only the good-to-bad transition is refused, mirroring
// spanEditIsSafe's leave-alone rule for broken markup.

const COLOUR = 'rgb(224, 62, 45)'
const CROSSING = '<span style="color: ' + COLOUR + ';">alpha\n\nbeta</span>'

test('a colour span refuses to wrap a selection across a paragraph break', () => {
  // RED before this fix: returned ok with a span around the whole selection.
  const result = plan('alpha\n\nbeta', 0, 11, 'color', COLOUR)
  assert.equal(result.ok, false)
  assert.equal(result.error, 'Select within one paragraph')
  assert.equal('text' in result, false)
  assert.equal('edits' in result, false)
})

test('a size span refuses to wrap a selection across a paragraph break', () => {
  // RED before this fix: returned ok with a span around the whole selection.
  const result = plan('alpha\n\nbeta', 0, 11, 'size', 'large')
  assert.equal(result.ok, false)
  assert.equal(result.error, 'Select within one paragraph')
  assert.equal('text' in result, false)
})

test('a highlight span refuses to wrap a selection across a paragraph break', () => {
  // RED before this fix: returned ok with a background-colour span.
  const result = plan('alpha\n\nbeta', 0, 11, 'highlightColor', 'rgb(255, 255, 0)')
  assert.equal(result.ok, false)
  assert.equal(result.error, 'Select within one paragraph')
  assert.equal('text' in result, false)
})

test('a colour span refuses a break with trailing spaces', () => {
  // RED before this fix: the loose break matched nothing and a span was written.
  const result = plan('alpha\n \t\nbeta', 0, 13, 'color', COLOUR)
  assert.equal(result.ok, false)
  assert.equal(result.error, 'Select within one paragraph')
})

test('a colour span still applies within one paragraph', () => {
  // Pinned: passes before and after the paragraph-break refusal.
  const result = plan('alpha', 0, 5, 'color', COLOUR)
  assert.equal(result.ok, true)
  assert.equal(result.text, '<span style="color: ' + COLOUR + ';">alpha</span>')
})

test('a colour span still wraps across a soft break', () => {
  // Pinned: one line ending keeps one paragraph, so the refusal must not fire.
  const result = plan('alpha\nbeta', 0, 10, 'color', COLOUR)
  assert.equal(result.ok, true)
  assert.equal(result.text, '<span style="color: ' + COLOUR + ';">alpha\nbeta</span>')
})

test('an existing crossing span, fully selected, recolours in place', () => {
  // Pinned: the leave-alone clause keeps legacy crossing spans editable.
  const result = plan(CROSSING, 0, CROSSING.length, 'color', 'rgb(0, 0, 255)')
  assert.equal(result.ok, true)
  assert.equal(result.text, '<span style="color: rgb(0, 0, 255);">alpha\n\nbeta</span>')
  assert.equal((result.text.match(/<span /g) || []).length, 1)
  assert.deepEqual({ start: result.selectionStart, end: result.selectionEnd },
    { start: 0, end: result.text.length })
})

test('an existing crossing span, fully selected, clears via No colour', () => {
  // Pinned: removing a property cannot create an unrenderable span.
  const result = plan(CROSSING, 0, CROSSING.length, 'noColour', null)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'alpha\n\nbeta')
})

test('turning colour off across a paragraph break stays allowed', () => {
  // Pinned: value "" never inserts a span, so the guard must skip it entirely.
  const result = plan('alpha\n\nbeta', 0, 11, 'noColour', null)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'alpha\n\nbeta')
})

test('clear formatting over an existing crossing span still works', () => {
  // Pinned: planClear is untouched by the span wrap guard.
  const result = plan(CROSSING, 0, CROSSING.length, 'clear', null)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'alpha\n\nbeta')
})

// ------------------------------------------------------------------ headings

test('heading level 0 strips an ATX closing sequence', () => {
  const result = plan('## hi ##', 0, 8, 'heading', 0)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hi')
})

test('heading level 0 strips a closing sequence and its trailing spaces', () => {
  const result = plan('## hi ###   ', 0, 12, 'heading', 0)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hi')
})

test('setting a level on a closing-carrying heading rewrites it without the closer', () => {
  const result = plan('## hi ##', 0, 8, 'heading', 2)
  assert.equal(result.ok, true)
  assert.equal(result.text, '## hi')
  // Write then reparse: the line still reads back as the requested level.
  assert.equal(load('MarkdownFormat.js').headingPrefix(result.text).level, 2)
})

test('hashes without a preceding space are heading content, not a closer', () => {
  const result = plan('## hi##', 0, 7, 'heading', 0)
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hi##')
})

test('a box without a following space is not a task', () => {
  assert.equal(MarkdownFormat.parseTaskLine('- [x]ylophone'), null)
  assert.deepEqual(plain(MarkdownFormat.parseTaskLine('- [x] done')),
    { indent: 0, checked: true, content: 'done' })
  assert.deepEqual(plain(MarkdownFormat.parseTaskLine('- [x]')),
    { indent: 0, checked: true, content: '' })
})
