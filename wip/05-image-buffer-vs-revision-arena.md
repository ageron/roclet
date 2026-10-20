# Plan 05: Separate the flat LIR image buffer from the retained-revision arena

## 1. Status

| Field | Value |
| --- | --- |
| Kind | Temporary WIP handoff plan. Delete this file when the work lands. |
| Branch | `integration/compiler-workspace` |
| Written | 2026-10-20 |
| Sequencing | Independent of the other `wip/` plans. Best done after `wip/01-typed-engine-pipeline.md` so there is one prepare path, but it can be done first on `compiler-adapter/notebook.zig` (and `engine.zig`) alone. Coordinate with `wip/04-engine-state-struct.md`, which moves the same code into an `Engine` struct. |
| Reader | An implementing agent with no other context. Everything needed is in this file or in the cited sources. Line numbers were verified at the commit this plan was written on; re-verify with `grep -n` before editing. Compiler paths are relative to `.toolchain/roc` (the prepared pinned checkout produced by `sh tools/prepare-compiler.sh`). |

## 1a. Implementation status (branch `plan/05-image-buffer`)

Steps 1–5, 7 and 8 are done for `notebook.zig`. **Step 6 (`runEcho`, the
`bridge.zig` 256 MiB / `cold_core` buffers and `RunOptions.runtime_fba`) remains**
and is scheduled after plan 01; when it lands, also update `docs/m4.md:33-35` and
`docs/m1.md:199-202` (runEcho budgets), then delete this file.

Baseline and results, same machine and session, native, **self-hosted backend
(`-Dllvm=false`)**, maximum RSS from `/usr/bin/time -v`:

| Run | Before | After |
| --- | --- | --- |
| Debug, `demos/04-meeting-windows.roc` | `runtime_error`, `failure: "OutOfMemory"`, 700 MB | `ok`, six values, two passing tests, 693 MB |
| Debug, `demos/01-reactivity.roc` | 647 MB | 137 MB |
| ReleaseFast, calendar notebook (median of 7) | 490 MB | 491 MB |
| ReleaseFast, `demos/01-reactivity.roc` (median of 7) | 76 MB | 76 MB |

`image_bytes`: Wall Area (benchmark draft via `--bridge`) 5,312; calendar notebook
471,660; `demos/01-reactivity.roc` 3,704. Defaults chosen from these: WASM first
buffer 1 MiB, native 64 MiB; zero retries for all of them. Forced runs
`-Dimage-initial-bytes=65536` (calendar: 3 retries) and `=1024` (calendar 9, Wall
Area 2) pass every native suite with parity files unchanged. Browser
`memoryBytes` measurements are still to be recorded with an LLVM build.

## 2. Problem statement

Every retained notebook revision reserves one fixed 512 MiB flat buffer and allocates
everything out of it with a bump allocator:

- `compiler-adapter/notebook.zig:322` allocates `512 * 1024 * 1024` bytes with
  `gpa.alignedAlloc` for each new `State`; `notebook.zig:326-327` wraps it in a
  `std.heap.FixedBufferAllocator` and points the debug-event capture at the same allocator.
- `notebook.zig:73` takes `const a = self.fba.allocator()` and then uses `a` for the
  expectations and labels copies, the synthetic source, the extras copies, the `EchoCtx`,
  the `BuildEnv` (`notebook.zig:125`, `build.* = compile.BuildEnv.initBorrowingBuiltinModules(a, ...)`),
  the `CacheManager` (`notebook.zig:135`), the lowered program (`notebook.zig:220`, `takeRuntime(a, ...)`), the
  imported/relation artifact views and static data (`notebook.zig:221-224`), the
  entrypoint array (`notebook.zig:225`), the image header (`notebook.zig:237`) and the image
  itself (`notebook.zig:238-239`).
- The buffer is freed only when the revision is replaced (`notebook.zig:60`).

The same pattern exists in the second compile pipeline, `runEcho`:

- `compiler-adapter/bridge.zig:405-408` allocates a 256 MiB buffer per call (or 1 GiB on
  wasm / 2 GiB native when `cold_core` is true), wraps it in a `FixedBufferAllocator` and
  passes it as `runtime_fba`.
- `compiler-adapter/engine.zig:154` takes `allocator = opts.runtime_fba.allocator()` and
  uses it for the `BuildEnv` (`engine.zig:190`), the `CacheManager` (`engine.zig:203-204`),
  lowering (`engine.zig:273-282`), static data (`engine.zig:297-300`), and the image
  (`engine.zig:302-309`).
- The `cold_core` sizes are dead in practice: they are only reached through
  `processCore` (`bridge.zig:313-315`), whose result `document.process` ignores
  (`compiler-adapter/document.zig:117`, fourth parameter `_: anytype`). `docs/m4.md:33-35`
  still documents those budgets.

Documented consequences:

- `docs/browser-package-validation.md:176-183`: the original 256 MiB arena "exhausted
  memory while lowering roc-time and the larger typed CSV parser example", so it was raised
  to 512 MiB; "the expanded formatted notebook reports `OutOfMemory` with the Debug engine".
