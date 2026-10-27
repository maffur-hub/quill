import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "MathSyntax.js" as MathSyntax

// Maths rendering for one preview pane.
//
// TeX is collected from the preview blocks, deduplicated and sent to
// scripts/quill-math as one batch (MathJax's cold start dominates, so a
// process per formula would make typing feel slow). The child writes themed
// SVG files into the Quill cache; this item only keeps key → result entries
// and a revision counter that preview bindings watch.
//
// All maths state lives here rather than in PreviewPane so the panel, the
// library window and the detached window share exactly one implementation.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  property string color: Commons.Color.foreground
  property int fontPx: Style.font.body

  // key(tex, display) → { ok, path, invalid, error }
  property var results: ({})
  // Bumped whenever results change, so Text bindings re-evaluate.
  property int revision: 0
  property int pendingCount: 0
  property string lastError: ""

  // The plugin's own script; QUILL_MATH_SCRIPT lets a staged copy override it.
  readonly property string scriptPath: Quickshell.env("QUILL_MATH_SCRIPT")
    || String(Qt.resolvedUrl("scripts/quill-math")).replace(/^file:\/\//, "")

  property var queue: []
  property var queued: ({})
  property var inFlight: ({})
  property var idFor: ({})
  property string payload: ""
  property var lastBlocks: []
  property bool abandoned: false
  property int generation: 0
  property int batchGeneration: -1

  function key(tex, display) {
    return (display ? "D|" : "I|") + String(tex === undefined || tex === null ? "" : tex)
  }

  function get(tex, display) {
    var entry = results[key(tex, display)]
    return entry === undefined ? null : entry
  }

  function htmlFor(tex, display) {
    var entry = get(tex, display === undefined ? false : display)
    if (!entry || !entry.ok) return ""
    var path = String(entry.path || "")
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/ /g, "%20")
    return '<img src="file://' + path + '" valign="middle" alt="math">'
  }

  function inFlightCount() {
    var count = 0
    for (var k in inFlight) count += 1
    return count
  }

  // Queue one formula. Cached successes are never re-rendered.
  function request(tex, display) {
    var text = String(tex === undefined || tex === null ? "" : tex)
    if (text.trim() === "") return
    var isDisplay = !!display
    var cacheKey = key(text, isDisplay)
    var existing = results[cacheKey]
    if (existing && existing.ok) return
    if (inFlight[cacheKey] || queued[cacheKey]) return
    queued[cacheKey] = true
    var next = queue.slice()
    next.push({ key: cacheKey, tex: text, display: isDisplay })
    queue = next
    pendingCount = queue.length + inFlightCount()
    debounce.restart()
  }

  // Scan preview blocks: display maths blocks plus inline maths in text.
  // Table cells are deliberately left alone (the grid owns their text).
  function prefetch(blocks) {
    lastBlocks = blocks || []
    for (var i = 0; i < lastBlocks.length; i++) {
      var block = lastBlocks[i]
      if (!block) continue
      if (block.kind === "math") {
        request(block.tex, true)
      } else if (block.kind === "text") {
        var spans = MathSyntax.inlineSpans(String(block.text || ""))
        for (var s = 0; s < spans.length; s++) request(spans[s].tex, false)
      }
    }
  }

  function flush() {
    if (process.running) return
    var batch = []
    var seen = ({})
    for (var i = 0; i < queue.length; i++) {
      var entry = queue[i]
      if (seen[entry.key]) continue
      var known = results[entry.key]
      if (known && known.ok) continue
      seen[entry.key] = true
      batch.push(entry)
    }
    queue = []
    queued = ({})
    if (batch.length === 0) {
      pendingCount = 0
      return
    }

    var items = []
    var map = ({})
    inFlight = ({})
    for (var b = 0; b < batch.length; b++) {
      var id = String(b)
      items.push({ id: id, tex: batch[b].tex, display: batch[b].display })
      map[id] = batch[b].key
      inFlight[batch[b].key] = true
    }
    idFor = map
    abandoned = false
    batchGeneration = generation
    payload = JSON.stringify({ color: root.color, fontPx: root.fontPx, items: items })
    pendingCount = batch.length
    process.command = [scriptPath]
    process.running = true
    timeout.restart()
  }

  function errorTail(text) {
    var value = String(text || "").trim()
    if (value === "") return ""
    var lines = value.split("\n")
    value = lines.slice(Math.max(0, lines.length - 3)).join(" ").replace(/\s+/g, " ")
    return value.length > 200 ? value.slice(0, 200) : value
  }

  function failBatch(message) {
    var next = {}
    for (var existing in results) next[existing] = results[existing]
    for (var k in inFlight) next[k] = { ok: false, error: message }
    results = next
    inFlight = ({})
    idFor = ({})
    lastError = message
    revision += 1
    pendingCount = queue.length
    if (queue.length > 0) debounce.restart()
  }

  function finish(exitCode) {
    timeout.stop()
    if (abandoned || batchGeneration !== generation) {
      // A theme change or a timeout made this batch stale. Drop its output but
      // make sure anything queued meanwhile still gets a render.
      abandoned = false
      inFlight = ({})
      idFor = ({})
      pendingCount = queue.length
      if (queue.length > 0) debounce.restart()
      return
    }
    var output = String(process.outText || "")
    var errors = String(process.errText || "")
    if (exitCode !== 0) {
      var reason = "math renderer exited " + exitCode
      var tail = errorTail(errors)
      failBatch(tail === "" ? reason : reason + ": " + tail)
      return
    }

    var response = null
    try {
      response = JSON.parse(output)
    } catch (error) {
      response = null
    }
    if (!response || !Array.isArray(response.items)) {
      var badTail = errorTail(errors)
      failBatch(badTail === "" ? "math renderer returned no results"
        : "math renderer returned no results: " + badTail)
      return
    }

    var next = {}
    for (var existing in results) next[existing] = results[existing]
    var handled = ({})
    var problem = ""
    for (var i = 0; i < response.items.length; i++) {
      var item = response.items[i] || {}
      var id = String(item.id === undefined ? "" : item.id)
      var cacheKey = idFor[id]
      if (!cacheKey) continue
      handled[cacheKey] = true
      if (item.ok && item.path) {
        next[cacheKey] = {
          ok: true,
          path: String(item.path),
          invalid: !!item.invalid
        }
      } else {
        next[cacheKey] = { ok: false, error: String(item.error || "render failed") }
        problem = next[cacheKey].error
      }
    }
    for (var key in inFlight) {
      if (handled[key]) continue
      next[key] = { ok: false, error: "math renderer returned no result" }
      problem = next[key].error
    }

    results = next
    inFlight = ({})
    idFor = ({})
    if (problem !== "") lastError = problem
    revision += 1
    pendingCount = queue.length
    if (queue.length > 0) debounce.restart()
  }

  // A theme or font change invalidates every cached colour/size pairing.
  // Drop the map (bindings briefly show raw TeX) and ask for the same blocks
  // again at the new colour/size. A batch already running is left to finish;
  // its generation is stale, so finish() discards it and then flushes the
  // freshly queued requests. Killing it here risks reusing the Process object
  // while its exit signal is still in flight.
  function resetForTheme() {
    generation += 1
    results = ({})
    queue = []
    queued = ({})
    inFlight = ({})
    idFor = ({})
    pendingCount = 0
    lastError = ""
    revision += 1
    prefetch(lastBlocks)
    if (process.running) timeout.restart()
    else timeout.stop()
  }

  onColorChanged: resetForTheme()
  onFontPxChanged: resetForTheme()

  Timer {
    id: debounce
    interval: 40
    onTriggered: root.flush()
  }

  Timer {
    id: timeout
    interval: 10000
    onTriggered: {
      if (!process.running) return
      root.abandoned = true
      process.running = false
      root.failBatch("math renderer timed out")
    }
  }

  Process {
    id: process
    stdinEnabled: true
    property string outText: ""
    property string errText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: process.outText = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: process.errText = String(text || "")
    }
    onStarted: write(root.payload + "\n")
    onExited: function(exitCode) { root.finish(exitCode) }
  }
}
