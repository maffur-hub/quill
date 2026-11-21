'use strict'

// Link destinations and note links must survive a write -> reparse -> re-edit
// round-trip: linkAt is the reparse authority for a Markdown destination (it
// stops at a newline, closes on a depth-0 `)` and skips `\x` escape pairs) and
// the store's WIKI_RE is the one for `[[Target|Alias]]` (no bracket, no
// newline anywhere in the construct). Whatever planLink/planNoteLink write has
// to be exactly what those readers read back.

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const MarkdownFormat = load('MarkdownFormat.js')
const { plan, linkAt } = MarkdownFormat

// Each accepted destination with the exact bytes planLink is expected to store.
const ACCEPTED = [
  {
    name: 'a clean destination is stored byte-identically',
    url: 'https://x.test/a',
    dest: 'https://x.test/a'
  },
  {
    name: 'an interior space is encoded as %20',
    url: 'https://x.test/a b',
    dest: 'https://x.test/a%20b'
  },
  {
    name: 'an unclosed paren is encoded as %28',
    url: 'https://x.test/a(b',
    dest: 'https://x.test/a%28b'
  },
  {
    name: 'an early close paren is encoded as %29',
    url: 'https://x.test/a)b',
    dest: 'https://x.test/a%29b'
  },
  {
    name: 'balanced parentheses stay raw',
    url: 'https://x.test/f(1)',
    dest: 'https://x.test/f(1)'
  },
  {
    name: 'a bare percent is encoded as %25',
    url: 'https://x.test/100%',
    dest: 'https://x.test/100%25'
  },
  {
    name: 'a legacy escaped paren stays raw',
    url: 'https://x.test/a\\)b',
    dest: 'https://x.test/a\\)b'
  },
  {
    name: 'a doubled backslash stays raw',
    url: 'https://x.test/a\\\\',
    dest: 'https://x.test/a\\\\'
  }
]

for (const row of ACCEPTED) {
  test('link destination: ' + row.name, () => {
    // Write: plan over a plain selection.
    const first = plan('see docs', 4, 8, 'link', row.url)
    assert.equal(first.ok, true, row.name + ': the destination is accepted')
    assert.equal(first.text, 'see [docs](' + row.dest + ')',
      row.name + ': the stored destination')

    // Reparse: linkAt is the authority the editor and preview use.
    const read = linkAt(first.text, first.selectionStart, first.selectionEnd)
    assert.ok(read, row.name + ': the written link is readable')
    assert.equal(read.url, row.dest, row.name + ': the re-read destination')

    // Re-edit: planning over the link with the re-read url is a no-op.
    const again = plan(first.text, read.labelStart, read.labelEnd, 'link', read.url)
    assert.equal(again.ok, true, row.name + ': the re-read url is accepted')
    assert.equal(again.text, first.text, row.name + ': write -> reparse -> re-edit is stable')
    const reread = linkAt(again.text, again.selectionStart, again.selectionEnd)
    assert.ok(reread, row.name + ': the re-edited link is readable')
    assert.equal(reread.url, read.url, row.name + ': the second re-read matches')
  })
}

test('editing an existing link encodes its new destination too', () => {
  const text = 'see [docs](https://x.test/a) now'
  const at = text.indexOf('docs')
  const result = plan(text, at, at + 4, 'link', 'https://x.test/a b')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'see [docs](https://x.test/a%20b) now')
  const read = linkAt(result.text, result.selectionStart, result.selectionEnd)
  assert.equal(read.url, 'https://x.test/a%20b')
  const again = plan(result.text, read.labelStart, read.labelEnd, 'link', read.url)
  assert.equal(again.text, result.text)
})

test('percent escapes already in a destination are not encoded twice', () => {
  const result = plan('see docs', 4, 8, 'link', 'https://x.test/My%20Notes')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'see [docs](https://x.test/My%20Notes)')
})

test('a destination with a line break is refused and nothing is applied', () => {
  const urls = [
    'https://x.test/a\nb',
    'https://x.test/a\rb',
    'https://x.test/a\r\nb'
  ]
  for (const url of urls) {
    const result = plan('see docs', 4, 8, 'link', url)
    assert.equal(result.ok, false, JSON.stringify(url) + ' is refused')
    assert.match(result.error, /line breaks/i)
    // A refusal carries no text: the editor has nothing to apply.
    assert.equal('text' in result, false)
    assert.equal('edits' in result, false)
  }
})

