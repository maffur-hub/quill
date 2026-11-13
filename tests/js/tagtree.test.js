'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load, plain } = require('./helpers/load')

const tree = load('TagTree.js')

function node (path, label, depth, count, direct, isLeaf) {
  return { path, label, depth, count, direct, isLeaf }
}

test('a single tag becomes one selectable leaf', () => {
  assert.deepEqual(plain(tree.build([{ tag: 'a', count: 2 }])), [
    node('a', 'a', 0, 2, 2, true)
  ])
})

test('nested tags aggregate counts and expose their depth', () => {
  const nodes = plain(tree.build([
    { tag: 'a', count: 1 },
    { tag: 'a/b', count: 2 },
    { tag: 'a/b/c', count: 3 }
  ]))
  assert.deepEqual(nodes, [
    node('a', 'a', 0, 6, 1, true),
    node('a/b', 'b', 1, 5, 2, true),
    node('a/b/c', 'c', 2, 3, 3, true)
  ])
})

test('a prefix that is not a tag is a pure parent', () => {
  assert.deepEqual(plain(tree.build([{ tag: 'work/projects', count: 4 }])), [
    node('work', 'work', 0, 4, 0, false),
    node('work/projects', 'projects', 1, 4, 4, true)
  ])
})

test('siblings sort case-insensitively, parents before children', () => {
  const nodes = plain(tree.build([
    { tag: 'zeta', count: 1 },
    { tag: 'Alpha', count: 1 },
    { tag: 'beta', count: 1 },
    { tag: 'alpha/child', count: 1 }
  ]))
  assert.deepEqual(nodes.map(entry => entry.path), [
    'Alpha', 'alpha', 'alpha/child', 'beta', 'zeta'
  ])
})

test('a tag can be both a leaf and a parent', () => {
  const nodes = plain(tree.build([
    { tag: 'a', count: 2 },
    { tag: 'a/b', count: 3 }
  ]))
  assert.deepEqual(nodes, [
    node('a', 'a', 0, 5, 2, true),
    node('a/b', 'b', 1, 3, 3, true)
  ])
})

test('a three-level tree flattens depth-first with sorted children', () => {
  const nodes = plain(tree.build([
    { tag: 'a/b/c', count: 2 },
    { tag: 'a/b/d', count: 3 },
    { tag: 'a/e', count: 4 }
  ]))
  assert.deepEqual(nodes, [
    node('a', 'a', 0, 9, 0, false),
    node('a/b', 'b', 1, 5, 0, false),
    node('a/b/c', 'c', 2, 2, 2, true),
    node('a/b/d', 'd', 2, 3, 3, true),
    node('a/e', 'e', 1, 4, 4, true)
  ])
})

test('prefixMatches matches exactly or on a segment boundary', () => {
  assert.equal(tree.prefixMatches('a', 'a'), true)
  assert.equal(tree.prefixMatches('a/b', 'a'), true)
  assert.equal(tree.prefixMatches('a/b/c', 'a/b'), true)
  assert.equal(tree.prefixMatches('alpine', 'a'), false)
  assert.equal(tree.prefixMatches('ab', 'a'), false)
  assert.equal(tree.prefixMatches('a/b', 'a/b/c'), false)
})

test('prefixMatches is case-sensitive on the display string', () => {
  assert.equal(tree.prefixMatches('A/b', 'a'), false)
  assert.equal(tree.prefixMatches('a/b', 'A'), false)
  assert.equal(tree.prefixMatches('A/b', 'A'), true)
})

test('mixed string and object entries are accepted', () => {
  const nodes = plain(tree.build([
    'alpha',
    { tag: 'alpha/beta', count: 3 },
    { tag: 'gamma' }
  ]))
  assert.deepEqual(nodes, [
    node('alpha', 'alpha', 0, 4, 1, true),
    node('alpha/beta', 'beta', 1, 3, 3, true),
    node('gamma', 'gamma', 0, 1, 1, true)
  ])
})

test('duplicate tags aggregate their direct counts', () => {
  assert.deepEqual(plain(tree.build([
    { tag: 'a', count: 2 },
    { tag: 'a', count: 3 }
  ])), [
    node('a', 'a', 0, 5, 5, true)
  ])
})

test('empty input and empty segments are ignored', () => {
  assert.deepEqual(plain(tree.build([])), [])
  assert.deepEqual(plain(tree.build(null)), [])
  assert.deepEqual(plain(tree.build(['', '/', '//'])), [])
  assert.deepEqual(plain(tree.build(['', 'a'])), [
    node('a', 'a', 0, 1, 1, true)
  ])
})

test('segments drops empty path pieces', () => {
  assert.deepEqual(plain(tree.segments('a//b/c/')), ['a', 'b', 'c'])
  assert.deepEqual(plain(tree.segments('')), [])
  assert.deepEqual(plain(tree.segments(null)), [])
})

test('tag names that look like object properties are ordinary nodes', () => {
  assert.deepEqual(plain(tree.build([
    { tag: '__proto__', count: 1 },
    { tag: 'constructor/deep', count: 2 }
  ])), [
    node('__proto__', '__proto__', 0, 1, 1, true),
    node('constructor', 'constructor', 0, 2, 0, false),
    node('constructor/deep', 'deep', 1, 2, 2, true)
  ])
})

test('countFor sums the whole subtree and ignores lookalikes', () => {
  const tags = [
    { tag: 'a', count: 2 },
    { tag: 'a/b', count: 3 },
    { tag: 'alpine', count: 4 },
    { tag: 'A/b', count: 5 }
  ]
  assert.equal(tree.countFor(tags, 'a'), 5)
  assert.equal(tree.countFor(tags, 'a/b'), 3)
  assert.equal(tree.countFor(tags, 'A'), 5)
  assert.equal(tree.countFor(tags, 'alpine'), 4)
  assert.equal(tree.countFor(tags, 'missing'), 0)
})
