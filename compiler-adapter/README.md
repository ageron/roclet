# Compiler workspace and protocol 1

Roclet embeds the pinned Roc compiler as a Zig package dependency. Run
`sh tools/prepare-compiler.sh /path/to/roc` before building. The script archives the
commit in `compiler.lock.json`, applies `embedding.patch`, and prepares
`.toolchain/roc` without modifying the supplied checkout. `build.zig.zon` imports
that dependency's compiler modules directly.

`bridge.zig`, `engine.zig`, `workspace.zig`, and `snapshot.zig` are shared by native
and WASM hosts. User programs execute through Roc's checked lowering and
interpreter. Generating WebAssembly for user programs is outside this interface.
Compiler embedding additions expose notebook parsing and structured compile-time
observations with their checked module/root provenance. Normal Roc parsing and
checking semantics remain the compiler's responsibility. The upstream license is
included in `ROC-LICENSE`.

## Engine instances and process-wide state

All mutable adapter state belongs to an explicit `Engine` (`engine_state.zig`):
the virtual workspace and compiler artifact store, `packagesRequired`, the
retained checked/lowered notebook revision, the last confirmed dependency graph,
the synthetic or native source paths, and the `workspaceCache` counters.
`bridge.process(&engine, request)` serves one top-level request and starts with
`engine.beginRequest()`, which clears `packagesRequired` and the counters. A
native host may construct several engines in one process (`tests/engine.zig`
does); the WASM export layer owns exactly one per worker instance.

JSON exists only at that boundary. `bridge.process` parses the request once,
dispatches on `operation`, and serialises one typed response with
`workspaceCache` and `packagesRequired` appended; everything between is typed
Zig. Document requests become a `document.Request` and leave as a
`document.Response`; notebook evaluation is `notebook.checkDocument`, which
prepares or reuses the retained revision and returns a `Checked` handle whose
`evaluate(roots)` runs the selected roots against the same image; whole
programs (`check`, `run`, `export` verification, `operation: "program"`) run
through `script.run`. Nothing inside the engine re-enters `bridge.process`.

Request-scoped sinks collect what compiler callbacks report: an
`engine.DiagnosticList` (rendered reports and the failure message) behind
`Diagnostics.ctx`, and a per-root `platform.EventBuffer` behind a
`platform.Observer`. The observer carries
the root it stamps on every `value`, `dbg`, `expect_failed`, `crashed` and
`test_*` event; it travels in the interpreter's `EchoEnv`, so RocOps callbacks
read it from `ops.env`, and the notebook pipeline derives one observer per
executed or replayed root. Attribution therefore never depends on global state.
App headers are parsed from memory; nothing is written to the workspace.

Three module-level variables remain, and `zig build check-globals` (part of
`zig build check` and `zig build test`, implemented in `ci/globals.zig`)
rejects any other:

- `platform.active_roc_ops`: hosted platform functions receive no RocOps or
  environment pointer (natural C ABI on native, `(args, ret)` on wasm32), yet
  `Echo.line!` must decref its argument. The interpreter run that owns the
  current RocOps publishes it with `enterRocOps`/`leaveRocOps`, which assert
  that runs never nest. It carries no attribution state.
- `engine.builtin_modules`: the decoded builtin modules are immutable and
  borrowed by every `BuildEnv`, so engines in one process share them.
- `bridge.wasm_engine`: the worker's single `Engine` instance, a struct rather
  than scattered state.

## Document preparation

`document_frontend.zig` implements document segmentation, expression lowering,
source maps, export policy, and reactive planning directly in Zig.
`document.zig` coordinates the frontend and compiler. Typed source preparation
replaces the former interpreted JSON calls between document stages.

Notebook code cells produce one UTF-8 application source. Supporting modules
remain ordinary files, resolved by Roc's normal import rules. The document API
accepts `{operation: "document", action, format, source, draft?, modules?, files?}`;
actions include `parse`, `convert`, `normalize`, `view`, `export`, `compose`,
`analyze`, `evaluate`, `check`, and `run`. Formats are `roc` and `markdown`.
`operation: "syntax"` returns version-pinned Roc/Markdown syntax facts;
`operation: "markdown"` returns Markdown rendering events.
`operation: "program"` with `{protocol: 1, source, user_bytes, args?,
check_only?, app_header?, modules?, root?, files?}` checks and runs one whole
headerless program on the echo platform and returns the protocol-1 program
response; the same request without `operation` is accepted until the M0
`cells` adapter is retired.

`compact: true` on `analyze` or `evaluate` omits export encodings, duplicate draft
and source strings, and internal parser facts. Editor cells, mappings,
diagnostics, dependency graphs, plans, rendering, and evaluated values retain
their ordinary shapes. Export/format actions still return complete documents.
The notebook uses compact responses for interactive analysis and evaluation.

JSON remains the public control/result envelope. It carries document settings,
revision tokens, diagnostics, graphs, and presentation data. Raw file contents,
package archives, and compiler cache artifacts have separate byte-oriented WASM
operations; they are not encoded as JSON arrays or base64.

