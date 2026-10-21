# Third-party software

Roclet is licensed under UPL-1.0; see LICENSE. Dependencies retain their licenses:

- **Roc compiler** — UPL-1.0. See `compiler-adapter/ROC-LICENSE` and the pinned revision in `compiler.lock.json`.
- **MD4C** — MIT. See `vendor/md4c/LICENSE.md` in source, or `web/vendor/md4c.LICENSE.md` in the browser distribution.
- **CodeMirror, Lezer, and editor dependencies** — MIT. Individual notices and the package list are in `web/vendor/editor/`.
- **KaTeX and its bundled fonts** — MIT. See `web/vendor/katex/LICENSE`; provenance is recorded in its lock file. Exported math styles include the notice.
- **TigerBeetle tidy.zig** — Apache-2.0. `ci/tidy.zig` is adapted from TigerBeetle's `src/tidy.zig` by way of the Roc compiler's `ci/tidy.zig`; the file header carries the notice and license link.

The Roc compiler has its own build dependencies. Its pinned source checkout is
the reference for their licenses; this list describes Roclet's directly vendored
components, not a separate audit of every compiler build dependency.
