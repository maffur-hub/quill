"use strict"

// Linked scrolling: block edges anchor source lines to preview pixels, and a
// line between two anchors is interpolated so both panes stay together.

const test = require("node:test")
const assert = require("node:assert")

const { load } = require("./helpers/load")

const PreviewSync = load("PreviewSync.js")

// A five-line paragraph followed by a one-line block.
const anchors = () => [
  { line: 0, endLine: 4, y: 0, height: 100 },
  { line: 5, endLine: 5, y: 110, height: 20 }
]

test("the top of a block maps to its first line", () => {
  assert.equal(PreviewSync.lineForY(anchors(), 0), 0)
  assert.equal(PreviewSync.lineForY(anchors(), 110), 5)
})

test("a pixel inside a block interpolates to a middle line", () => {
  // Halfway down a five-line block is line 2 (0, 1, 2, 3, 4).
  assert.equal(PreviewSync.lineForY(anchors(), 50), 2)
})

test("below the last anchor clamps to the last block's end line", () => {
  assert.equal(PreviewSync.lineForY(anchors(), 1000), 5)
})

test("above the first anchor returns the first line", () => {
  assert.equal(PreviewSync.lineForY(anchors(), -40), 0)
})

test("a line maps to its block's y, and its last line stays inside the block", () => {
  assert.equal(PreviewSync.yForLine(anchors(), 0), 0)
  assert.equal(PreviewSync.yForLine(anchors(), 5), 110)
  const last = PreviewSync.yForLine(anchors(), 4)
  assert.ok(last > 0 && last < 100)
})

test("a line before the document returns the first anchor's y", () => {
  assert.equal(PreviewSync.yForLine(anchors(), -10), 0)
})

test("a line past the end returns the last block's bottom", () => {
  assert.equal(PreviewSync.yForLine(anchors(), 99), 130)
})

test("anchors with no height, a negative line or a reversed range are ignored", () => {
  const list = [
    { line: 0, endLine: 4, y: 0, height: 0 },
    { line: -1, endLine: 2, y: 10, height: 20 },
    { line: 5, endLine: 3, y: 30, height: 20 },
    { line: 6, endLine: 8, y: 60, height: 30 }
  ]
  assert.equal(PreviewSync.lineForY(list, 25), 6)
  assert.equal(PreviewSync.lineForY(list, 75), 7)
  assert.equal(PreviewSync.yForLine(list, 8), 80)
})

test("every source line round trips through pixels", () => {
  const list = anchors()
  for (let line = 0; line <= 5; line++) {
    assert.equal(PreviewSync.lineForY(list, PreviewSync.yForLine(list, line)), line)
  }
})

test("empty or missing anchors resolve to the first line", () => {
  assert.equal(PreviewSync.lineForY([], 100), 0)
  assert.equal(PreviewSync.lineForY(undefined, 100), 0)
  assert.equal(PreviewSync.yForLine([], 3), 0)
  assert.equal(PreviewSync.yForLine(undefined, 3), 0)
})
