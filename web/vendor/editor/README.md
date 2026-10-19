# Browser editor dependencies

Roclet uses CodeMirror 6 and Lezer as native browser ES modules. There is no Node,
npm, bundler or CDN requirement for building, serving or using Roclet. Modules
are resolved by the local import map in `web/studio.html`.

These are unmodified ESM entry files from pinned npm release archives. Archives
were verified against their registry SHA-512 integrity before extracting only the
ESM entry and license. `lock.json` records exact versions, archive URLs/integrity,
module SHA-256, license SHA-256 and upstream dependency constraints. All 14
packages use the MIT license; the adjacent `.LICENSE` files retain attribution.
Total JavaScript is 1,166,035 bytes before compression. Normal Zig builds use
these checked-in assets and do not contact a package registry.

- [CodeMirror source and API](https://github.com/codemirror)
- [Lezer Markdown source](https://github.com/lezer-parser/markdown)

To update: choose a compatible release set, download the recorded release
archives, verify integrity, and replace the unmodified ESM entry files and
licenses. Update the lock and HTML import map together. Run both desktop and
compact `/web/studio-ui-conformance.html` checks. Do not run package install
scripts. No dependency management command is part of the regular build.

The editor owns text selection, multiple cursors and DOM layout. Its Markdown
parser is used only for source highlighting. Roc token ranges come from the
pinned Roc compiler through the existing syntax API. Notebook parsing, lowering,
encoding and evaluation still belong to the Roc core/compiler; Markdown display
still uses MD4C's safe typed events.
