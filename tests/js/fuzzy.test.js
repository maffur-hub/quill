'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, plain } = require('./helpers/load')

const fuzzy = load('Fuzzy.js')

test('exact and prefix matches score above -1', () => {
  assert.ok(fuzzy.score('quick', 'Quick') > 0)
  assert.ok(fuzzy.score('qui', 'Quick Preview') > 0)
})

test('subsequence matches are allowed', () => {
  assert.ok(fuzzy.score('qk', 'Quick') > 0)
  assert.ok(fuzzy.score('qkpv', 'Quick Preview') > 0)
})

test('matching is case-insensitive', () => {
  assert.equal(fuzzy.score('QUICK', 'quick note'), fuzzy.score('quick', 'quick note'))
  assert.equal(fuzzy.score('QuIcK', 'QUICK NOTE'), fuzzy.score('quick', 'quick note'))
})

test('word starts outrank a match inside a word', () => {
  const entries = [{ title: 'Quadruple Pane' }, { title: 'Quick Preview' }]
  const ranked = fuzzy.rank(entries, 'qp', e => e.title)
  assert.equal(plain(ranked)[0].title, 'Quick Preview')
})

test('contiguous runs beat scattered characters', () => {
  assert.ok(fuzzy.score('abc', 'abcdef') > fuzzy.score('abc', 'a-b-c-d-e-f'))
})

test('a prefix beats a late match', () => {
  assert.ok(fuzzy.score('note', 'Note plan') > fuzzy.score('note', 'Plan a note'))
})

test('a short haystack beats a long one for the same match', () => {
  assert.ok(fuzzy.score('plan', 'Plan') > fuzzy.score('plan', 'Plan of the whole project archive'))
})

test('no match returns -1', () => {
  assert.equal(fuzzy.score('zzz', 'Quick Preview'), -1)
  assert.equal(fuzzy.score('quick', ''), -1)
})

test('word-start preference never loses a valid subsequence', () => {
  // "abZ" exists greedily (a-b-Z), but the boundary-preferring walk would
  // take the later "b" and run out of text.
  assert.ok(fuzzy.score('abZ', 'aXbZ b') > 0)
})

test('empty and whitespace queries return the entries unchanged', () => {
  const entries = ['b', 'a', 'c']
  assert.deepEqual(plain(fuzzy.rank(entries, '', null)), ['b', 'a', 'c'])
  assert.deepEqual(plain(fuzzy.rank(entries, '   ', null)), ['b', 'a', 'c'])
})

test('a trailing space does not stop the query matching', () => {
  assert.equal(fuzzy.score('quick ', 'Quick'), fuzzy.score('quick', 'Quick'))
  assert.deepEqual(plain(fuzzy.rank(['Plan', 'Quick'], 'qu ', null)), ['Quick'])
})

test('null and undefined inputs do not throw', () => {
  assert.equal(fuzzy.score(null, null), 0)
  assert.equal(fuzzy.score(undefined, 'text'), 0)
  assert.equal(fuzzy.score('x', null), -1)
  assert.deepEqual(plain(fuzzy.rank(null, 'x', null)), [])
  assert.deepEqual(plain(fuzzy.rank([null, { title: 'x' }], 'x', e => e && e.title)), [{ title: 'x' }])
})

test('rank does not mutate the input array', () => {
  const entries = [{ title: 'Quadruple Pane' }, { title: 'Quick Preview' }]
  const before = plain(entries)
  fuzzy.rank(entries, 'qp', e => e.title)
  assert.deepEqual(plain(entries), before)
})

test('rank is stable for equal scores', () => {
  const entries = [{ id: 1, title: 'Plan' }, { id: 2, title: 'Plan' }]
  const ranked = plain(fuzzy.rank(entries, 'plan', e => e.title))
  assert.deepEqual(ranked.map(e => e.id), [1, 2])
})
