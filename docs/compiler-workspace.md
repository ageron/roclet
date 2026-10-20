# Compiler workspace

Roclet's execution path prepares one UTF-8 module from notebook code cells and
uses the embedded Roc compiler for ordinary module and package semantics. The
document frontend must preserve existing formats, expression lowering, output
selection, and diagnostic source maps without interpreting the document policy
or transporting its syntax model through JSON between compiler stages.

The compiler workspace lives in a persistent worker. Editable files live under
`/workspace`, with `Main.roc` reserved for the generated notebook. Real modules
remain separate files. Package files use compiler-resolved identities and normal
Roc dependency declarations; asynchronous browser acquisition supplies verified
package contents before synchronous compilation resumes.

Compiled artifacts are distinct from displayed output snapshots. The browser
build cache stores canonicalized and checked compiler artifacts, partitioned by
the compiler/ABI identity. Compiler-authored keys govern source, imported-module,
configuration, and file-input invalidation. Restoring this cache must work in a
fresh worker. Corrupt entries must be rejected, and unavailable persistence must
not prevent normal compilation. Package downloads and persistent cache entries
have bounded storage; warm source edits do not need network requests.

Browser requests retain the existing document API. Ordinary project files are
represented by `files: [{path, source}]` at the notebook boundary and transferred
to WASM only when changed. File removal and workspace replacement are explicit.
Source-only changes must not repeatedly transfer previous compiler graphs or
unused internal syntax data. Result objects retain the fields used by editors,
source mapping, dependency explanations, rich display, import, and export.

Runtime output roots share a checked program and lowering where the compiler's
declared runtime-consumer contract permits it. Debug/compile-time observations,
per-output runtime failures, revision rejection, and cancellation remain part of
the behavior. Compiling user notebook programs to WebAssembly is outside this
change; runtime interpretation remains supported.

## What changed

The old Wall Area path spent most of its time running document policy through
the Roc interpreter and serializing intermediate document models. The original
shipped ReleaseSmall build measured about 201 ms for a warm browser edit; its
document parse phase alone took about 109 ms. Worker messaging was about 0.2 ms.
Those measurements identified work to remove; they are not a mode-matched
comparison with the new ReleaseFast build.

Document segmentation, source assembly, source maps, and reactive scheduling now
run directly in Zig. Code cells become one UTF-8 notebook module; imported files
remain ordinary compiler modules. One retained revision owns its checked module
graph and one lowered runtime image. Checking, root selection, and execution use
that revision instead of compiling a new program for each output. Runtime
interpreters remain separate per root, preserving independent failures and
observations.

JSON remains the small public request/result envelope. It no longer transports
the document syntax model between internal compiler stages. The compiler receives
source slices directly. Changed project files and binary compiler-cache entries
use byte-oriented WASM entry points. Compact notebook responses omit unused
intermediate syntax, duplicate source, and export encodings. Subsequent requests
carry no dependency graph at all: the engine keeps the reactive baseline and
returns complete results with `reused` flags.

Inside the engine there is no JSON at all. The request is parsed once at the
boundary and the response serialised once; the document layer reaches the
retained revision through typed calls (`notebook.checkDocument` and
`Checked.evaluate`) rather than re-entering the public entry point once for the
check and once per output root, and the check/run/export script path calls
`script.run` directly. The dependency analysis is computed once per revision
and cached on it (`workspaceCache.analyses`); previously it ran N+2 times for N
evaluated roots, each copy round-tripped through JSON. It builds the dependency
graph (version 2) from checked data: parser-token fingerprints, value edges
from the compiler's strict-demand relation united with name references, and
nodes for local types and imported modules, so comments, annotations, type
declarations and supplied-module edits invalidate only the roots that depend
on them instead of every root.

`tests/pipeline-benchmark.mjs` times one native `--bridge` document `evaluate`
of generated notebooks (`a = 1`, one `out_i = a + i` per cell, a `dbg` in every
tenth cell, one `expect`). Median of five runs, Zig self-hosted backend
(`-Dllvm=false`, several times slower than release builds), same machine:

| Code cells (roots) | Before | After |
| --- | ---: | ---: |
| 10 (9) | 51.0 ms | 56.0 ms |
| 30 (29) | 134.2 ms | 92.4 ms |
| 60 (59) | 377.1 ms | 179.7 ms |

Every run is one frontend build, one lowering and one analysis. Small notebooks
are dominated by fixed costs; the gap grows with the number of roots.

