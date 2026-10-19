# Roclet

Roclet is a planned reactive notebook system for Roc. This repository currently
implements **M0: the execution foundation**, **M1: Roc/Markdown document formats**,
**M2: the local reactive editor**, **M3: offline use and sharing**, and **M4: selective recomputation and developer tooling**. The first part of **M5** adds
rich Markdown/image outputs, TeX math, and paged tables; typed inputs and plots are next.

The prototype checks a complete top-level Roc module, evaluates named output
roots, and captures `dbg` observations. It has native and browser WASM hosts,
a pure Roc document core, loss-preserving format conversion, and conformance fixtures. Source files are never
replayed as a sequence of REPL cells.

The app is **Roclet**. Documents are **Roclet notebooks**, portable archives are
**Roclet bundles** (`.roclet.zip`), and static exports are **Roclet reports**.
Notebooks can be saved as `.roc` or `.md`.

## Build and run

Build requirements: **Zig 0.17.0**, Git, tar, and a Roc compiler checkout containing
the commit in [compiler.lock.json](compiler.lock.json). There is no Node.js,
npm, Python, or separately installed Roc compiler requirement. Zig may download
the compiler's pinned dependencies on the first build; compilation needs several
GiB of RAM. The current native build targets the build machine; macOS ARM64 is
validated so far.

```sh
zig build -Droc-source=/path/to/roc
zig build test
zig build run -- fixtures/forward.json
zig build serve
```

The native CLI is also directly executable, without Zig or a scripting runtime:

```sh
./zig-out/bin/roclet run fixtures/debug.json
```

The CLI accepts `.roc` and `.md` Roclet notebooks as well as M0 JSON snapshots:

```sh
./zig-out/bin/roclet check notebook.roc
./zig-out/bin/roclet convert notebook.roc --to markdown --output notebook.md
./zig-out/bin/roclet convert notebook.md --to roc --output notebook.roc --force
```

Parsing/checking/running return JSON. Conversion returns source without executing
notebook code. Same-format conversion is byte-exact unless `--normalize` is given.
The CLI exits 1 for diagnostics or evaluation failure (2 for missing arguments). `--bridge request.json` exposes the lower-level source protocol for
adapter tests. WASM evaluation runs in the browser; the former Node `--wasm`
wrapper has been removed.

Open `http://127.0.0.1:4173/web/studio.html` for **Roclet**,
`http://127.0.0.1:4173/web/formats.html` for the document playground,
`http://127.0.0.1:4173/` for the compiler probe, or
`http://127.0.0.1:4173/web/conformance.html` for M0 browser tests. M1 parity tests are at
`http://127.0.0.1:4173/web/document-conformance.html`. Roclet recovery and
reactivity checks are at `http://127.0.0.1:4173/web/studio-conformance.html`.
Editor UI checks are at `/web/studio-ui-conformance.html` (add `?compact` for a narrow layout);
offline/sharing contracts are at `/web/m3-conformance.html`; selective evaluation,
tooling and benchmark checks are at `/web/m4-conformance.html`; rich-output
checks are at `/web/m5-conformance.html`; math checks are at `/web/math-conformance.html`. Try **File → Rich outputs example**
for an editable demonstration. An optional port
follows `--`, for example `zig build serve -- 4174`. The installed server also
works directly: `./zig-out/bin/roclet-serve /path/to/roclet 4173`.

`zig build test` runs native conformance and Zig unit tests and writes
`artifacts/native-conformance.json`, `artifacts/document-conformance.json`, and
`artifacts/m4-conformance.json`. The browser page runs JavaScript unit tests,
compares WASM responses with those native results, and exercises real worker
cancellation/restart. Browser tests require opening that page; `zig build test`
does not launch a browser or claim to run its checks. Run `zig build test-unit`
for checks that do not need built compiler artifacts.

Once the adapter is built, ordinary build/test/serve commands verify and reuse
its artifacts. Pass `-Droc-source=/path/to/roc` again after changing adapter
inputs. Repeated source builds reuse the compiler cache. Set `-Dcompiler-jobs=1`
to reduce build concurrency on machines with less memory.

## Dependencies and build boundaries

`build.zig` coordinates compiler preparation, compilation, verification, tests,
and artifact installation. Small Zig tools handle filesystem/process work and
local HTTP serving. The browser uses native JavaScript modules and browser APIs,
with no frontend package manager or bundler. Application policy belongs in Roc;
`core/Document.roc` implements the format rules, while `core/Revision.roc`
remains the revision-policy portability proof.

Markdown parsing uses vendored **MD4C 0.5.2** (MIT), compiled by Zig for both hosts.
It adds no package-manager or runtime installation requirement.

Roclet text editing uses locally vendored CodeMirror 6 and Lezer browser modules
(MIT). [The editor lock and licenses](web/vendor/editor/README.md) record all 14
packages. These are native ES modules served by Zig; no Node, npm, bundler or CDN
is required. Roc highlighting consumes tokens from the existing WASM compiler.

The compiler contributes its own pinned dependencies: Bytebox (including
stable-array), zstd, and its configured LLVM/LLD/Binaryen/zlib bootstrap bundle.
These are managed by the compiler build, not separate browser installations.

The build exports the pinned commit into `.toolchain/compiler`, applies the
exact-match replacements in `compiler-adapter/overlay.json`, and writes the
native/WASM artifacts and SHA-256 hashes to `artifacts/manifest.json`. It never
edits the supplied Roc checkout. Hash verification rejects stale or altered
artifacts. Compiler caches and generated artifacts are excluded from version
control. Build tools still need Git and tar for source preparation.

The browser loads its compiler and runs evaluations locally in dedicated workers.
Choose **File → Offline & storage → Prepare for offline use** to verify and cache
Roclet for offline reopening. **File → Export & share** creates portable notebook
bundles, static reports, and interactive sites. `zig build package` produces
`zig-out/roclet.zip` (the complete Roclet app) and
`zig-out/roclet-headless.zip` (the native runner); see [M3](docs/m3.md).

## Scope

- [Design](design.md): product, formats, architecture, and milestones.
- [M5 rich outputs](docs/m5.md): the Display API, paged tables, portable snapshots, and limits.
- [M4 selective recomputation](docs/m4.md): dependency tracking, editor tools, limitations, and regression benchmark.
- [M3 offline and sharing](docs/m3.md): installation, portable bundles, reports, recovery, packaging, and limits.
- [M2 editing and recovery](docs/m2.md): browser editing, execution, persistence, and limits.
- [M1 format contract and commands](docs/m1.md): conversions, source maps, bounds, and tests.
- [M0 report and limitations](docs/m0.md): evidence, chosen integration, and gates.
- [Adapter contract](compiler-adapter/README.md): ownership, errors, regions,
  revisions, events, and cancellation.
- [Roc revision core](core/Revision.roc): portable policy prototype.

M1 includes expression/debug lowering, optional IDs, saved-output preservation,
generated-entry validation, and a format playground. M2 adds reactive cell
editing, inline results/debug messages, undo, autosave, and recovery. See
[the M2 notes](docs/m2.md) for current execution, editor, and storage limits.
