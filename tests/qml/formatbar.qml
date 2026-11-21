import QtQuick
import "../../MarkdownFormat.js" as MarkdownFormat

// The colour, size, highlight, underline, superscript, subscript, strike,
// task, quote, date, emoji and note-link controls had no automated cover: the
// toolbar is a 1,900-line component that four popups feed, and a renamed
// action string there is a silent no-op no load check can see.
//
// The case drives the real controls offscreen and asserts on the markdown the
// engine plans from the emitted (name, value) pair, not on button state. A
// control is clicked by emitting activated()/picked() on the item whose handler
// a click runs; popup rows are reached through itemAtIndex() and their
// MouseArea's clicked(). FormatBar.available defaults to true and Library only
// narrows it for an unloaded, oversized or draft note, so the bar created here
// needs no editor behind it.
Item {
  id: test
  objectName: "formatBarCase"

  property var harness: null
  property var bar: null
  property var captured: null
  property string sample: "some words here"

  function walk(item, found) {
    if (!item) return found
    if (found.indexOf(item) >= 0) return found
    found.push(item)
    var kids = []
    var i
    if (item.children) for (i = 0; i < item.children.length; i++) kids.push(item.children[i])
    try { if (item.data) for (i = 0; i < item.data.length; i++) kids.push(item.data[i]) } catch (error) {}
    if (item.contentItem) kids.push(item.contentItem)
    if (item.item) kids.push(item.item)
    for (i = 0; i < kids.length; i++) test.walk(kids[i], found)
    return found
  }

  function findIn(root, predicate) {
    var all = walk(root, [])
    for (var i = 0; i < all.length; i++) if (predicate(all[i])) return all[i]
    return null
  }

  // FmtButton and MenuButton both carry activated(); tooltips and labels tell
  // them apart from highlight swatches, which also carry tips.
  function button(tip) {
    return findIn(bar, function(item) {
      return item.tip === tip && typeof item.activated === "function"
    })
  }
  function named(name) {
    return findIn(bar, function(item) { return item.objectName === name })
  }
  function menu(label) {
    return findIn(bar, function(item) {
      return item.label === label && typeof item.activated === "function"
    })
  }
  function cell(popup, hex) {
    return findIn(popup.contentItem, function(item) {
      return typeof item.picked === "function" && String(item.swatch).toLowerCase() === hex
    })
  }
  // List and grid delegates react through a MouseArea; emitting clicked() runs
  // exactly the onClicked handler a click would.
  function clickDelegate(host, index) {
    var view = findIn(host, function(item) {
      return typeof item.itemAtIndex === "function" && item.count > index
    })
    if (!view) return "no populated list view"
    var row = view.itemAtIndex(index)
    if (!row) return "list view has no delegate at " + index
    var hit = findIn(row, function(item) { return typeof item.clicked === "function" })
    if (!hit) return "delegate has no MouseArea"
    hit.clicked(null)
    return ""
  }

  // control = [kind, ...]: tip|object (button), menu [openerTip, label],
  // insert [objectName], swatch [popup, hex], delegate [popup, index].
  function drive(row) {
    var c = row.control
    var target = null
    if (c[0] === "tip") target = button(c[1])
    else if (c[0] === "object") target = named(c[1])
    if (c[0] === "tip" || c[0] === "object") {
      if (!target) return "no control for " + c[1]
      target.activated()
      return ""
    }
    if (c[0] === "menu") {
      var opener = button(c[1])
      if (!opener) return "no " + c[1] + " of the menu"
      opener.activated()
      target = menu(c[2])
      if (!target) return "no " + c[2] + " entry in the menu"
      target.activated()
      return ""
    }
    if (c[0] === "swatch") {
      var popup = c[1]
      popup.open()
      target = cell(popup, c[2])
      if (!target) { popup.close(); return "no " + c[2] + " swatch in the palette" }
      target.picked()
      popup.close()
      return ""
    }
    if (c[0] === "insert") {
      bar.insertPopupRef.open()
      target = named(c[1])
      if (!target) return "no " + c[1] + " entry in the insert menu"
      target.activated()
      return ""
    }
    if (c[0] === "delegate") {
      c[1].open()
      var problem = clickDelegate(c[1].contentItem, c[2])
      c[1].close()
      return problem
    }
    return "unknown control kind " + c[0]
  }

  function checkRow(row) {
    captured = null
    var problem = ""
    if (row.before) row.before()
    try { problem = drive(row) } catch (error) { problem = "threw " + error }
    if (problem !== "") return problem
    if (captured === null) return "the control emitted no action"
    if (captured.name !== row.action)
      return "emitted " + captured.name + ", expected " + row.action
    var value = captured.value === undefined || captured.value === null
      ? "" : String(captured.value)
    if (row.value && !row.value(value)) return "unexpected value " + value
    var built = MarkdownFormat.plan(sample, row.at, row.to, captured.name, captured.value)
    if (!built.ok) return "the engine refused: " + built.error
    for (var i = 0; i < row.needles.length; i++) {
      var needle = row.needles[i].replace("$value", value)
      if (built.text.indexOf(needle) < 0) return "missing " + needle + " in " + built.text
    }
    return ""
  }

  function rows() {
    var date = function(v) { return /^\d{4}-\d{2}-\d{2}$/.test(v) }
    var modalPopup = bar.emojiPopupRef
    var linkPopup = bar.noteLinkPopupRef
    bar.noteTitles = ["Weekly review", "Sourdough"]
    bar.noteLinkQuery = ""
    return [
      { name: "colour swatch emits the normalised colour", action: "color",
        at: 0, to: 4, needles: ['<span style="color: ', "$value"],
        value: function(v) { return v === "rgb(224, 62, 45)" },
        control: ["swatch", bar.colorPalettePopup, "#e03e2d"] },
      { name: "highlight swatch emits a background span", action: "highlightColor",
        at: 0, to: 4, needles: ["background-color: ", "$value"],
        value: function(v) { return v === "rgb(194, 224, 244)" },
        control: ["swatch", bar.highlightPalettePopup, "#c2e0f4"] },
      { name: "highlight button marks with ==", action: "highlight",
        at: 0, to: 4, needles: ["=="], control: ["object", "formatHighlightButton"],
        // The main button re-applies the last palette colour once one has been
        // chosen (the row above chose blue); empty means plain == again.
        before: function() { bar.lastHighlight = "" } },
      { name: "underline emits a u tag", action: "underline",
        at: 0, to: 4, needles: ["<u>", "</u>"], control: ["tip", "Underline (Ctrl+U)"] },
      { name: "strike emits a double tilde", action: "strike",
        at: 0, to: 4, needles: ["~~"], control: ["tip", "Strikethrough (Ctrl+Shift+X)"] },
      { name: "superscript emits a sup tag", action: "superscript",
        at: 0, to: 4, needles: ["<sup>", "</sup>"], control: ["object", "formatSuperscriptButton"] },
      { name: "subscript emits a sub tag", action: "subscript",
        at: 0, to: 4, needles: ["<sub>", "</sub>"], control: ["object", "formatSubscriptButton"] },
      { name: "task adds the unchecked box prefix", action: "task",
        at: 0, to: 4, needles: ["- [ ] "], control: ["tip", "Task list"] },
      { name: "quote adds the blockquote prefix", action: "quote",
        at: 0, to: 4, needles: ["> "], control: ["tip", "Blockquote"] },
      { name: "size large emits 18px", action: "size",
        at: 0, to: 4, needles: ["font-size: 18px"],
        value: function(v) { return v === "large" }, control: ["menu", "Text size", "Large"] },
      { name: "size small emits 10px", action: "size",
        at: 0, to: 4, needles: ["font-size: 10px"],
        value: function(v) { return v === "small" }, control: ["menu", "Text size", "Small"] },
      { name: "size extra large emits 22px", action: "size",
        at: 0, to: 4, needles: ["font-size: 22px"],
        value: function(v) { return v === "xlarge" }, control: ["menu", "Text size", "Extra large"] },
      { name: "date inserts an ISO date", action: "date",
        at: 5, to: 5, needles: ["$value"], value: date,
        control: ["insert", "formatInsertDate"] },
      { name: "emoji cell inserts its glyph", action: "emoji",
        at: 5, to: 5, needles: ["$value"], value: function(v) { return v.length > 0 },
        control: ["delegate", modalPopup, 0] },
      { name: "note-link row inserts a wiki link", action: "noteLink",
        at: 5, to: 5, needles: ["[[", "$value", "]]"],
        value: function(v) { return v === "Weekly review" },
        control: ["delegate", linkPopup, 0] }
    ]
  }

  function finish() {
    tick.stop()
    harness.done()
  }

  function verify() {
    var list = rows()
    for (var i = 0; i < list.length; i++) {
      var problem = checkRow(list[i])
      harness.check(list[i].name, problem === "", problem)
    }
    finish()
  }

  function start(h) {
    harness = h
    var component = Qt.createComponent(Qt.resolvedUrl("../../FormatBar.qml"))
    if (component.status !== Component.Ready) {
      harness.check("FormatBar.qml is ready", false, component.errorString())
      finish()
      return
    }
    bar = component.createObject(test, { width: 900, height: 30 })
    if (!bar) {
      harness.check("the format bar could be created", false, "")
      finish()
      return
    }
    bar.action.connect(function(name, value) {
      captured = { name: name, value: value }
    })
    tick.start()
  }

  Timer {
    id: tick
    interval: 1000
    running: false
    onTriggered: test.verify()
  }
}
