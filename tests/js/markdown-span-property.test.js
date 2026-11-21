'use strict'

// B1 property: Quill's span planner must never emit structurally ill-formed
// inline HTML. Ported from the B1/B6 fuzz corpus in /tmp/opencode/quill-b-audit
// (fuzz-span.js and fuzz-random.js): same documents, same selection sweep, same
// seeded random grammar. Every successful plan() result must pass an
// independent stack validator for the four inline tags the planner emits
// (span, u, sup, sub); refusal (ok === false) is always acceptable.

const test = require('node:test')
const assert = require('node:assert/strict')
const { load } = require('./helpers/load')

const { plan } = load('MarkdownFormat.js')

// Re-implemented here on purpose: the production predicate and this validator
// must not share code, or a bug in one would hide the other.
const TAG = /<(\/?)(span|u|sup|sub)\b[^>]*>/gi

function inlineProblem (text) {
  const stack = []
  TAG.lastIndex = 0
  let match
  while ((match = TAG.exec(text)) !== null) {
    const name = match[2].toLowerCase()
    if (match[1] === '') {
      stack.push(name)
      continue
    }
    const top = stack.pop()
    if (top !== name) {
      return 'crossed ' + match[0] + ' (open was ' + (top === undefined ? 'nothing' : '<' + top + '>') + ')'
    }
  }
  if (stack.length > 0) return 'unclosed ' + stack.join(',')
  return null
}

// Every tag-emitting action the planner exposes. Marker actions (bold, italic,
// strike, code, highlight) emit no tags and are covered by the existing suites.
const TAG_ACTIONS = [
  ['color', 'rgb(9, 9, 9)'],
  ['highlightColor', 'rgb(250, 215, 160)'],
  ['size', 'small'],
  ['size', 'large'],
  ['size', 'xlarge'],
  ['underline', null],
  ['superscript', null],
  ['subscript', null],
  ['clear', '']
]

// fuzz-span.js's hand-built documents, verbatim.
const CRAFTED = [
  '<span style="color: rgb(255, 0, 0);">red</span> and plain',
  '<span style="color: rgb(255, 0, 0);">a<span style="color: rgb(0, 0, 255);">b</span>c</span>',
  '<span style="background-color: rgb(191, 237, 210);">green</span><span style="color: rgb(1, 2, 3);">blue</span>',
  'x <span style="color: rgb(255, 0, 0); font-size: 18px;">rs</span> y',
  '<u><span style="color: rgb(255, 0, 0);">us</span></u>',
  '<span style="color: rgb(1, 2, 3);">one</span> <span style="color: rgb(4, 5, 6);">two</span>',
  '**bold** <span style="color: rgb(1, 2, 3);">c</span> `code`',
  '<span style="color: rgb(1, 2, 3);"></span>',
  '<span style="font-size: 10px;">small</span>',
  // Documents the B1 repros and fuzz-random.js found crossings on.
  'H <sup>2</sup>O water',
  '<sup>2</sup>',
  '<sup>2</sup><sup>2</sup>',
  '<sup>2</sup>`c`plain`c`',
  '~~s~~<sup>2</sup>~~s~~plain',
  '\n<sup>2</sup>',
  '**b**`c`<sup>2</sup><sup>2</sup>',
  'say <u>now</u>!',
  '<span style="color: rgb(1, 2, 3);"><u>x</u></span>'
]

// fuzz-random.js's grammar and LCG, replayed exactly: the documents are the
// ones the fuzzer built (including the action and selection draws that
// consumed the same stream), and the exact sampled case is replayed too so the
// random corpus is covered without an unseeded sweep.
const FRAGMENTS = [
  'plain', ' ', '\n', 'word ', '**b**', '*i*', '`c`', '==h==', '~~s~~',
  '<u>u</u>', '<sup>2</sup>',
  '<span style="color: rgb(255, 0, 0);">red</span>',
  '<span style="background-color: rgb(191, 237, 210);">bg</span>',
  '<span style="color: rgb(1, 2, 3);"><u>x</u></span>'
]
const RANDOM_ACTIONS = [['color', 'rgb(9, 9, 9)'], ['size', 'small'],
  ['highlightColor', 'rgb(250, 215, 160)'], ['clear', ''],
  ['bold', null], ['italic', null], ['underline', null], ['highlight', null],
  ['code', null], ['link', 'https://x.test'], ['heading', 2], ['bullet', null]]

