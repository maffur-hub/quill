"use strict"

// The editor's wheel scrolling: trackpads pass through, and a wheel spin ramps
// up with the speed of the notches and settles back to the base step.

const test = require("node:test")
const assert = require("node:assert")

const { load } = require("./helpers/load")

const WheelScroll = load("WheelScroll.js")

test("first notch scrolls one base step", () => {
  const state = WheelScroll.create()
  assert.equal(WheelScroll.step(state, -120, 0, 1000), -WheelScroll.BASE)
})

test("a positive delta scrolls the other way", () => {
  const state = WheelScroll.create()
  assert.equal(WheelScroll.step(state, 120, 0, 1000), WheelScroll.BASE)
})

test("rapid notches accelerate", () => {
  const state = WheelScroll.create()
  const first = WheelScroll.step(state, -120, 0, 1000)
  const second = WheelScroll.step(state, -120, 0, 1020)
  assert.equal(first, -WheelScroll.BASE)
  assert.ok(Math.abs(second) > Math.abs(first))
})

test("a long spin is capped", () => {
  const state = WheelScroll.create()
  let now = 1000
  let step = 0
  for (let i = 0; i < 20; i++) {
    now += 20
    step = WheelScroll.step(state, -120, 0, now)
  }
  assert.equal(step, -WheelScroll.BASE * WheelScroll.MAX)
})

test("a normal mouse wheel spin still reaches top speed", () => {
  const state = WheelScroll.create()
  let now = 1000
  let step = 0
  // A mouse wheel often spaces notches 60-90 ms apart rather than every 20 ms.
  for (let i = 0; i < 10; i++) {
    now += 70
    step = WheelScroll.step(state, -120, 0, now)
  }
  assert.ok(Math.abs(step) >= WheelScroll.BASE * 10)
})

test("a pause resets the multiplier", () => {
  const state = WheelScroll.create()
  let now = 1000
  for (let i = 0; i < 10; i++) {
    now += 20
    WheelScroll.step(state, -120, 0, now)
  }
  assert.equal(WheelScroll.step(state, -120, 0, now + 400), -WheelScroll.BASE)
})

test("slowing down decays the multiplier without going below one", () => {
  const state = WheelScroll.create()
  let now = 1000
  for (let i = 0; i < 10; i++) {
    now += 20
    WheelScroll.step(state, -120, 0, now)
  }
  let step = 0
  for (let i = 0; i < 10; i++) {
    now += 200
    step = WheelScroll.step(state, -120, 0, now)
  }
  assert.equal(step, -WheelScroll.BASE)
})

test("trackpad deltas pass through unchanged and reset the multiplier", () => {
  const state = WheelScroll.create()
  WheelScroll.step(state, -120, 0, 1000)
  WheelScroll.step(state, -120, 0, 1020)
  assert.ok(state.factor > 1)

  assert.equal(WheelScroll.step(state, 0, 12, 1030), 12)
  assert.equal(state.factor, 1)
})

test("an empty delta does nothing", () => {
  const state = WheelScroll.create()
  assert.equal(WheelScroll.step(state, 0, 0, 1000), 0)
})
