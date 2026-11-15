'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const guard = load('WritableGuard.js')
const HOME = '/home/u'

test('normalizePath expands ~ and resolves . and ..', () => {
  assert.equal(guard.normalizePath('~/notes/../x', HOME), '/home/u/x')
  assert.equal(guard.normalizePath('/a//b/./c/', HOME), '/a/b/c')
  assert.equal(guard.normalizePath('', HOME), '')
})

test('normalizePath decodes file:// URLs', () => {
  assert.equal(guard.normalizePath('file:///tmp/my%20notes', HOME), '/tmp/my notes')
})

test('isRealDataRoot matches only the live Quill root', () => {
  assert.equal(guard.isRealDataRoot('~/.local/share/quill', HOME), true)
  assert.equal(guard.isRealDataRoot('/tmp/quill', HOME), false)
  assert.equal(guard.isRealDataRoot('', HOME), false)
})

test('writes are refused for the real root unless explicitly allowed', () => {
  assert.equal(guard.writesAllowed('~/.local/share/quill', false, HOME), false)
  assert.equal(guard.writesAllowed('~/.local/share/quill', true, HOME), true)
})

test('writes are allowed for disposable roots', () => {
  assert.equal(guard.writesAllowed('/tmp/opencode/quill', false, HOME), true)
})

test('an empty root is read-only even when real data is allowed', () => {
  assert.equal(guard.writesAllowed('', true, HOME), false)
})

test('refusal message explains the guard', () => {
  assert.match(guard.refusalMessage(), /refusing to write to the real Quill data root/i)
})

test('isMutatingArgs classifies note commands', () => {
  for (const args of [
    ['write', 'x'],
    ['create'],
    ['duplicate', 'x'],
    ['rename', 'x'],
    ['move', 'x'],
    ['trash', 'x'],
    ['restore', 'x'],
    ['delete', 'x'],
    ['empty-trash'],
    ['pin', 'x'],
    ['tag-add', 'x', '#a'],
    ['tag-remove', 'x', '#a'],
    ['tag-rename', 'a', 'b'],
    ['index', '--rebuild'],
    ['restore-version', 'x', 'snap']
  ]) {
    assert.equal(guard.isMutatingArgs(args), true, args.join(' '))
  }
})

test('an unknown command counts as a write', () => {
  assert.equal(guard.isMutatingArgs(['future-command', 'x']), true)
  assert.equal(guard.isMutatingArgs(['read', 'x']), false)
  assert.equal(guard.isMutatingArgs(['versions', 'x']), false)
})

test('isMutatingArgs treats tag-remove as a state write', () => {
  assert.equal(guard.isMutatingArgs(['tag-remove', 'x', '#a']), true)
  assert.equal(guard.isMutatingArgs(['tag-remove', 'x', '--id', 'y', 'a']), true)
})

test('isMutatingArgs classifies subcommands and read-only commands', () => {
  assert.equal(guard.isMutatingArgs(['folder', 'create', 'a']), true)
  assert.equal(guard.isMutatingArgs(['draft', 'discard', 'x']), true)
  assert.equal(guard.isMutatingArgs(['draft', 'save']), false)
  assert.equal(guard.isMutatingArgs(['attachment', 'save']), true)
  assert.equal(guard.isMutatingArgs(['attachment', 'gc']), true)
  assert.equal(guard.isMutatingArgs(['attachment', 'list']), false)
  assert.equal(guard.isMutatingArgs(['list']), false)
  assert.equal(guard.isMutatingArgs(['search', 'x']), false)
  assert.equal(guard.isMutatingArgs([]), false)
})

test('isMutatingArgs treats templates saves and deletes as writes', () => {
  assert.equal(guard.isMutatingArgs(['templates', 'save', 'weekly', '--name', 'Weekly']), true)
  assert.equal(guard.isMutatingArgs(['templates', 'delete', 'weekly']), true)
  assert.equal(guard.isMutatingArgs(['templates', 'list']), false)
  assert.equal(guard.isMutatingArgs(['templates', 'show', 'weekly']), false)
  assert.equal(guard.isMutatingArgs(['templates']), false)
})

test('isMutatingArgs treats settings gets as reads and sets as writes', () => {
  assert.equal(guard.isMutatingArgs(['settings', 'get']), false)
  assert.equal(guard.isMutatingArgs(['settings', 'set', '--json', '{}']), true)
  assert.equal(guard.isMutatingArgs(['settings', 'set', '--stdin']), true)
  assert.equal(guard.isMutatingArgs(['settings']), true)
})

test('isMutatingArgs treats tag-delete as a state write', () => {
  assert.equal(guard.isMutatingArgs(['tag-delete', 'alpha']), true)
})