- `docs/compiler-workspace.md:159-161` repeats that the formatted roc-time notebook OOMs
  under Debug and that ReleaseFast "pass[es] within the 512 MiB retained-revision arena".
- `compiler-adapter/README.md:55-57` documents the 512 MiB reservation as part of the contract.

Why one flat buffer is wasteful rather than merely large:

- `FixedBufferAllocator` is a bump allocator. `free` reclaims only the most recent
  allocation and `resize` can only grow the most recent allocation in place
  (Zig 0.17 `lib/std/heap/FixedBufferAllocator.zig:62-70` and `:114-127`). Checking and
  lowering grow many `ArrayList`s; every growth of a list that is not the last allocation
  copies and abandons its old capacity. So the 512 MiB is not "the size of the image"; it is
  image + all of checking + all lowering churn + abandoned capacities, with nothing reclaimed
  until the revision is dropped. Debug builds allocate more and so hit the ceiling first.
- Only a small, well-defined subset of that data must be in a flat buffer at all
  (Section 4). Everything else is in the buffer because `prepare` has a single allocator.

## 3. Why it matters

- **Memory floor.** On wasm32, `std.heap.wasm_allocator` is `BrkAllocator`
  (`lib/std/heap.zig:18` and `:357`). Allocations above the 64 KiB "bigpage"
  (`lib/std/heap/BrkAllocator.zig:38`) are served from power-of-two big classes; a class
  miss calls `@wasmMemoryGrow` (`BrkAllocator.zig:156-175`), and linear memory never
  shrinks. The first revision of any notebook, including the four-cell Wall Area demo, grows
  linear memory by 512 MiB. `memory.buffer.byteLength` and the browser's per-tab memory
  accounting carry that for the life of the worker. Whether untouched pages are physically
  backed is engine-dependent, but the bump allocator walks forward through the region as
  lowering churns, so a large fraction is touched in practice.
- **Memory ceiling.** 512 MiB is also a hard ceiling for *checking + lowering churn +
  image* combined, including dependency packages. The roc-time calendar notebook already
  fails under Debug. Larger packages or more cells will hit it under ReleaseFast too, and
  the only remedy today is another constant bump that raises the floor for everyone.
- **No reclamation.** Per-revision garbage (lowering intermediates, abandoned list
  capacities, static-data scratch) stays resident until the next revision replaces the whole
  block, so the "live" memory for a notebook is always its peak.
- **Native.** `gpa` on native is `std.heap.page_allocator` (`bridge.zig:14`), so the
  reservation is `mmap` and the OS commits pages lazily (the compiler README says the same,
  `.toolchain/roc/src/compile/README.md:175`). Native cost is RSS proportional to
  touched pages rather than the reservation, which is why the problem is mostly invisible
  natively and acute in the browser.
- `alignedAlloc` does not zero memory, so the reservation itself is not a zeroing cost;
  wasm `memory.grow` pages arrive zeroed from the engine.

Nothing here is a correctness bug. It is a structural limit that already bites in Debug and
will bite ReleaseFast as notebooks and packages grow.

## 4. Current design and the established facts

### 4.1 Embedding sequence used by Roclet

`State.prepare` (`notebook.zig:72-240`) performs: build synthetic source → `BuildEnv` init →
`discoverDependencies` / `compileDiscovered` → select root requests → `setRuntimeLowering`
→ `finishCheckedProgram` → `takeRuntime` → `collectImportedArtifactViews` /
`collectRelationArtifactViews` → `eval.buildStaticDataForWidth` → entrypoint array →
`lir.LirImage.referenceProgramWithStaticDataInBuffer` → `copied.fillHeader(header, fba.end_index)`.
`State.execute` (`notebook.zig:246-311`) then, per root, creates a scratch
`ArenaAllocator` (`notebook.zig:261-263`) and calls
`lir.LirImage.viewMappedImageWithAllocator(self.header, self.buffer.ptr, image_size, target_usize, a)`
(`notebook.zig:264`), builds `InterpreterStaticData`, static strings, and an interpreter
from that view, and runs the entrypoint. The per-root scratch is already separate and is
not part of this change.

`runEcho` (`engine.zig:154-327`) does the same sequence once per call, then executes `main!`.

### 4.2 What the compiler requires to be flat (verified in `.toolchain/roc`)

**Reference mode (what Roclet uses today) requires the whole lowered program to be inside the flat buffer.**
`lir.LirImage.referenceProgramWithStaticDataInBuffer` (`src/lir/lir_image.zig:1066-1088`)
copies only the static data (`StaticDataImage.copy`, `src/lir/lir_image_static_data.zig:54-84`,
which itself allocates through the supplied allocator and validates with `copyArrayRef`).
Everything else is encoded with `arrayRef` against the arrays the lowered program already
owns:

- `lowered.root_procs.items`, the `platform_entrypoints` slice, `lowered.boxy_worker_procs.items`
  (`lir_image.zig:1079-1081`);
- the entire `LirStore` through `LirStoreImage.fromStore` (`lir_image.zig:206-237`): 27 arrays
  plus the string-literal buffer (`:324-328`) and Boxy names (`:354-359`);
