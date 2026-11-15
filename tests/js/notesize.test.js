'use strict'

// Byte sizes must agree with Python's len(body.encode("utf-8")), because the
// store enforces MAX_NOTE_BYTES on that value. The mixed-string expectations
// below were checked against Python directly.

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const size = load('NoteSize.js')

test('null and undefined have no bytes', () => {
  assert.equal(size.utf8Length(null), 0)
  assert.equal(size.utf8Length(undefined), 0)
})

test('the empty string and ASCII count one byte per character', () => {
  assert.equal(size.utf8Length(''), 0)
  assert.equal(size.utf8Length('abc'), 3)
  assert.equal(size.utf8Length('a b\n\t~'), 6)
})

test('two-, three- and four-byte characters match Python', () => {
  assert.equal(size.utf8Length('é'), 2) // U+00E9
  assert.equal(size.utf8Length('€'), 3) // U+20AC
  assert.equal(size.utf8Length('漢'), 3) // CJK
  assert.equal(size.utf8Length('𝄞'), 4) // U+1D11E, a surrogate pair
  assert.equal(size.utf8Length('\u07FF'), 2)
  assert.equal(size.utf8Length('\u0800'), 3)
})

test('mixed strings add up to Python byte counts', () => {
  assert.equal(size.utf8Length('é€𝄞'), 9) // 2 + 3 + 4
  assert.equal(size.utf8Length('Ünïcodé'), 10)
  assert.equal(size.utf8Length('日本語のテキスト'), 24)
  assert.equal(size.utf8Length('café — €5 🎉'), 19)
  assert.equal(size.utf8Length('a𝄞b'), 6)
})

test('surrogate pairs count four bytes and lone surrogates three', () => {
  assert.equal(size.utf8Length('\uD834\uDD1E'), 4)
  assert.equal(size.utf8Length('\uD834'), 3)
  assert.equal(size.utf8Length('\uDD1E'), 3)
  assert.equal(size.utf8Length('\uD834a'), 4)
  assert.equal(size.utf8Length('a\uDD1E'), 4)
})

test('non-string values are converted with String', () => {
  assert.equal(size.utf8Length(123), 3)
  assert.equal(size.utf8Length(true), 4)
})

test('a body of exactly limit bytes is already over the limit', () => {
  for (const value of ['abc', 'é€𝄞', 'café — €5 🎉']) {
    const bytes = size.utf8Length(value)
    assert.equal(size.exceeds(value, bytes), true, value)
    assert.equal(size.exceeds(value, bytes + 1), false, value)
  }
})

test('the empty string never exceeds, even at limit zero', () => {
  assert.equal(size.exceeds('', 0), false)
  assert.equal(size.exceeds('', 100), false)
  assert.equal(size.exceeds('a', 0), true)
})

test('a huge body trips a small limit without counting it all', () => {
  const huge = 'x'.repeat(2000000)
  assert.equal(size.utf8Length(huge), 2000000)
  assert.equal(size.exceeds(huge, 1000), true)
  assert.equal(size.exceeds(huge, 2000000), true)
  assert.equal(size.exceeds(huge, 2000001), false)
})

test('a non-finite or negative limit means no limit', () => {
  assert.equal(size.exceeds('abc', NaN), false)
  assert.equal(size.exceeds('abc', undefined), false)
  assert.equal(size.exceeds('abc', Infinity), false)
  assert.equal(size.exceeds('abc', -1), false)
  assert.equal(size.exceeds('abc', '-5'), false)
})

test('a numeric string is coerced as a limit', () => {
  assert.equal(size.exceeds('abc', '3'), true)
  assert.equal(size.exceeds('abc', '4'), false)
})
