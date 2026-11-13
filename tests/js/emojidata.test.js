'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, deepEqual, plain } = require('./helpers/load')

const emoji = load('EmojiData.js')

test('all returns a stable, non-empty catalogue', () => {
  assert.equal(emoji.all().length, 176)
  assert.equal(emoji.all()[0].glyph, '😀')
})

test('filter matches names case-insensitively', () => {
  const lower = emoji.filter('smile')
  const upper = emoji.filter('SMILE')
  assert.equal(lower.length, 4)
  deepEqual(upper.map(item => item.glyph), plain(lower.map(item => item.glyph)))
})

test('filter matches keywords', () => {
  const matches = emoji.filter('country')
  assert.equal(matches.length, 9)
  assert.ok(matches.every(item => /flag$/i.test(item.name)))
})

test('an empty query returns the whole catalogue', () => {
  assert.equal(emoji.filter('').length, emoji.all().length)
  assert.equal(emoji.filter('   ').length, emoji.all().length)
  assert.equal(emoji.filter(null).length, emoji.all().length)
})

test('a query with no matches returns an empty list', () => {
  deepEqual(emoji.filter('zzzz-nope'), [])
})
