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

Measurements and final command results will be recorded here after integration.