Each worker owns one compiler engine instance. All mutable adapter state (the
virtual filesystem, live compiler cache, retained revision, reactive baseline and
request counters) belongs to that engine rather than to module globals, and
observations are attributed through a request-scoped observer that carries its
root. Native hosts and the in-process `zig build test-engine` suite can hold
several engines in one process.
The worker keeps its virtual filesystem and live compiler cache between edits.
IndexedDB stores checked/canonicalized artifacts under the compiler identity and
actual WASM digest, with entry checksums and a global 32 MiB/512-entry artifact
bound. Verified package archives have their own 32 MiB/512-entry eviction budget. The
live artifact cache has a separate 24 MiB/512-entry bound. Source files and
verified package inputs are not evicted as compiler artifacts. Fresh workers
restore artifacts; changed source and dependencies use the compiler's own keys
for invalidation. Package resolution uses Roc's resolver and hash verification.

The Roc dependency is pinned in `build.zig.zon`. `tools/prepare-compiler.sh`
archives the pinned compiler revision and applies the reviewed embedding patch
inside a prepared checkout. The sibling working tree is not edited.
The patch exposes typed embedding facts for notebook expressions, debug-event
provenance, retained runtime ownership, and compile-time failure classification;
the adapter does not infer compiler state from diagnostic text.

Compiler builtins are compressed in the browser artifact and decompressed once
per worker. The normal WASM file retains function names; its companion
`artifacts/roclet-profile.wasm` retains full debug information for profiling.

## Browser measurements

Measured on 2026-10-20 with Chrome 153.0.8010.52 on Linux x86_64, AMD Ryzen 7
9700X, against the ReleaseFast (LLVM) engine. The browser benchmark uses three
warmup edits followed by 15 measured edits, verifies both output values after
every edit, and waits for durable cache writes before completing each request.
Unrelated user workloads were still running on the host.

| Workload | Warm round trip, median | Worker request, median | Request / response bytes, median | Worker linear memory, median |
| --- | ---: | ---: | ---: | ---: |
| Wall Area source edit | 13.2 ms | 9.1 ms | 614 / 5,132 | 65 MiB |
| Imported Geometry implementation edit | 8.2 ms | 5.4 ms | 234 / 3,198 | 68 MiB |

Every measured edit performed exactly one frontend build, one lowering, one
dependency analysis and two root executions, with no image buffer retries. The
LIR images are about 5 KiB. Before the image buffer and the revision arena were
separated, every retained revision reserved a fixed 512 MiB, so linear memory
could not be below that. Requests carry no dependency graph: the engine owns the
reactive baseline. The module edit transferred only the changed Geometry source
(84 bytes); unchanged Materials source was not resent. Request/response byte
counts exclude separate file and cache streams.

First Wall Area request startup was 480.6 ms and first multi-module request
startup 290.7 ms. A restarted module worker took 216.3 ms, restored compiler
artifacts from IndexedDB, and matched the previous worker's outputs. Startup
includes worker/runtime initialization and cache restoration and excludes the
page's WASM download. `workerMs` times the worker's evaluation request,
excluding the subsequent durable cache write; the round trip includes that
write, transport, and scheduling.

The earlier 2026-10-19 measurement of the original pipeline was 19.2 ms / 9.7 ms
(Wall Area) and 13.0 ms / 8.1 ms (module edit) on the same machine. These runs
are not a controlled same-session comparison.

`tests/pipeline-benchmark.mjs` times generated notebooks through the native
ReleaseFast `--bridge` CLI (median of five cold processes). Each request performs
one frontend build, one lowering and one analysis regardless of size:

| Code cells (output roots) | Median | Response bytes |
| ---: | ---: | ---: |
| 10 (9) | 7.5 ms | 16,715 |
| 30 (29) | 16.1 ms | 49,483 |
| 60 (59) | 29.5 ms | 98,789 |

The measured browser compiler is 25,144,618 bytes, SHA-256
`276514f632236c9d24004c2111df825f6c4c71a63ea9cdbbbf0009f91fea96ec`.
Run the benchmarks with:

```sh
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
node tests/pipeline-benchmark.mjs
```

## Notebook assertions

