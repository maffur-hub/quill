# Vendored MathJax

Quill renders maths offline with [MathJax](https://www.mathjax.org/) 3.2.2
(`mathjax-full`), used only from `scripts/quill-math` through its CommonJS
`js/` build. No network access and no system packages are involved.

Upstream licence: Apache-2.0. The licence text ships with the package in
`node_modules/mathjax-full/LICENSE`.

## Reinstalling

```bash
cd ~/.config/omarchy/plugins/matt.quill
npm install --prefix vendor mathjax-full@3.2.2
rm -rf vendor/node_modules/mathjax-full/{es5,components,ts}
rm -rf vendor/node_modules/{speech-rule-engine,commander,@xmldom,wicked-good-xpath,mj-context-menu,esm}
```

`npm install` also writes `vendor/package.json`, `package-lock.json` and may
create `vendor/node_modules/.package-lock.json`; those are harmless and can be
kept.

## Why the extra pruning

Only `mathjax-full/js/` is loaded by `scripts/quill-math` (the `es5/`,
`components/` and `ts/` trees are browser bundles, TypeScript sources and
typings — about 32 MB). `mhchemparser` stays because `AllPackages` imports the
`\ce` extension. `speech-rule-engine`, `mj-context-menu`, `commander`,
`@xmldom` and `wicked-good-xpath` are only reachable from MathJax's
accessibility and context-menu code, which Quill never loads, and `esm` is not
required by the CJS `js/` build. With those removed the tree is about 9 MiB.
After reinstalling, run the renderer once (see the tests in
`/tmp/opencode/test-quill-math.mjs`) to confirm the prune did not go too far.
