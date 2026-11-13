"use strict"

// End-to-end tests for scripts/quill-export-pdf. They exercise a real headless
// Chromium when one is installed and skip the printing test otherwise. Every
// file lives in a fresh mkdtemp directory; the live Quill data root is never
// read or written.

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const os = require("os")
const path = require("path")
const { spawnSync } = require("child_process")

const script = path.join(__dirname, "..", "..", "scripts", "quill-export-pdf")

// Same discovery order as the script, minus --chromium (the tests never pass
// it, so $QUILL_CHROMIUM and PATH are enough).
const BROWSER_NAMES = [
  "chromium",
  "chromium-browser",
  "google-chrome-stable",
  "google-chrome",
  "brave",
  "brave-browser",
  "microsoft-edge-stable",
  "microsoft-edge"
]

function isExecutable(file) {
  try {
    if (!fs.statSync(file).isFile()) return false
    fs.accessSync(file, fs.constants.X_OK)
    return true
  } catch (error) {
    return false
  }
}

function findBrowser() {
  const configured = String(process.env.QUILL_CHROMIUM || "").trim()
  if (configured !== "" && isExecutable(configured)) return configured
  for (const directory of String(process.env.PATH || "").split(path.delimiter)) {
    if (directory === "") continue
    for (const name of BROWSER_NAMES) {
      const candidate = path.join(directory, name)
      if (isExecutable(candidate)) return candidate
    }
  }
  return ""
}

const browser = findBrowser()
const skip = browser === "" ? "no chromium" : false

function temporaryDirectory() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "quill-exportpdf-test-"))
}

function remove(directory) {
  fs.rmSync(directory, { recursive: true, force: true })
}

function run(args) {
  return spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
    timeout: 180000
  })
}

test("prints a note with a table, long code line and maths to PDF", { skip }, () => {
  const directory = temporaryDirectory()
  try {
    const notePath = path.join(directory, "note.md")
    const pdfPath = path.join(directory, "note.pdf")
    const longLine = "const value = \"" + "x".repeat(400) + "\""
    fs.writeFileSync(notePath, [
      "# Export fixture",
      "",
      "Inline maths $x^2$ and a table:",
      "",
      "| Left | Right |",
      "| --- | ---: |",
      "| alpha | beta |",
      "",
      "```js",
      longLine,
      "```",
      ""
    ].join("\n"), "utf8")

    const result = run(["--input", notePath, "--output", pdfPath, "--title", "Export fixture"])

    assert.equal(result.status, 0, result.stderr)
    const lines = result.stdout.trim().split("\n")
    assert.equal(lines.length, 1, "stdout must be exactly one JSON line")
    const summary = JSON.parse(lines[0])
    assert.equal(summary.ok, true)
    assert.ok(summary.bytes > 1000, "PDF is suspiciously small: " + summary.bytes)
    assert.ok(summary.htmlBytes > 0)
    assert.equal(summary.pageSize, "A4")
    assert.ok(summary.engine.length > 0)
    assert.equal(summary.htmlPath, undefined)

    const pdf = fs.readFileSync(pdfPath)
    assert.equal(pdf.subarray(0, 5).toString("latin1"), "%PDF-")

    assert.deepEqual(fs.readdirSync(directory).sort(), ["note.md", "note.pdf"])
  } finally {
    remove(directory)
  }
})

test("fails cleanly when --input is missing", () => {
  const directory = temporaryDirectory()
  try {
    const pdfPath = path.join(directory, "note.pdf")
    const result = run(["--output", pdfPath, "--title", "No input"])

    assert.equal(result.status, 1)
    assert.ok(result.stderr.startsWith("quill-export-pdf:"), result.stderr)
    assert.equal(fs.existsSync(pdfPath), false)
  } finally {
    remove(directory)
  }
})

test("rejects a page size that could inject CSS", () => {
  const directory = temporaryDirectory()
  try {
    const notePath = path.join(directory, "note.md")
    const pdfPath = path.join(directory, "note.pdf")
    fs.writeFileSync(notePath, "# Injection\n\ntext\n", "utf8")

    const result = run([
      "--input", notePath,
      "--output", pdfPath,
      "--title", "Injection",
      "--page-size", "A4 } body{display:none"
    ])

    assert.equal(result.status, 1)
    assert.match(result.stderr, /page-size/)
    assert.equal(fs.existsSync(pdfPath), false)
  } finally {
    remove(directory)
  }
})