- the layout store (`LayoutStoreImage.fromStore`, `:389`) and Boxy tables
  (`BoxyTablesImage.fromProgram`, `:576`).

`arrayRef` (`lir_image.zig:1195-1210`) returns `error.InvalidLirImage` if a slice's address
is below `base_ptr` or `offset + byte_len > image_size`. This is the `ptr - base_ptr`
arithmetic the compiler README warns about (`src/compile/README.md:159-176`). It is why
`takeRuntime`, `platformEntrypoints`/`a.alloc`, and `buildStaticDataForWidth` are all
called with the FBA allocator in Roclet: in reference mode the lowering output *is* the image.

**Copy mode does not.** `lir.LirImage.copyProgramWithStaticDataIntoBuffer`
(`lir_image.zig:1090-1118`) duplicates every array into the image allocator with
`copyArrayRef` (`lir_image.zig:1220-1237`, `allocator.dupe` then `arrayRef`), through
`LirStoreImage.copyFromStore` (`:240-279`), `LayoutStoreImage.copyFromStore` (`:403`) and
`BoxyTablesImage.copyFromProgram` (`:598`). The documented intent of the copy entry points
(`lir_image.zig:1042-1048`): "Compiler scratch and intermediate IR stay in their ordinary
reclaimable allocator; the image owns only the arrays its mapped consumer reads." With
`ByteContract.mapped` (`lir_image.zig:84-100`) the copy is verbatim; no canonicalization.
`CopiedProgram.fillHeader` (`lir_image.zig:1024-1047`) rejects an `image_size` larger than
the capacity the copy was validated against.

The compiler's own run path uses copy mode: `src/cli/main.zig:7083-7100` (`publishLirImage`,
`.mapped`, into a shared-memory allocator created with a size fallback at
`src/cli/main.zig:1206-1208`), `src/cli/main.zig:11350-11358` (`.persisted`, for embedded
images), and a unit test that copies into a 1 MiB `FixedBufferAllocator`
(`src/eval/compile_time_finalization.zig:5700-5705`). Reference mode is what the
`echo_platform` runner and the embedding smoke test use
(`src/echo_platform/runner.zig:265`, `src/compile/test/embedding_smoke.zig:117-163`, with a
128 MiB arena). Both modes produce the same `Header` and are viewed by the same
`viewMappedImage`.

**The image must stay at a fixed address while it is viewed.**
`viewMappedImageWithAllocator` (`lir_image.zig:1133-1192`) builds `LirStore` and the Boxy
tables as slices into `base_ptr` (`LirStoreImage.view`, `:280-318`, via
`guardedListFromRef`/`sliceFromRef`); only the layout store's compact columns and the static
data export rows are reconstructed with the scratch allocator (`ProgramView.scratch_allocator`,
`lir_image.zig:141-175`; `StaticDataImage.view`, `lir_image_static_data.zig:86-138`). The
interpreter borrows `&view.store` and `&view.layouts` (`src/eval/interpreter.zig:871-890`).
So: the image buffer is owned by the revision, lives as long as the revision, and is never
moved. That is already the case today.

**After a copy the lowered program and static data can be dropped.**
`LoweredProgram.deinit` (`src/lir/checked_pipeline.zig:1169-1180`) and `Program.Result.deinit`
(`src/lir/program.zig:768-800`) free through `store.allocator`, so lowering can use an
ordinary reclaimable allocator. `platformEntrypointNames` says explicitly that "run images
outlive their checked modules" (`checked_pipeline.zig:1207-1210`). In Roclet, nothing in
`State.execute` reads `self.lowered`; it reads `self.header` and `self.buffer` only
(`notebook.zig:264`). `eval.deinitStaticData` (`engine.zig:300`) frees the static-data
exports after they have been copied.

**Nothing else needs to be flat.** `BuildEnv`, `CacheManager`, `EchoCtx`, the synthetic source
and extras copies, labels, expectations, and the `DebugCapture` events are only in the FBA
because `prepare` has one allocator. `BuildEnv` must still be *retained* for the revision:
`State.execute` replays debug events through it (`notebook.zig:259-260` →
`engine.DebugCapture.replay`, which calls `build_env.getCompiledModules`) and `run` calls
`opts.analyze` on its app environment (`notebook.zig:346`). Retained is not the same as flat.

**`takeRuntime` is single-shot** (`src/eval/compile_time_finalization.zig:326-331`; it sets
`self.runtime_target = null` at `:357`). Unchanged by this plan.

### 4.3 Where the 512 MiB goes today

In order of allocation inside the one FBA: synthetic source and extras copies; `BuildEnv`
and all checked-module state for the app and every package module it compiles (builtins are
borrowed from the process-wide `persistentBuiltins()`, `engine.zig:589-592`, and are not in the
buffer); `CacheManager`; lowering (`LoweredProgram` with all its lists, grown in place with
abandoned capacities); artifact views; static data exports; entrypoints; header; the
static-data copy. The `image_size` recorded in the header is `self.fba.end_index`
(`notebook.zig:239`), i.e. the entire used buffer, not the image.