function randomCases (rounds) {
  let seed = 12345
  const rnd = (n) => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return seed % n
  }
  const cases = []
  for (let round = 0; round < rounds; round++) {
    let text = ''
    const parts = 1 + rnd(5)
    for (let i = 0; i < parts; i++) text += FRAGMENTS[rnd(FRAGMENTS.length)]
    const [action, value] = RANDOM_ACTIONS[rnd(RANDOM_ACTIONS.length)]
    const start = rnd(text.length + 1)
    const end = start + rnd(text.length - start + 1)
    cases.push({ text, action, value, start, end })
  }
  return cases
}

function describe (doc, action, value, start, end) {
  return action + ' ' + JSON.stringify(value) + ' sel ' + start + '..' + end
    + ' on ' + JSON.stringify(doc)
}

test('every tag-emitting action over the fuzz corpus is refused or well-formed', () => {
  const failures = []
  for (const doc of CRAFTED) {
    for (const [action, value] of TAG_ACTIONS) {
      for (let start = 0; start <= doc.length; start++) {
        for (let end = start; end <= doc.length; end++) {
          const result = plan(doc, start, end, action, value)
          if (!result.ok) continue
          const problem = inlineProblem(result.text)
          if (problem) {
            failures.push(describe(doc, action, value, start, end)
              + '\n  out: ' + JSON.stringify(result.text) + '\n  ' + problem)
          }
        }
      }
    }
  }
  assert.equal(failures.length, 0, '\n' + failures.slice(0, 12).join('\n') + '\n'
    + failures.length + ' malformed outputs in total')
})

test('the seeded random corpus is refused or well-formed', () => {
  const failures = []
  for (const item of randomCases(400)) {
    const result = plan(item.text, item.start, item.end, item.action, item.value)
    if (!result.ok) continue
    const problem = inlineProblem(result.text)
    if (problem) {
      failures.push(describe(item.text, item.action, item.value, item.start, item.end)
        + '\n  out: ' + JSON.stringify(result.text) + '\n  ' + problem)
    }
  }
  assert.equal(failures.length, 0, '\n' + failures.slice(0, 12).join('\n'))
})

test('B1/B6 repro rows are refused instead of crossing tags', () => {
  const cases = [
    { doc: 'H <sup>2</sup>O water', start: 0, end: 8, action: 'color', value: 'rgb(224, 62, 45)' },
    { doc: '<sup>2</sup>', start: 6, end: 12, action: 'color', value: 'rgb(224, 62, 45)' },
    { doc: 'say <u>now</u>!', start: 0, end: 10, action: 'size', value: 'large' },
    {
      doc: '<span style="background-color: rgb(191, 237, 210);">green</span><span style="color: rgb(1, 2, 3);">blue</span>',
      start: 58,
      end: 65,
      action: 'clear',
      value: ''
    }
  ]
  for (const item of cases) {
    const result = plan(item.doc, item.start, item.end, item.action, item.value)
    assert.equal(result.ok, false, describe(item.doc, item.action, item.value, item.start, item.end)
      + ' should be refused, got ' + JSON.stringify(result.text))
    assert.equal(result.error, 'Cannot apply formatting across a tag')
  }
})

test('legal tag edits still succeed', () => {
  const colour = plan('hello world', 0, 5, 'color', 'rgb(224, 62, 45)')
  assert.equal(colour.ok, true)
  assert.equal(colour.text, '<span style="color: rgb(224, 62, 45);">hello</span> world')

  const underline = plan('hello', 0, 5, 'underline')
  assert.equal(underline.ok, true)
  assert.equal(underline.text, '<u>hello</u>')

  const inside = plan('<span style="color: rgb(1, 2, 3);">one two</span>', 23, 26, 'color', 'rgb(9, 9, 9)')
  assert.equal(inside.ok, true)
  assert.equal(inlineProblem(inside.text), null)

  const sup = plan('H2O', 1, 2, 'superscript')
  assert.equal(sup.ok, true)
  assert.equal(sup.text, 'H<sup>2</sup>O')
})

test('an already-broken note is left editable', () => {
  // The exact crossed output B1a produced before the fix.
  const broken = '<span style="color: rgb(224, 62, 45);">H <sup>2</span></sup>O water'
  const at = broken.indexOf('water')
  const result = plan(broken, at, at + 5, 'color', 'rgb(9, 9, 9)')
  assert.equal(result.ok, true, result.error)
  assert.ok(result.text.indexOf('H <sup>2</span></sup>') >= 0,
    'the pre-existing damage must be preserved, not rewritten')
  assert.ok(result.text.indexOf('<span style="color: rgb(9, 9, 9);">water</span>') >= 0,
    'the new edit must still apply')
})
