# Compiler workspace and protocol 1

Roclet embeds the pinned Roc compiler as a Zig package dependency. Run
`sh tools/prepare-compiler.sh /path/to/roc` before building. The script archives the
commit in `compiler.lock.json`, applies `embedding.patch`, and prepares
`.toolchain/roc` without modifying the supplied checkout. `build.zig.zon` imports
that dependency's compiler modules directly. The historical `overlay.json` is not
part of the build.

`bridge.zig`, `engine.zig`, `workspace.zig`, and `snapshot.zig` are shared by native
and WASM hosts. User programs execute through Roc's checked lowering and
interpreter. Generating WebAssembly for user programs is outside this interface.
Compiler embedding additions expose notebook parsing and structured compile-time
observations with their checked module/root provenance. Normal Roc parsing and
checking semantics remain the compiler's responsibility. The upstream license is
included in `ROC-LICENSE`.

## Document preparation

`document_frontend.zig` implements document segmentation, expression lowering,
source maps, export policy, and reactive planning directly in Zig.
`document.zig` coordinates the frontend and compiler. The former interpreted
`core/Document.roc` implementation remains as a reference; it is not executed on
the editing path. Typed source preparation replaces the former interpreted JSON
calls between document stages.

Notebook code cells produce one UTF-8 application source. Supporting modules
remain ordinary files, resolved by Roc's normal import rules. The document API
accepts `{operation: "document", action, format, source, draft?, modules?, files?}`;
actions include `parse`, `convert`, `normalize`, `view`, `export`, `compose`,
`analyze`, `evaluate`, `check`, and `run`. Formats are `roc` and `markdown`.
`operation: "syntax"` returns version-pinned Roc/Markdown syntax facts;
`operation: "markdown"` returns Markdown rendering events.

`compact: true` on `analyze` or `evaluate` omits export encodings, duplicate draft
and source strings, and internal parser facts. Editor cells, mappings,
diagnostics, dependency graphs, plans, rendering, and evaluated values retain
their ordinary shapes. Export/format actions still return complete documents.
The Studio uses compact responses for interactive analysis and evaluation.

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

The retained checked/lowered revision reserves a 512 MiB arena, including space
for dependency packages such as roc-time. Each selected output gets a fresh
interpreter and temporary allocation arena.
Rich outputs also have a checked value entrypoint and a concrete serializer for
the bundled nominal `Display` type. No evaluated Roc value is retained between
responses. `workspaceCache.frontend_builds`, `lowerings`, `executions`, and
`prepared_hits` expose the actual work so tests can verify reuse independently of
wall-clock timing.

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
notebook. The Studio stores relative portable paths and translates them into
workspace paths. It sends only changed files and explicit removals, remounting the
full desired set after worker replacement. **File → Project files** edits these
sources; portable Roclet bundles include them once under `project/`.
Nested module paths use slash imports such as `import Shapes/Wall`. UTF-8 text
files use Roc's file import, for example
`import "data/message.txt" as message : Str`.

Packages use ordinary Roc app-header declarations and compiler-resolved content
identities. A synchronous compile can return `packagesRequired` containing URLs.
The worker downloads those archives asynchronously, asks Roc to validate their
content hashes and unbundle them, then resumes compilation. The configurable
archive downloader uses the bundled server for GitHub releases; static hosts can
select a separate HTTPS endpoint in `web/package-config.json`. Other package
servers must allow browser CORS. Verified archives are cached separately and can be restored
into a fresh worker without network access. JavaScript does not resolve Roc
imports or implement another package manager.

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
- `roclet_process(ptr,n)` returns a JSON response.
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