## One compilation per revision

The notebook declares callable output entrypoints before compilation. A retained
`BuildEnv` checks the module graph once; compiler-produced exported procedure
roots then declare one runtime consumer before finalization. `takeRuntime` runs
once and produces an immutable LIR image containing the output entrypoints.
Metadata queries and later output selections reuse that graph and image. A source,
module, file, or configuration change replaces the retained revision.

A retained revision has three allocation lifetimes. Its inputs, `BuildEnv` and
checked modules (including dependency packages such as roc-time), cache manager,
debug events and root names live in a growable revision arena. Lowering output
(`takeRuntime`, artifact views, static data, entrypoints) lives in a temporary
arena that is freed as soon as `image.zig` has copied it into the flat LIR image.
Only the image must be one contiguous buffer: it is copied in the compiler's copy
mode (`ByteContract.mapped`), header first, into a buffer that starts at 1 MiB on
WASM and 64 MiB natively and doubles when exhausted, up to an image-only cap of
512 MiB on WASM and 2 GiB natively. An image over the cap is reported as
`OutOfMemory`, the failure a full revision buffer produced before.
`zig build -Dimage-initial-bytes=N` overrides the first buffer size so tests can
force doubling. Each selected output gets a fresh interpreter and temporary
allocation arena that views the image in place.
Rich outputs also have a checked value entrypoint and a concrete serializer for
the bundled nominal `Display` type. No evaluated Roc value is retained between
responses. `workspaceCache.frontend_builds`, `lowerings`, `executions`,
`prepared_hits` and `analyses` expose the actual work so tests can verify reuse
independently of wall-clock timing. `prepared_hits` is 1 when the request was
served by the retained revision and 0 when it prepared one. `analyses` counts
dependency analyses (`analysis.zig`): one per new revision, cached on the
revision for every later request and root, plus one per script run. The input
key is hashed once per request. `image_bytes` is the size of the image the
request built (0 when it reused a revision) and `image_retries` the buffer
doublings it took.

Script runs (`check`, `run`, `export` verification) deliberately bypass the
revision: they compile the exact runnable `execution` text users run with
ordinary `roc`, in a fresh pipeline (`engine.runEcho`) whose scratch is an
ordinary arena and whose image comes from the same adaptive `image.build`.
Scripts and revisions share one app header synthesiser,
`engine.synthesizeAppHeader`.

## Notebook assertions

Top-level `expect` statements in code cells are first-class test roots. The source
is preserved: the adapter selects the pinned compiler's checked `.test_expect`
requests, lowers them with output roots in the revision's single LIR image, and
runs each selected assertion in its own interpreter. Tests in imported modules
and packages are not selected.

`evaluation.tests` reports each root's pass/fail status and message; document
responses add its cell and original UTF-8 source location. A false condition,
crash, or failed `?` inside an expect block fails that test without discarding
independent notebook values. Failed assertions produce `partial` evaluation
status and `root_errors` with `status: "test_failed"`. Compile/type errors remain
module-wide diagnostics. Inline expects keep their existing compiler semantics.

Assertions use the same resolved definition dependencies and reactive planner as
outputs. Run all forces every assertion; Run cell forces all assertions in that
cell. Passing statuses can be reused for unchanged dependencies, with source
locations remapped to the current revision. Test-only cells and notebooks work
without output roots. Top-level expects in the App header are diagnosed explicitly;
move them into code cells to execute them.

## Persistent workspace and packages

A browser session keeps one worker and WASM instance across completed requests.
The compiler's builtins and virtual filesystem survive requests. Editable files
live under `/workspace`; `Main.roc` and `main.roc` are reserved for the generated
notebook. The notebook stores relative portable paths and translates them into
workspace paths. It sends only changed files and explicit removals, remounting the
full desired set after worker replacement. **File → Project files** edits these
sources; portable Roclet bundles include them once under `project/`.
Nested module paths use slash imports such as `import Shapes/Wall`. UTF-8 text
files use Roc's file import, for example
`import "data/message.txt" as message : Str`.

Packages use ordinary Roc app-header declarations and compiler-resolved content
identities. A synchronous compile can return `packagesRequired` containing URLs.
The worker downloads those archives asynchronously, asks Roc to validate their
content hashes and unbundle them, then resumes compilation. Downloads are direct
by default (`endpoint: null`). If downloading fails, the notebook offers the
original package URL and a file picker for the downloaded `.tar.zst`. Selected
bytes go to the same compiler verification path; invalid files are rejected
without caching, and the user can retry. Missing transitive dependencies prompt
in turn. The execution timeout pauses during file selection. Cancelling or
editing the document aborts the pending selection and prevents stale bytes from
reaching a replacement worker.

Verified archives are cached separately and can be restored into a fresh worker
without network access. A completely static host supports this flow. An optional
GitHub archive proxy can be configured in `web/package-config.json`; the bundled
server exposes `/api/packages/`, or a deployment can use an external HTTPS
endpoint. JavaScript does not resolve Roc imports or implement another package
manager.