## 5. Target design

Three allocation lifetimes replace the single flat buffer:

| Lifetime | Allocator | Contents | Freed |
| --- | --- | --- | --- |
| Revision (retained) | `std.heap.ArenaAllocator` over `gpa` (`revision_arena`) | expectations, labels, synthetic source, extras, `EchoCtx`, `BuildEnv`, `CacheManager`, `DebugCapture` events, entry names, reports | when the revision is replaced |
| Lowering (temporary) | `std.heap.ArenaAllocator` over `gpa` (`lowering_arena`) | `takeRuntime` output, imported/relation views, static data exports, entrypoint array | immediately after the image copy succeeds (or fails) |
| Image (retained, flat) | `gpa.alignedAlloc` buffer + `FixedBufferAllocator` sized adaptively | `Header` (first allocation), copied LIR store, layouts, Boxy tables, root procs, entrypoints, static data | when the revision is replaced |
| Per-root scratch | existing `ArenaAllocator` in `State.execute` | view, static data image, strings, interpreter | per root (unchanged) |

### 5.1 New module: `compiler-adapter/image.zig`

One helper shared by `notebook.zig` and `engine.zig` (and by the single prepare path once
`wip/01` lands):

```zig
//! Flat LIR image ownership. The lowered program is copied into an exactly
//! sized contiguous buffer; compiler scratch stays reclaimable.
const std = @import("std");
const lir = @import("lir");

pub const Limits = struct {
    /// First buffer size tried. Power of two; see 5.3.
    initial_bytes: usize,
    /// Give up with error.OutOfMemory above this size.
    max_bytes: usize,
};

pub const Image = struct {
    buffer: []align(16) u8,            // owned flat region
    header: *lir.LirImage.Header,      // first allocation inside `buffer`
    size: usize,                       // bytes used == header.image_size
    attempts: u8,                      // 1 + retries, for stats

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }
    pub fn view(self: *const Image, target_usize: @import("base").target.TargetUsize, scratch: std.mem.Allocator) !lir.LirImage.ProgramView {
        return lir.LirImage.viewMappedImageWithAllocator(self.header, self.buffer.ptr, self.size, target_usize, scratch);
    }
};

/// Copy `lowered` (plus entrypoints and frozen static data) into a flat buffer,
/// retrying with a doubled buffer when the copy runs out of room.
pub fn build(
    gpa: std.mem.Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    entrypoints: []const lir.LirImage.PlatformEntrypoint,
    static_data: []const lir.Program.StaticDataExport,
    limits: Limits,
) (lir.LirImage.CopyError || error{ImageTooLarge})!Image {
    var capacity = @min(limits.max_bytes, @max(limits.initial_bytes, lowerBound(lowered, static_data)));
    var attempts: u8 = 0;
    while (true) {
        attempts += 1;
        const buffer = try gpa.alignedAlloc(u8, .@"16", capacity);
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        const a = fba.allocator();
        const header = a.create(lir.LirImage.Header) catch unreachable; // capacity >= 1 MiB
        const copied = lir.LirImage.copyProgramWithStaticDataIntoBuffer(a, buffer.ptr, buffer.len, .mapped, &lowered.lir_result, entrypoints, static_data) catch |err| switch (err) {
            error.OutOfMemory => {
                gpa.free(buffer);
                if (capacity >= limits.max_bytes) return error.ImageTooLarge;
                capacity = @min(limits.max_bytes, capacity * 2);
                continue;
            },
            else => {
                gpa.free(buffer);
                return err;
            },
        };
        copied.fillHeader(header, fba.end_index) catch |err| {
            gpa.free(buffer);
            return err;
        };
        return .{ .buffer = buffer, .header = header, .size = fba.end_index, .attempts = attempts };
    }
}
```

Notes on this sketch:

- `copyProgramWithStaticDataIntoBuffer` returns `CopyError = Allocator.Error || ImageError`
  (`lir_image.zig:79`); an exhausted FBA surfaces as `error.OutOfMemory`, which is the retry
  signal. `error.InvalidLirImage` / `UnsupportedLirImageVersion` are real failures and are not
  retried.
- A failed attempt discards the whole buffer. The wasted work is one partial `memcpy` per
  retry; doubling bounds retries at `log2(max/initial)`.
- The header is the first allocation in the image buffer, matching the compiler's own
  `publishLirImage` (`src/cli/main.zig:7092`). `viewMappedImage` requires
  `mapped_size >= @sizeOf(Header)` and `header.image_size <= mapped_size`
  (`lir_image.zig:1140-1144`).
- `lowerBound` is optional (5.3). Start without it (`lowerBound` returns 0) and add it only if
  the `image_retries` counter shows retries on ordinary notebooks.
- `error.ImageTooLarge` is mapped by callers to the existing user-visible failure path
  (today an `OutOfMemory` becomes `status: "runtime_error"` with `failure: "OutOfMemory"`
  via `bridge.zig:396` and `:429`). Keep that mapping: map `ImageTooLarge` to the same string so the
  protocol does not change, or surface a clearer message if the implementer prefers; either
  way document it.

