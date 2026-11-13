'use strict'

// Render a note the way PreviewPane does, for the golden-file tests.
//
// The block splitter is PreviewBlocks.build; text blocks always go through
// MathText.toHtml (with highlighting and footnote numbering in its options),
// fenced code blocks are wrapped in <pre>, definition lists are dumped as
// plain structure text (Qt RichText cannot lay out <dl>), and the footnote
// section uses MarkdownExtras' HTML. Blocks are joined with a newline so a
// failing golden points at one feature at a time.
//
// Images, tables and display maths are placeholders: the golden pairs cover
// the Markdown extensions, not QML's table/image widgets.

const { load } = require('./load')

const MathText = load('MathText.js')
const MathSyntax = load('MathSyntax.js')
const TableEngine = load('TableEngine.js')
const ImageSizing = load('ImageSizing.js')
const MarkdownFormat = load('MarkdownFormat.js')
const MarkdownExtras = load('MarkdownExtras.js')
const PreviewBlocks = load('PreviewBlocks.js')
const CodeHighlight = load('CodeHighlight.js')

const DEPS = {
  image: ImageSizing,
  table: TableEngine,
  math: MathSyntax,
  format: MarkdownFormat,
  extras: MarkdownExtras
}

// The fixed palette the QML preview passes. Keeping it here rather than using
// CodeHighlight's defaults makes the goldens independent of a defaults change.
// The kbd pair mirrors the theme-aware values QML derives from the foreground;
// MathText falls back to these same colours when the pair is absent/invalid.
const PALETTE = {
  comment: '#6b7280',
  keyword: '#c792ea',
  string: '#a3d17a',
  number: '#e0a458',
  literal: '#e0a458',
  function: '#7aa2f7',
  type: '#7dcfff',
  tag: '#f07178',
  attribute: '#e0af68',
  punctuation: '#9aa0a6',
  kbdBackground: '#2a2d31',
  kbdText: '#e6e6e6'
}

function escapeAttribute (value) {
  return String(value === undefined || value === null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function render (markdown) {
  const blocks = PreviewBlocks.build(markdown, DEPS)
  const notes = blocks.filter(block => block.kind === 'footnotes')
  const numbers = {}
  if (notes.length > 0) {
    for (const item of notes[0].items) numbers[item.label] = item.number
  }
  const options = {
    highlight: CodeHighlight,
    palette: PALETTE,
    footnotes: { numbers }
  }
  const inline = value => MathText.renderInline(value, null, null, options)
  const parts = []

  for (const block of blocks) {
    if (block.kind === 'text') {
      parts.push(MathText.toHtml(block.text, null, null, options))
    } else if (block.kind === 'tasks') {
      const items = block.items.map(item =>
        '<li>' + (item.checked ? '\u2611' : '\u2610') + ' ' + inline(item.content) + '</li>')
      parts.push('<ul>' + items.join('') + '</ul>')
    } else if (block.kind === 'code') {
      parts.push('<pre>' + CodeHighlight.toHtml(block.code, block.language, PALETTE) + '</pre>')
    } else if (block.kind === 'deflist') {
      // Qt RichText flattens <dl>/<dt>/<dd> into a single run, so the golden
      // pipeline dumps the parsed structure instead: one line per block,
      // groups separated by "; ", definitions by " | ". That still proves
      // term/definition grouping without pretending Qt can lay it out.
      const groups = block.block.groups.map(group =>
        group.term + ' :: ' + group.definitions.join(' | '))
      parts.push('[deflist] ' + groups.join('; '))
    } else if (block.kind === 'footnotes') {
      parts.push(MarkdownExtras.footnoteSectionHtml(block.items, inline))
    } else if (block.kind === 'image') {
      parts.push('<p><img src="' + escapeAttribute(block.source) + '" alt="'
        + escapeAttribute(block.alt) + '"></p>')
    } else if (block.kind === 'table') {
      parts.push('<p>[table]</p>')
    } else if (block.kind === 'math') {
      parts.push('<p>[math]</p>')
    }
  }

  return parts.filter(part => part !== '').join('\n')
}

module.exports = {
  render,
  PALETTE,
  DEPS,
  MathText,
  MathSyntax,
  MarkdownExtras,
  PreviewBlocks,
  CodeHighlight
}