The browser shares an already compiled `WebAssembly.Module` across worker
restarts. Stop/edit cancellation can therefore replace a worker without copying
and recompiling the compiler binary each time.

## Compiler build cache

Roc's canonicalized and checked artifact caches use compiler-authored keys for
source, import, configuration, and file-input invalidation. Browser persistence
stores the opaque artifacts, partitioned by compiler compatibility identity and
the actual WASM binary digest. `workspaceCache` reports compiler hit/miss/store
counters for the whole top-level request. These counters are instrumentation,
not part of semantic result equality.

`web/build-cache.mjs` persists artifacts in IndexedDB with per-entry SHA-256
verification and recency eviction. Compiler artifacts and verified package
archives each have a separate 32 MiB / 512-entry bound across namespaces, so
compiler revision churn cannot evict source archives. Unavailable browser
storage does not prevent compilation. Compiler artifacts are distinct from saved
output snapshots: restoring an output does not count as a compiler-cache hit.
`web/workspace-conformance.mjs` verifies that importing actual emitted artifacts
into a fresh WASM instance reduces misses, alongside module invalidation,
corruption recovery, and offline verified-package restoration.
The live virtual compiler-artifact store has its own 24 MiB / 512-entry LRU
budget; editable files and package inputs are not evicted as compiler artifacts.

The compiler retains its previous dependency graph. The transport omits an
unchanged confirmed graph on subsequent requests; explicit alternate baselines
remain supported. Changes to workspace files participate in reactive invalidation.

## WASM byte operations

Requests are synchronous within an instance and must not overlap.

- `roclet_alloc(n)` / `roclet_free(ptr,n)` own input memory.
- `roclet_process(ptr,n)` returns a JSON response. The request is parsed once
  and the response serialised once; no nested JSON requests are issued.
- `roclet_file_put(pathPtr,pathLen,ptr,len)` mounts raw UTF-8 bytes;
  `roclet_file_drop(ptr,len)` removes a path.
- `roclet_cache_identity()` returns the compiler cache namespace.
- `roclet_cache_import(ptr,len)` imports a binary artifact stream;
  `roclet_cache_take_updates()` exports changed artifacts only.
- `roclet_cache_stats()` returns request-level cache counters.
- `roclet_package_install(urlPtr,urlLen,ptr,len)` validates and mounts an archive.

Response pointers refer to a four-byte little-endian byte length followed by the
payload. `roclet_free_response(ptr)` releases them. Zero indicates allocation or
processing failure. The cache stream is `RLC1` followed by records of little-endian
u32 path length, u32 data length, UTF-8 path bytes, and opaque data bytes.
`compiler-adapter/wasm.mjs` owns copying and freeing; it recreates typed views after
calls that may grow linear memory. No Roc value handles survive a response.

## Revisions, values, and diagnostics

Request ID, document revision, input revision, and worker generation travel with
results. The shell accepts only the current revision. Workers are terminated for
cancellation; a synchronous compiler call cannot interrupt itself. A WASM trap
invalidates the worker. Native requests can be bounded by the caller's process
supervisor.

The compiler supplies definition names, checked types, and UTF-8 source regions.
The document frontend maps those regions to cells. Diagnostic display coordinates
are compiler-provided, one-based line/column positions; do not interpret them as
byte offsets. No terminal diagnostic text is parsed for semantics.

Values retain `{root, text}`. A nominal compiler-checked `Display` value from the
trusted unaliased bundled module may also provide versioned text, Markdown,
bounded table, or embedded raster presentation. Inspected text is never parsed to
infer a renderer. Markdown rendering consists of MD4C events, including math
spans, rendered with locally pinned KaTeX assets.

Observations are buffered and attributed to the selected evaluation root. Detailed
checked provenance lets the engine exclude unrelated compile-time debug events
without matching message text. Shared dependencies can produce observations for
each selected root. Per-root runtime failures remain isolated when requested.
For a crashing constant, the compiler's typed failure summary permits the
declared runtime consumer to read its retained crash value and run independent
roots. All compiler diagnostics remain visible. Parse/type errors, rejected
conversions, exhaustiveness failures, and other compile-time errors remain
module-wide. Ordinary non-isolating requests retain their diagnostic behavior.
All supplied application definitions are checked, including unused definitions.

Document sources are bounded to 256 KiB and 500 cells. The snapshot source limit
is 1 MiB of user source, with generated notebook code bounded separately. Each root retains at most 1,000 observations,
256 KiB of observations, and 64 KiB per text message/result; rich payloads have a
separate 512 KiB bound. Arbitrary platform effects and external foreign functions
are outside this embedding's supported scope.

See [the workspace contract](../docs/compiler-workspace.md) for integration checks
and performance results. The M1–M5 documents describe the established document,
reactivity, sharing, and presentation contracts.