### 5.2 `notebook.zig` changes

`State` becomes:

```zig
const State = struct {
    key: [32]u8,
    revision_arena: std.heap.ArenaAllocator,   // replaces buffer + fba
    image: ?image.Image = null,                // replaces lowered + header
    build: ?*compile.BuildEnv = null,
    capture: engine.DebugCapture,              // allocator = revision_arena
    reports, failed, constant_failures, prefix, labels, expectations,
    expectation_expressions, wire_name, requests, request_names,
    entry_names, cache_reported ...            // unchanged
    fn deinit(self: *State) void {
        if (self.image) |*img| img.deinit(gpa);
        if (self.build) |build| { if (self.reports.len != 0) build.freeDrainedReports(self.reports); build.deinit(); }
        self.revision_arena.deinit();
    }
};
```

`prepare` keeps `const a = self.revision_arena.allocator();` for everything up to and including
`finishCheckedProgram`. The tail becomes:

```zig
var lowering = std.heap.ArenaAllocator.init(gpa);
defer lowering.deinit();                       // frees lowered program, views, static data, entrypoints
const la = lowering.allocator();
engine.request_lowerings += 1;
var lowered = try build.runtimeProgramSession().?.takeRuntime(la, request_set, runtime_target);
const imports = try build.collectImportedArtifactViews(la, artifact);
const relations = try build.collectRelationArtifactViews(la, artifact);
const data = try eval.buildStaticDataForWidth(la, .{ .root = ..., .imports = imports }, &lowered, lowered.target_usize, .{});
const entrypoints = try la.alloc(lir.LirImage.PlatformEntrypoint, lowered.lir_result.root_procs.items.len);
// entry_names stays on `a` (revision arena): execute() reads it.
... existing ordinal/name mapping ...
self.image = try image.build(gpa, &lowered, entrypoints, data, image_limits);
engine.request_image_bytes = self.image.?.size;   // new stats, see 5.5
engine.request_image_retries += self.image.?.attempts - 1;
```

`execute` replaces `notebook.zig:264` with `var view = try self.image.?.view(opts.target_usize, a);`.
`run` (`notebook.zig:313-335`) no longer allocates 512 MiB; it initialises
`revision_arena = std.heap.ArenaAllocator.init(gpa)` and sets
`state.capture.allocator = state.revision_arena.allocator()`. The `errdefer gpa.free(buffer)`
becomes `errdefer state.revision_arena.deinit()`; on `prepare` failure also `deinit` any
`state.image` (the existing catch at `notebook.zig:328-331` only deinits `build`; fix the leak
of `lowered` while there).

`BuildEnv.deinit()` on an arena-backed `BuildEnv` performs frees that the arena ignores; the
arena's `deinit` reclaims everything. That is acceptable and is how the FBA behaves today.

### 5.3 Sizing policy

- `initial_bytes`: a power of two. Reason: `BrkAllocator` rounds big allocations up to a
  power-of-two bigpage count anyway (`BrkAllocator.zig:156-158`), so a 48 MiB request occupies
  a 64 MiB slot; asking for powers of two keeps requested and resident sizes equal and keeps
  each size class reusable across revisions.
- Defaults to start with: **wasm32 16 MiB, native 64 MiB**. Native over-allocation is
  virtual (`mmap`, lazily committed) so a larger initial buffer costs nothing and avoids
  retries; wasm growth is permanent, so start small. Measure the actual `image_bytes` for the
  Wall Area demo and the roc-time calendar notebook first (Section 8) and set the wasm
  initial size to the smallest power of two that gives Wall Area zero retries.
- `max_bytes`: **wasm32 512 MiB, native 2 GiB**. 512 MiB keeps today's documented ceiling as
  the image-only ceiling; since checking and lowering churn are no longer inside it, the
  effective headroom for notebooks is much larger than today.
- Optional `lowerBound(lowered, static_data)`: sum of the dominant arrays
  (`lowered.lir_result.store.cf_stmts`, `proc_specs`, `locals`, `u64s`, `u32s`, the
  string-literal buffer, the layout store's main arrays, and `bytes.len + symbol_name.len` per
  static-data export) times 1.5, plus `@sizeOf(Header)`. These fields are the ones
  `copyFromStore` reads (`lir_image.zig:249-278`), via `unsafeRawItemsForView()`. Add only if
  retries are observed on ordinary notebooks. Do **not** add a size-query function to the
  compiler patch unless both the estimate and doubling prove inadequate; no such helper exists
  in `lir_image.zig`, `LirStore.zig` or `program.zig` today (grep confirmed), and the compiler
  itself sizes by reservation plus fallback (`src/cli/main.zig:1206-1208`).
- Put the constants in `image.zig` as `pub const default_limits: Limits` selected on
  `builtin.cpu.arch == .wasm32`, and allow a build option override
  (`-Dimage-initial-bytes=N`) through a Roclet `addOptions` module so tests can force the
  retry path (Section 8).

### 5.4 `engine.zig` / `runEcho`

