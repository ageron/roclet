# Compiler workspace implementation contract

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
represented by `files: [{path, source}]` at the Studio boundary and transferred
to WASM only when changed. File removal and workspace replacement are explicit.
Source-only changes must not repeatedly transfer previous compiler graphs or
unused internal syntax data. Result objects retain the fields used by editors,
source mapping, dependency explanations, rich display, import, and export.

Runtime output roots share a checked program and lowering where the compiler's
declared runtime-consumer contract permits it. Debug/compile-time observations,
per-output runtime failures, revision rejection, and cancellation remain part of
the behavior. Compiling user notebook programs to WebAssembly is outside this
change; runtime interpretation remains supported.

## Integration and verification

The integration branch is `integration/compiler-workspace`. Separate worktrees
implement the compiler engine, document frontend, and browser cache/transport.
Small compiler embedding API changes live on `work/roclet-embedding` in a separate
Roc worktree; the user's sibling checkout remains untouched.

Completion requires native and browser evidence for:

- Existing execution, document, reactivity, rich-output, math, sharing, and Studio
  UI contracts, including compact layouts, Unicode spans, and worker cancellation.
- Multiple ordinary modules, nested module paths, and dependency packages, with
  changes to imported files invalidating both builds and displayed results.
- Browser artifact-cache writes and actual cache hits after a fresh worker,
  changed-source/import invalidation, corrupt-cache recovery, and offline reuse.
- Reduced steady-state request bytes and raw file transfers only for changes.
- Warm Wall Area and multi-module timings, reporting build mode and cold startup
  separately. Performance builds use ReleaseFast with debug symbols retained;
  safety validation is a separate build where needed.
- Reproducible builds, portable project bundles, and complete offline assets.

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
use byte-oriented WASM entry points. Compact Studio responses omit unused
intermediate syntax, duplicate source, and export encodings. Subsequent requests
also omit the worker's already confirmed dependency graph.

The worker keeps its virtual filesystem and live compiler cache between edits.
IndexedDB stores checked/canonicalized artifacts under the compiler identity and
actual WASM digest, with entry checksums and a global 32 MiB/512-entry bound. The
live artifact cache has a separate 24 MiB/512-entry bound. Source files and
verified package inputs are not evicted as compiler artifacts. Fresh workers
restore artifacts; changed source and dependencies use the compiler's own keys
for invalidation. Package resolution uses Roc's resolver and hash verification.

The Roc dependency is pinned in `build.zig.zon`. `tools/prepare-compiler.sh`
archives the pinned sibling revision and applies the reviewed embedding patch
inside an immutable prepared checkout. The sibling working tree is not edited.
The patch exposes typed embedding facts for notebook expressions, debug-event
provenance, retained runtime ownership, and compile-time failure classification;
the adapter does not infer compiler state from diagnostic text.

Compiler builtins are compressed in the browser artifact and decompressed once
per worker. The normal WASM file retains function names; its companion
`artifacts/roclet-profile.wasm` retains full debug information for profiling.

## Browser measurements

Measured on 2026-10-19 with Chrome 153.0.8010.52 on Linux x86_64, AMD Ryzen 7
9700X. Both engines used ReleaseFast. The profiling WASM retains DWARF symbols.
The browser benchmark uses three warmup edits followed by 15 measured edits,
verifies both output values after every edit, and waits for durable cache writes
before completing each request. Builds and our other browser suites were idle
during measurement; unrelated user workloads were still running on the host.

| Workload | Warm round trip, median | Worker request, median | Request / response bytes, median |
| --- | ---: | ---: | ---: |
| Wall Area source edit | 19.2 ms | 9.7 ms | 687 / 4,764 |
| Imported Geometry implementation edit | 13.0 ms | 8.1 ms | 304 / 2,558 |

