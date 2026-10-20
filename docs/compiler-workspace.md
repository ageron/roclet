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
also omit the worker's already confirmed dependency graph.

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

## Notebook assertions

Top-level `expect` statements select Roc's checked test roots alongside the
notebook's output roots. They share the revision's checked graph and lowered
image, use resolved dependencies for reactive reruns, and display source-linked
pass/fail results. Assertion failures preserve independent outputs; imported
module/package test suites are not selected. See the
[adapter contract](../compiler-adapter/README.md#notebook-assertions).

## Validation

The merged ReleaseFast native/WASM pair passes:

- 146 native document contracts, 36 compiler cases, and 30 complete selective/full
  evaluation responses.
- 226 complete native/WASM document comparisons and 80 fresh-worker runs,
  including Unicode mappings, failure isolation, missing-module diagnostics,
  checked runnable exports, and the upstream pinned Display package.
- 46 Edit UI contracts at each desktop/compact width, 20 lifecycle contracts,
  18 rich-output contracts, seven math contracts, 11 sharing/offline contracts,
  and the workspace/cache/package suite.
- Desktop/compact top-level assertion and App header probes, including source
  links, dependency changes, selected-cell execution, undo, and persistence.
- Real released roc-parser 2.0.0 with transitive Unicode 4.2.0, and roc-time 0.2.0,
  through local and separate-origin archive proxy configurations.
- Native unit/workspace checks, 11 Node unit contracts, 13 Node workspace tests,
  five ordinary-Roc demo/fixture runs against an extracted Display package,
  artifact verification, and packaging with 83 verified offline assets.

The formatted calendar notebook evaluates six outputs and two assertions with
one frontend build and one lowering, including fresh-worker restoration with
package networking disabled. Compiler artifacts and verified package archives
have separate bounded eviction budgets, so compiler-cache churn does not discard
package inputs. Screenshots were inspected at desktop and compact widths.

The validated browser artifact is 25,097,937 bytes, SHA-256
`cd92bdd279d304fecf80ed7cc6602923808a72fa5131df04fa521eb8fa1f2c7e`.
The performance table above describes its explicitly identified earlier artifact;
those timings were not remeasured after the package/assertion changes.

Workspace correctness tests use ReleaseSafe. The document suite also passes
against the Debug engine. The expanded formatted roc-time notebook currently
reports `OutOfMemory` with the Debug engine; native and browser ReleaseFast
execution pass within the 512 MiB retained-revision arena.

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