test('a destination ending in a lone backslash is refused and nothing is applied', () => {
  const result = plan('see docs', 4, 8, 'link', 'https://x.test/a\\')
  assert.equal(result.ok, false)
  assert.match(result.error, /backslash/i)
  assert.equal('text' in result, false)
})

test('an empty or whitespace link url is refused', () => {
  for (const url of ['', '   ']) {
    const result = plan('hello', 0, 5, 'link', url)
    assert.equal(result.ok, false)
    assert.match(result.error, /link URL/i)
    assert.equal('text' in result, false)
  }
})

test('a note link over a selection keeps the pick as target and the text as alias', () => {
  const result = plan('read later', 0, 10, 'noteLink', 'Meeting notes')
  assert.equal(result.ok, true)
  assert.equal(result.text, '[[Meeting notes|read later]]')
  // The alias is selected, so typing replaces the label in place.
  assert.equal(result.text.slice(result.selectionStart, result.selectionEnd), 'read later')
  assert.equal(result.selectionStart, '[[Meeting notes|'.length)
  const retyped = result.text.slice(0, result.selectionStart) + 'tomorrow'
    + result.text.slice(result.selectionEnd)
  assert.equal(retyped, '[[Meeting notes|tomorrow]]')
})

test('a note link at a caret is unchanged: the pick is the target', () => {
  const result = plan('hello world', 5, 5, 'noteLink', 'Weekly review')
  assert.equal(result.ok, true)
  assert.equal(result.text, 'hello[[Weekly review]] world')
  assert.equal(result.text.slice(result.selectionStart, result.selectionEnd), 'Weekly review')
  assert.deepEqual(
    { start: result.selectionStart, end: result.selectionEnd },
    { start: 7, end: 20 })
})

test('the caret form still folds a multi-line title and rejects an empty one', () => {
  const folded = plan('', 0, 0, 'noteLink', 'Two\r\nlines')
  assert.equal(folded.ok, true)
  assert.equal(folded.text, '[[Two lines]]')
  const empty = plan('', 0, 0, 'noteLink', '  ')
  assert.equal(empty.ok, false)
  assert.match(empty.error, /note title/i)
  const closing = plan('', 0, 0, 'noteLink', 'a]]b')
  assert.equal(closing.ok, false)
  assert.match(closing.error, /cannot contain \]\]/)
})

test('a paragraph-crossing selection keeps its label as one line', () => {
  const text = 'alpha\nbravo\n\ncharlie'
  const result = plan(text, 0, text.length, 'noteLink', 'Daily')
  assert.equal(result.ok, true)
  assert.equal(result.text, '[[Daily|alpha bravo charlie]]')
  assert.equal(result.text.slice(result.selectionStart, result.selectionEnd),
    'alpha bravo charlie')
})

test('a note link refuses a whitespace-only selection', () => {
  const result = plan('   ', 0, 3, 'noteLink', 'Meeting notes')
  assert.equal(result.ok, false)
  assert.match(result.error, /label/i)
  assert.equal('text' in result, false)
})

test('a note link refuses an alias containing a bracket', () => {
  for (const text of ['a]b', 'a[b', 'a]b[c']) {
    const result = plan(text, 0, text.length, 'noteLink', 'Meeting notes')
    assert.equal(result.ok, false, JSON.stringify(text) + ' is refused')
    assert.match(result.error, /label cannot contain/i)
    assert.equal('text' in result, false)
  }
})

test('a note link refuses a target containing ] [ or |', () => {
  const cases = [
    { value: 'A|B', error: /note title cannot contain/i },
    { value: 'A]B', error: /note title cannot contain/i },
    { value: 'A[B', error: /note title cannot contain/i }
  ]
  for (const row of cases) {
    const result = plan('read later', 0, 10, 'noteLink', row.value)
    assert.equal(result.ok, false, JSON.stringify(row.value) + ' is refused')
    assert.match(result.error, row.error)
    assert.equal('text' in result, false)
  }
})

test('a note link refuses a target containing # (heading split)', () => {
  const result = plan('read later', 0, 10, 'noteLink', 'C# notes')
  assert.equal(result.ok, false)
  assert.match(result.error, /cannot contain/)
  assert.equal('text' in result, false)
})

test('an empty note title is refused over a selection too', () => {
  const result = plan('read later', 0, 10, 'noteLink', '   ')
  assert.equal(result.ok, false)
  assert.match(result.error, /note title/i)
  assert.equal('text' in result, false)
})
