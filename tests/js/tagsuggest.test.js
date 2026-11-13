'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const { suggest, normalizeTag } = require('../../TagSuggest.js')

test('normalizeTag folds case, spaces and accents', () => {
  assert.equal(normalizeTag('  Hello World! '), 'hello-world')
  assert.equal(normalizeTag('naïve café'), 'naive-cafe')
  assert.equal(normalizeTag('a/b'), 'ab')
  assert.equal(normalizeTag('C++'), 'c')
})

test('normalizeTag collapses punctuation and trims separators', () => {
  assert.equal(normalizeTag('---Deep   Work---'), 'deep-work')
  assert.equal(normalizeTag(''), '')
})

test('normalizeTag caps tags at 40 characters', () => {
  const tag = normalizeTag('a'.repeat(60))
  assert.equal(tag.length, 40)
  assert.equal(tag, 'a'.repeat(40))
})

test('suggest ranks repeated title words first', () => {
  const tags = suggest(
    'Project Planning notes',
    'We should plan the project planning meeting. The project planning doc.',
    [],
    []
  )
  assert.equal(tags[0], 'project-planning')
  assert.ok(tags.includes('planning'))
  assert.ok(tags.includes('project'))
  assert.ok(tags.length <= 5)
})

test('suggest excludes tags that already exist', () => {
  const tags = suggest('Untitled', 'alpha beta gamma', ['alpha'], [])
  assert.ok(!tags.includes('alpha'))
  assert.ok(tags.includes('beta'))
  assert.ok(tags.includes('gamma'))
})

test('suggest boosts known tags', () => {
  const tags = suggest(
    'Machine Learning',
    'machine learning models and machine learning data',
    [],
    ['machine-learning']
  )
  assert.equal(tags[0], 'machine-learning')
})

test('suggest accepts known tags as {tag, count} rows', () => {
  const tags = suggest('Search engine notes', 'search engine work', [], [{ tag: 'search-engine', count: 3 }])
  assert.ok(tags.includes('search-engine'))
})

test('suggest keeps repeated bigrams but drops incidental ones', () => {
  const tags = suggest('Repeat', 'foo bar foo bar', [], [])
  assert.ok(tags.includes('foo-bar'))
})

test('suggest ignores stopwords and empty documents', () => {
  assert.deepEqual(suggest('x', 'the and of to a in is it', [], []), [])
  assert.deepEqual(suggest('', '', [], []), [])
})

test('suggest strips frontmatter and fenced code before scanning', () => {
  const content = [
    '---',
    'tags: [alpha]',
    '---',
    'realword here',
    '```',
    'hiddenword hiddenword hiddenword',
    '```'
  ].join('\n')
  const tags = suggest('', content, [], [])
  assert.ok(tags.includes('realword'))
  assert.ok(!tags.includes('hiddenword'))
})
