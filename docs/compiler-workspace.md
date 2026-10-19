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