Top-level `expect` statements select Roc's checked test roots alongside the
notebook's output roots. They share the revision's checked graph and lowered
image, use resolved dependencies for reactive reruns, and display source-linked
pass/fail results. Assertion failures preserve independent outputs; imported
module/package test suites are not selected. See the
[adapter contract](../compiler-adapter/README.md#notebook-assertions).

## Validation

The merged ReleaseFast native/WASM pair passes:

- 170 native document contracts (one an `operation: "program"` run, one each
  for `operation: "syntax"` and `"markdown"`) and 84 complete selective/full
  evaluation responses across 28 recomputation workloads, with every recorded
  request and response matching the wire shape pinned in
  `tests/protocol-shape.json`.
- 264 complete native/WASM document comparisons and 115 fresh-worker runs,
  including Unicode mappings, failure isolation, missing-module diagnostics,
  checked runnable exports, and the upstream pinned Display package; the M4
  responses replay in the same order through one worker, including the engine's
  retained reactive baseline.
- 49 Edit UI contracts at desktop, compact and 600 px widths, 18 side-by-side
  contracts at wide, medium and tabbed widths, the lifecycle contracts, 18
  rich-output contracts, seven math contracts, 11 sharing/offline contracts,
  three ordinary-Roc demos in WASM, and the workspace/cache/package suite.
- Desktop/compact top-level assertion and App header probes, including source
  links, dependency changes, selected-cell execution, undo, and persistence.
- Real released roc-parser 2.0.0 with transitive Unicode 4.2.0, and roc-time 0.2.0,
  through the local archive proxy and through the static-host file picker, in one
  panel and shared by two panels.
- In-process engine tests, native unit/workspace checks, 35 Node tests,
  `zig build check` (formatting, tidy rules, lints, dead files, module globals),
  artifact verification, and packaging with 89 verified offline assets.

The formatted calendar notebook evaluates six outputs and two assertions with
one frontend build and one lowering, including fresh-worker restoration with
package networking disabled. Compiler artifacts and verified package archives
have separate bounded eviction budgets, so compiler-cache churn does not discard
package inputs. Screenshots were inspected at desktop and compact widths.

The validated browser artifact is the one measured above.

Workspace correctness tests use ReleaseSafe. The document suite also passes
against the Debug engine. The expanded formatted roc-time notebook passes with
the native Debug engine since checking and lowering moved out of the fixed
512 MiB revision buffer into growable arenas; only its 461 KiB LIR image is
flat (`compiler-adapter/README.md`).

## Two notebooks side by side

The editor can show two notebooks at once (`web/workbench.mjs`,
`web/notebook-panel.mjs`). Each panel owns a `Notebook`, so it has its own
notebook worker and therefore its own `Engine`, retained revision, reactive
baseline and workspace files; it also saves through its own `DraftStore`
instance. The panels share the syntax highlighter worker, one `PackagePrompts`
coordinator for the page's package dialog, and the compiler `ArrayBuffer`, so
every worker starts from one compiled `WebAssembly.Module`. The compiler
artifact and package caches in IndexedDB are shared by design: a panel opened
after another has run starts warm, and a worker that misses a package re-reads
the persistent cache before downloading or prompting. Requests are unchanged;
the side-by-side layout adds no protocol fields.

`web/dual-conformance.html` exercises the engine changes with two engines alive:
concurrent evaluation equal to each document alone, per-engine `workspaceCache`
counters and retained revisions, reuse that ignores the other panel (including a
comment edit and a type declaration), `reset` on a document switch, `dbg` and
`expect` attribution, per-panel Stop, one shared package prompt, one module
compilation, per-worker `memoryBytes` within 256 MiB each and 512 MiB together,
per-panel project files, focus routing, concurrent saves, the one-panel-per-draft
rule and closing either panel. `tools/browser-dual-package-probe.mjs` repeats
the package flow with the real file picker.

```sh
node tools/browser-check.mjs --page web/dual-conformance.html
node tools/browser-check.mjs --page 'web/dual-conformance.html?medium'
node tools/browser-check.mjs --page 'web/dual-conformance.html?compact'
node tools/browser-check.mjs --page 'web/edit.html?example=meeting-windows&right=example:meeting-windows' \
  --script tools/browser-dual-package-probe.mjs --upload-plan plan.json
```

The upload plan selects the roc-time 0.2.0 bundle once; add `--viewport 390x960`
for the tabs layout.

In the 2026-10-20 run both panels reported 74 and 66 MiB of worker linear memory,
with no image retries, and every side-by-side contract and the two-panel package
probe passed at each width.

## Package hosting

Package downloads are direct by default. When CORS restrictions or network errors
prevent downloading, the notebook shows the original archive URL and a file
picker. The user downloads and selects the bundle; Roc validates its content hash
and archive before mounting it and persisting the verified bytes. Incorrect files
can be retried, missing transitive dependencies prompt separately, and compilation
resumes after loading. The execution timeout pauses while awaiting user input.
This works on GitHub Pages and other completely static hosts without a backend.

The static flow passes real-file-picker Chrome tests at desktop and compact
widths using released roc-time, roc-parser, and Unicode archives. The probes
reject malformed files and a valid archive for the wrong package, verify Cancel
and retry, and restore user-loaded packages after worker restart with package
networking disabled. The desktop
probe waits 16 seconds to check that user interaction does not time out execution.

An optional bounded, hash-verifying GitHub archive proxy is included in
`roclet-serve`. Configure its endpoint for automatic downloads from GitHub Releases;
otherwise users load bundles through the default static workflow. The pinned
Display implementation is embedded and works offline without prompting.

See the [real-package validation report](browser-package-validation.md) for
reproduction and [hosting instructions](installation.md#package-downloads-on-a-static-host)
for the static workflow and optional proxy configuration.