Every measured edit performed exactly one frontend build, one lowering, and two
root executions. Wall Area transferred no project-file bytes. The module edit
transferred only the changed Geometry source (84 bytes at the median); unchanged
Materials source was not resent. Wall Area's original UI request was 1,502 bytes
at the median; retaining the confirmed graph in the worker reduced the JSON sent
to WASM to 687 bytes. These request/response byte counts exclude separate file
and cache streams.

First Wall Area request startup was 609.2 ms. First multi-module request startup
was 388.6 ms. A restarted module worker took 202.3 ms and reported five compiler
artifact hits with zero misses; its outputs matched the previous worker. Startup
includes worker/runtime initialization and cache restoration and is separate
from the warm-edit measurements. It excludes the page's earlier WASM download.
`workerMs` times the worker's evaluation request, excluding the subsequent durable
cache write; the round trip includes that write, transport, and scheduling.

That measured browser compiler was 25,063,956 bytes. Its SHA-256 is
`0fd7ec11335d36f30f7b96bef14f1c0cf33d5e53f3ef6bf075e712d11e9e933f`.
Run the benchmark with:

```sh
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
```

## Workspace baseline validation

The compiler build, native tests, package generation, and artifact manifest
check passed. The native ReleaseFast engine passed 36 compiler cases,
121 document contracts (196 browser parity requests), and 30 complete M4
responses. Unit tests also cover compact responses, source limits, publication
hashing, cache envelopes, cache eviction, and verified package extraction; the
workspace correctness tests use ReleaseSafe. The Node unit/workspace suites
passed. Packaging produced the portable, site, and native-runner archives and
verified 72 offline assets.

The complete 121-document suite also passed against the Debug engine. A final
Studio check caught a retained-compilation error path that discarded reports
when an imported file was missing. The adapter now drains and preserves those
compiler reports before retaining the failed revision. Its regression fixture
requires the missing module's path in diagnostics and an empty value list.

On the corrected published ReleaseFast WASM, Studio passed all 46 UI contracts
at both desktop and compact widths, all 20 revision/persistence/editing/failure/
cancellation contracts, and all 18 rich-output contracts. Screenshots were
inspected for both layouts, including the visible missing-file diagnostic.

The final six-suite Chrome run passed 11 browser unit checks and 36 compiler
parity cases; all 196 complete document responses and 58 fresh-worker runs; all
30 M4 parity cases plus reactive editing, rename, and failure isolation; seven
math contracts; 11 sharing/offline contracts; and the workspace/cache/package
suite. Missing-module diagnostics passed in both retained and fresh workers.
The benchmark and all final browser suites verified the WASM digest above.

Subsequent [real-package browser validation](browser-package-validation.md)
found that direct GitHub release downloads are blocked by CORS. The bundled
server now provides a bounded, hash-verifying archive proxy. A configurable HTTPS
endpoint supports static hosting; original package identities and browser
compilation are preserved. See the validation report for the real-release checks.


## Package-download follow-up

The configurable GitHub archive proxy and roc-time demonstration were validated
on 2026-10-20 with the rebuilt ReleaseFast native/WASM pair. The new WASM digest
is `3791ec6d865abce743e3d8a5c868418aeae740b3ff3bb73b88296ad0e7296b0f`.
The native suites (121 documents, 36 compiler cases, and 30 M4 responses), all six
browser suites above, artifact verification, and packaging passed again. The
publication now contains 75 verified offline assets. The earlier timing table
remains a measurement of its explicitly identified baseline artifact.

The actual Studio downloads released roc-parser/Unicode and roc-time packages
through the supported proxy path. Desktop/local-endpoint and compact/separate-
origin roc-time tests verify editable scheduling results, reversed-date errors,
worker restart, and fresh-worker execution with package networking disabled.
The retained revision arena increased from 256 to 512 MiB so the larger package
graphs also pass native lowering. See the
[package validation report](browser-package-validation.md) for reproduction and
[hosting instructions](installation.md#package-downloads-on-a-static-host) for
the separately deployed HTTPS service required by GitHub Pages.
