'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const FileUrls = load('FileUrls.js')

test('a plain local path becomes a file URL', () => {
  assert.equal(FileUrls.fileUrl('/home/me/spec.pdf'), 'file:///home/me/spec.pdf')
})

test('spaces and unicode are percent encoded', () => {
  assert.equal(
    FileUrls.fileUrl('/home/me/My Notes/Café menü.pdf'),
    'file:///home/me/My%20Notes/Caf%C3%A9%20men%C3%BC.pdf')
})

test('an already encoded link is not encoded twice', () => {
  assert.equal(
    FileUrls.fileUrl('/home/me/My%20Notes/a%20b.pdf'),
    'file:///home/me/My%20Notes/a%20b.pdf')
})

test('a fragment or query character in a file name is escaped', () => {
  assert.equal(
    FileUrls.fileUrl('/home/me/a#b?.md'),
    'file:///home/me/a%23b%3F.md')
})

test('a lone percent sign does not fail the conversion', () => {
  assert.equal(FileUrls.fileUrl('/home/me/100%.md'), 'file:///home/me/100%25.md')
})

test('anything with a scheme is left untouched', () => {
  for (const value of ['https://example.test/a b', 'mailto:me@example.test',
    'quill://note/Inbox/a.md']) {
    assert.equal(FileUrls.fileUrl(value), value)
  }
})

test('an empty value stays empty', () => {
  assert.equal(FileUrls.fileUrl(''), '')
  assert.equal(FileUrls.fileUrl(null), '')
  assert.equal(FileUrls.fileUrl(undefined), '')
})
