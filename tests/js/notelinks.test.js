'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual } = require('./helpers/load')

const links = load('NoteLinks.js')
const DATA = '/data/quill'

test('quill://note links carry a decoded note id', () => {
  deepEqual(links.classify('quill://note/Inbox%2Fa.md', 'x.md', DATA),
    { kind: 'note', value: 'Inbox/a.md' })
})

test('quill://missing and quill://tag carry their text', () => {
  deepEqual(links.classify('quill://missing/Foo%20Bar', 'x.md', DATA),
    { kind: 'missing', value: 'Foo Bar' })
  deepEqual(links.classify('quill://tag/well--known', 'x.md', DATA),
    { kind: 'tag', value: 'well--known' })
})

test('a relative link resolves against the note folder', () => {
  deepEqual(links.classify('Other.md', 'Inbox/a.md', DATA),
    { kind: 'note', value: 'Inbox/Other.md' })
  deepEqual(links.classify('./Other.md', 'Inbox/a.md', DATA),
    { kind: 'note', value: 'Inbox/Other.md' })
  deepEqual(links.classify('../B.md', 'Inbox/Deep/a.md', DATA),
    { kind: 'note', value: 'Inbox/B.md' })
  deepEqual(links.classify('b.md#section', 'a.md', DATA),
    { kind: 'note', value: 'b.md' })
})

test('an absolute link inside the notes root keeps its id', () => {
  deepEqual(links.classify(DATA + '/notes/Inbox/c.md', 'a.md', DATA),
    { kind: 'note', value: 'Inbox/c.md' })
})

test('links that leave the notes root stay external', () => {
  assert.equal(links.classify('../../escape.md', 'Inbox/a.md', DATA).kind, 'external')
  assert.equal(links.classify('/etc/passwd.md', 'a.md', DATA).kind, 'external')
  assert.equal(links.classify('~/notes.md', 'a.md', DATA).kind, 'external')
})

test('non-note targets stay external', () => {
  deepEqual(links.classify('https://example.com/x.md', 'a.md', DATA),
    { kind: 'external', value: 'https://example.com/x.md' })
  assert.equal(links.classify('images/pic.png', 'a.md', DATA).kind, 'external')
  assert.equal(links.classify(DATA + '/notes/../evil.md', 'a.md', DATA).kind, 'external')
})

test('anchors and empty links are not notes', () => {
  assert.equal(links.classify('#heading', 'a.md', DATA).kind, 'anchor')
  assert.equal(links.classify('   ', 'a.md', DATA).kind, 'empty')
})
