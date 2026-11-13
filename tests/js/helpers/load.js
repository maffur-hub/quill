'use strict'

// Load a product JavaScript module with node:vm.
//
// Quill's shared modules are plain ES5 with no Qt imports. Most declare
// top-level functions rather than exporting them, so tests evaluate each file
// in a fresh context and read the functions off that context. WritableGuard.js
// starts with QML's `.pragma library`, which is not valid JavaScript; strip
// that one line before compiling.

const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const assert = require('node:assert/strict')

const ROOT = path.resolve(__dirname, '..', '..', '..')

function load (file, extra = {}) {
  let source = fs.readFileSync(path.join(ROOT, file), 'utf8')
  source = source.replace(/^\.pragma library\r?\n/, '')
  const context = vm.createContext({ console, ...extra })
  vm.runInContext(source, context, { filename: file })
  return context
}

// Values returned from a vm context belong to another realm, so their arrays
// and objects fail strict prototype checks. Tests compare structured results
// through this host-realm copy.
function plain (value) {
  return JSON.parse(JSON.stringify(value))
}

function deepEqual (actual, expected) {
  assert.deepStrictEqual(plain(actual), expected)
}

module.exports = { load, ROOT, plain, deepEqual }