If `wip/01` has already folded `check`/`run`/`export` into the retained revision, `runEcho` is
gone and nothing more is needed. Otherwise apply the same split inside `runEcho`:

- `RunOptions.runtime_fba` (`engine.zig:111-116`) is replaced by nothing; `runEcho` creates a
  local `std.heap.ArenaAllocator` for `BuildEnv`/`CacheManager`/views/lowering/static data and
  calls `image.build(gpa, ...)` for the image, viewing it through `Image.view`.
- `bridge.zig:405-408` (the 256 MiB / 1 GiB / 2 GiB buffers) is deleted. `cold_core` goes with
  it (it is unreachable; see Section 2).

Both call sites then share one image builder, which is what `wip/01` needs when it
consolidates the two pipelines.

### 5.5 Stats

Add two optional work counters next to the existing `frontend_builds`/`lowerings`/`executions`/
`prepared_hits` (`engine.zig:728-749`): `image_bytes` (size of the current revision's image)
and `image_retries` (buffer doublings this request). They ride in `workspaceCache`, whose
extra numeric fields are already permitted by `compiler-adapter/protocol.d.ts`
(`CompilerCacheStats` index signature) and are stripped from semantic comparisons by
`tests/harness.mjs` (`compilerSemantics`). Expose them in the benchmark sample
(`tests/workspace-benchmark.mjs:11-15`) by adding `imageBytes` and `imageRetries` next to
`preparedHits`.

### 5.6 Memory telemetry (browser)

`compiler-adapter/wasm.mjs` holds `wasm = instance.exports` (`wasm.mjs:8`). Add
`transport.memoryBytes = () => wasm.memory.buffer.byteLength;` beside the other transport
helpers, and in `web/format-worker.mjs:35` add `memoryBytes: transport.memoryBytes?.()` to
`transportMetrics`. `tests/workspace-benchmark.mjs` spreads `transportMetrics` into each
sample and `summarize` computes medians for every sample key, so `memoryBytesMedian` appears
in the benchmark output with no further change. `compilerSemantics` already strips
`transportMetrics`, so parity suites are unaffected.

## 6. Constraints and non-goals

- Zero protocol change at the WASM/native boundary. Response shapes, statuses, values,
  events, diagnostics, source maps and the existing counters are unchanged; the only
  additions are optional numeric counters in `workspaceCache` and `memoryBytes` in
  `transportMetrics`, both already excluded from semantic parity.
- All parity suites stay green (native vs WASM responses compared field for field).
- No behaviour change except memory use and, as a side effect, a Debug-mode run that used to
  OOM now succeeding.
- Must keep working on wasm32 with `target_usize = .u32` (`copyProgramWithStaticDataIntoBuffer`
  records `static_data_pointer_bytes` from `lowered.layouts.targetUsize()`; `viewMappedImage`
  checks it, `lir_image.zig:1145`; unchanged).
- Respect the compiler README invariant: the image buffer is a `FixedBufferAllocator` over one
  contiguous allocation; never an `ArenaAllocator`.
- No growth of `compiler-adapter/embedding.patch`. Copy mode is public compiler API.
- Per-root execution keeps its own scratch arena; no retained Roc values (unchanged).
- Non-goal: a total per-revision memory budget. After this change the image has a hard cap
  but the revision and lowering arenas are bounded only by `gpa`. A counting wrapper
  allocator can add a total budget later if measurements show a need (Section 10).
- Non-goal: changing the compiler cache manager, package extraction, or the per-root
  interpreter.

## 7. Step-by-step implementation plan

Each step leaves `zig build test` green.

1. **Record a baseline.** Before touching code: run the browser benchmark and the native
   roc-time run with the measurement commands in Section 8 (after adding only the telemetry
   from 5.6, which is behaviour-neutral). Save the numbers in this file under a "Baseline"
   heading. Also confirm the Debug OOM reproduces with the exact command in 8.2.
   Tests: `zig build test`, `node --test tests/workspace.test.mjs`.
2. **Add `compiler-adapter/image.zig`** with `Limits`, `Image`, `build`, `default_limits`, and a
   unit test of the retry policy that injects a copy function (make `build` take the copy
   function as a comptime parameter, or split the loop into `buildWith(copyFn)` so the test can
   pass a stub that fails below N bytes). Register the file in `build.zig`'s `test-unit` list
   (the `inline for` over `compiler-adapter/snapshot.zig`, `document.zig`, ...).
   Tests: `zig build test-unit`.
3. **Switch `notebook.zig` to copy mode behind the old allocator.** Keep the 512 MiB FBA for
   everything, but replace `referenceProgramWithStaticDataInBuffer` + `fillHeader` with
   `image.build(gpa, ...)` and `execute`'s view with `Image.view`. This isolates "copy vs
   reference" from "arena vs FBA". Expect identical results.
   Tests: `zig build test` (documents, m4, native), browser parity pages (Section 8).
4. **Introduce the lowering arena.** Move `takeRuntime`, views, static data and entrypoints
   onto a temporary `ArenaAllocator` freed after `image.build`. Delete `State.lowered`.
   Tests: same as step 3; check `lowerings == 1` and `executions` unchanged in the benchmark.
5. **Replace the 512 MiB FBA with the revision arena.** `State.revision_arena`, `capture`
   allocator, `run` initialisation, error-path cleanup. Delete the constant at
   `notebook.zig:322`.
   Tests: same; plus the Debug roc-time run (8.2) now passes; plus memory measurements (8.3).
6. **Apply the same split to `runEcho`** (skip if `wip/01` has removed it). Delete
   `bridge.zig:405-408` and `RunOptions.runtime_fba`.
   Tests: `zig build test-documents` exercises `check`/`run`/`export`; `tests/native.zig`
   exercises the raw path ("runtime dbg" case).
7. **Add the counters and build option** (5.5, 5.3). Wire `-Dimage-initial-bytes` through a
   Roclet options module and run the full suite once with a tiny initial size to prove the
   retry path under real workloads (8.4).
8. **Docs and cleanup** (Section 11).

## 8. Validation

### 8.1 Existing suites (all must pass at every step)

```sh
zig build test                 # unit, workspace (ReleaseSafe), package fixture, native, documents, m4
zig build test-documents
zig build test-m4
zig build test-unit
zig build test-workspace
node --test tests/workspace.test.mjs
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
```

The benchmark page asserts `frontendBuilds == 1`, `lowerings == 1`, `rootExecutions == 2` per
edit and verifies every value (`tests/workspace-benchmark.mjs:31-33`, `:47-48`); those
assertions must keep passing unchanged.

### 8.2 The Debug reproduction

`demos/04-meeting-windows.roc` is the formatted calendar notebook (roc-time dependency,
`roclet.Display`, six outputs and two assertions; `docs/compiler-workspace.md:147-148`,
`tools/browser-time-probe.mjs`). Reproduce the documented OOM before changing anything:

```sh
zig build -Doptimize=Debug                     # native + wasm adapters in Debug
zig-out/bin/roclet run demos/04-meeting-windows.roc
```

The first native run downloads roc-time into `~/.cache/roclet/packages/<hash>`
(`workspace.zig:445-488`); later runs are offline. Today this is documented to fail with
`OutOfMemory` (`docs/compiler-workspace.md:159-161`). After step 5 it must print a JSON
response with `"status":"ok"`, six `evaluation.values`, and two passing `evaluation.tests`.
If the OOM does not reproduce on the implementer's machine, say so in this file and keep the
check as a regression guard anyway. Then `zig build` again (ReleaseFast) before the other
suites.

### 8.3 Measurements to record (before and after, same machine, same session)

- Browser, from the benchmark JSON (after 5.6): `wallArea.startup.memoryBytes`,
  `wallArea.warm.memoryBytesMedian`, `multiModule.warm.memoryBytesMedian`,
  `multiModule.restoredWorker.memoryBytes`, plus `imageBytesMedian` / `imageRetriesMedian`
  (after 5.5), plus the existing `roundTripMsMedian` / `workerMsMedian` and the startup samples.
  Compare the timing medians with the recorded ones in `docs/compiler-workspace.md`
  (Wall Area 19.2 ms round trip / 9.7 ms worker; module edit 13.0 / 8.1) only as a sanity
  check; the gate is before/after on the same machine.
- Native RSS for the roc-time notebook:
  `/usr/bin/time -v zig-out/bin/roclet run demos/04-meeting-windows.roc 2>&1 | grep 'Maximum resident'`
  in ReleaseFast and in Debug.
- Native RSS for Wall Area: `/usr/bin/time -v zig-out/bin/roclet run demos/01-reactivity.roc`.
- Report the roc-time notebook's `image_bytes` (native `--bridge` output `workspaceCache`).

### 8.4 New tests

- `image.zig` unit test: a stub copy that needs N bytes succeeds via retry from
  `initial_bytes < N`, reports `attempts == 1 + ceil(log2(N / initial))`, and fails with
  `error.ImageTooLarge` when `max_bytes < N`; a stub returning `error.InvalidLirImage` is not
  retried.
- Forced-retry run: `zig build test -Dimage-initial-bytes=65536` (exact option name per step
  7). Every real workload then exercises at least one doubling; all suites must pass and the
  m4 parity file must still match native vs WASM.
- Memory bound test (Node, real WASM not available in Node here, so do this in the browser
  benchmark): after 15 warm Wall Area edits, `memoryBytesMedian` ≤ the gate in Section 9.
  Put the assertion in `tests/workspace-benchmark.mjs` with the bound as a parameter so the
  page fails loudly if a future change reintroduces a fixed reservation.

## 9. Acceptance gates

All must be true:

- [ ] `zig build test` passes in ReleaseFast (default) and `zig build -Doptimize=Debug test-documents` passes.
- [ ] `zig build -Doptimize=Debug` then `zig-out/bin/roclet run demos/04-meeting-windows.roc` returns `status: "ok"` with six values and two passing tests (the documented Debug OOM is gone).
- [ ] Browser parity pages (document, m4, workspace conformance) pass; native vs WASM responses still match.
- [ ] Benchmark assertions unchanged: `frontendBuilds == 1`, `lowerings == 1`, `rootExecutions == 2`, all values verified, restored worker reports cache hits.
- [ ] Wall Area warm `memoryBytesMedian` after the change is at most half of the recorded baseline, and the `512 * 1024 * 1024` literal no longer exists in `compiler-adapter/`.
- [ ] roc-time calendar notebook memory (browser `memoryBytes` if measurable, otherwise native Debug RSS) is not higher than baseline.
- [ ] Warm round-trip and worker medians for both benchmark workloads are within 10 % of the same-session baseline (the extra image `memcpy` is expected to be sub-millisecond).
- [ ] `imageRetriesMedian == 0` for both benchmark workloads with the default limits.
- [ ] Forced-retry run (`-Dimage-initial-bytes=65536`) passes every suite.
- [ ] `grep -n "runtime_fba\|cold_core" compiler-adapter/*.zig` returns nothing (or, if `wip/01` has not landed and `runEcho` remains, `runEcho` uses `image.build` and has no fixed buffer).
- [ ] `compiler-adapter/image.zig` is the only place that calls `copyProgramWithStaticDataIntoBuffer` / `fillHeader`, and nothing in `compiler-adapter/` calls `referenceProgramWithStaticDataInBuffer`.
- [ ] Docs updated per Section 11 and this file deleted.

## 10. Risks, open questions, deferred decisions

- **Copy-mode store assertions.** `LirStoreImage.copyFromStore` asserts
  `store.tail_call_builder == null` and `proc_rewrite == null and body_coordinator == null`
  (`lir_image.zig:247-248`). These hold after lowering completes (the compiler's own run
  path copies after `lowerLirWithBuildEnv`), but reference mode never checked them. Run the
  suites in Debug once after step 3 to be sure.
- **Image relocation.** None: the image is built once per revision in its final buffer and
  never moved. Views are per root and borrow it. If a future change wanted to move or
  compact the image, it would need `copyProgram…` again; do not add that now.
- **Cross-width.** Native `target_usize = .native`, wasm `.u32`; both already pass through
  `viewMappedImageWithAllocator`. The image is width-independent except static data,
  which is checked at view time. No change.
- **wasm size-class residue.** With adaptive sizing, revisions with different power-of-two
  image sizes leave freed blocks in different `big_frees` classes; linear memory high-water
  mark is bounded by the sum of distinct classes used (at most twice the largest). Today the
  single 512 MiB class is reused every revision. Net effect is still far lower; note it in
  the measurements.
- **Lowering arena growth.** `ArenaAllocator` grows in place only for the last allocation, so
  lowering churn still abandons capacity, but it grows geometrically instead of failing and
  is freed right after the copy. If the measured peak is surprisingly large, keep one
  engine-owned lowering arena and `reset(.retain_capacity)` per revision instead of
  `deinit` (deferred; default is `deinit`).
- **Retained arena vs `gpa` for `BuildEnv`.** `BuildEnv.deinit()` frees properly through its
  allocator, so it could live on `gpa` instead of the revision arena. On native `gpa` is
  `page_allocator` (`bridge.zig:14`), which is a poor fit for many small allocations, so the
  arena is the better default until `wip/04` revisits the native `gpa` choice.
- **Total budget.** The image cap restores a bound on the one thing that must be flat; a
  total per-revision budget (counting allocator over `gpa`) is deferred until a runaway case
  is observed. Default: no total budget.
- **`ImageTooLarge` user message.** Default: map to the existing `OutOfMemory` failure text
  to keep fixtures stable; a clearer message is allowed if fixtures are updated.
- **Initial sizes.** Defaults in 5.3 are guesses until 8.3 measurements exist; set the wasm
  initial size from the measured Wall Area `image_bytes`.
- **Startup time.** The first `@wasmMemoryGrow` of 512 MiB happens during the first request
  today and is part of the measured startup; its removal may lower startup. Record it.

## 11. Cleanup

- Delete: the 512 MiB literal and `buffer`/`fba` fields in `notebook.zig`; `bridge.zig:405-408`
  and `cold_core`; `RunOptions.runtime_fba` and its doc comment (`engine.zig:111-116`), unless
  `wip/01` already removed `runEcho`; `State.lowered`; the direct `referenceProgramWithStaticDataInBuffer`
  / `fillHeader` / `viewMappedImageWithAllocator` calls now inside `image.zig`.
- Update docs: `compiler-adapter/README.md:55-57` (replace the "reserves a 512 MiB arena"
  sentences with the three-lifetime description and the image cap); `docs/compiler-workspace.md:159-161`
  (the Debug OOM note becomes "passes"); `docs/m4.md:33-35` (remove the 2 GiB / 1 GiB /
  256 MiB budget sentences); `docs/browser-package-validation.md:176-183` is a dated record and
  may stay, with one added sentence pointing at the new design; `compiler-adapter/protocol.d.ts`
  comment on `CompilerCacheStats` listing `image_bytes` / `image_retries`;
  `docs/compiler-workspace.md` browser measurements table gets a memory column once remeasured.
- Delete `wip/05-image-buffer-vs-revision-arena.md`.
