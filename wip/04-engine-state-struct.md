# Plan 04: Replace compiler-adapter globals with an explicit `Engine`

| | |
| --- | --- |
| Status | Temporary WIP handoff plan. Delete this file when the work lands. |
| Branch | `integration/compiler-workspace` |
| Written | 2026-10-20 |
| Do together with | `wip/01-typed-engine-pipeline.md` (same files, same refactor surface) |
| Unblocks | `wip/02-engine-owned-baseline.md` (baseline lives on the engine), `wip/03-checked-dependency-graph.md` (analysis takes an engine, not globals) |
| Touches | `compiler-adapter/bridge.zig`, `engine.zig`, `notebook.zig`, `platform.zig`, `workspace.zig`, `native.zig`, `build.zig`, a new `compiler-adapter/engine_state.zig`, a new `tests/engine.zig` |

All `path:line` references below were verified against this branch's HEAD on
2026-10-20. Re-verify before editing; plan 01 may have moved code.

## 1. Problem statement

The compiler adapter is a set of Zig modules that behave like one process-wide
singleton. Every piece of state that should belong to "one engine serving one
notebook" is a module-level `var`, and the observation callbacks that attribute
`dbg`, `expect`, values and crashes to notebook roots are a global function
pointer plus a global "current root" string that is set and cleared with `defer`
around each call.

### 1.1 The complete list of module-level mutable globals

Produced with `grep -n '^var \|^pub var ' compiler-adapter/*.zig` and confirmed
complete (there are no `threadlocal` declarations).

| File:line | Global | What it holds | Lifetime today |
| --- | --- | --- | --- |
| `compiler-adapter/workspace.zig:9` | `pub var global: Workspace` | virtual filesystem, compiler artifact store, package `required` list, content fingerprint, `std_io`, `native_files` | process |
| `compiler-adapter/platform.zig:9` | `pub var observation_root: ?[]const u8` | the root name stamped onto every observation | one root execution (set/cleared with `defer`) |
| `compiler-adapter/platform.zig:10` | `pub var observer: ?*const fn ([]const u8, []const u8) void` | the callback that receives `value`/`dbg`/`expect_failed`/`crashed`/`test_*` events | one `processSourceImpl` call |
| `compiler-adapter/platform.zig:23` | `pub var g_roc_ops: ?*host_abi.RocOps` | the `RocOps` that hosted functions need for refcounting | one interpreter run |
| `compiler-adapter/engine.zig:588` | `var builtin_modules: ?eval.BuiltinModules` | decoded builtin module artifacts | process |
| `compiler-adapter/engine.zig:600` | `pub var last_cache_stats` | scratch for computing a per-call cache delta | one `runEcho` call |
| `compiler-adapter/engine.zig:602` | `pub var request_cache_stats` | cache counters accumulated over one top-level request | one request |
| `compiler-adapter/engine.zig:724-727` | `request_frontend_builds`, `request_lowerings`, `request_executions`, `request_prepared_hits` | work counters reported as `workspaceCache` | one request |
| `compiler-adapter/notebook.zig:312` | `var current: ?*State` | the retained checked/lowered revision | until the input key changes |
| `compiler-adapter/bridge.zig:76` | `var response: Response` | the protocol-1 response being built | one `processSourceImpl` call |
| `compiler-adapter/bridge.zig:77` | `var arena: std.mem.Allocator` | the allocator for that response | one call |
| `compiler-adapter/bridge.zig:78` | `var user_bytes: u32` | length of the user source inside the synthetic app | one call |
| `compiler-adapter/bridge.zig:79-84` | `callback_failed`, `bounded_events`, `event_bytes`, `events_truncated`, `rich_output`, `value_index` | observation bounds state | one call |
| `compiler-adapter/bridge.zig:85` | `var notebook_expectations` | expectation spans consulted by `analyzeFallible` | one call |
| `compiler-adapter/bridge.zig:312` | `var core_cache: runner.CachedProgram` | leftover from the interpreted `Document.roc` era; `document.process` ignores its `processCore` argument (`document.zig:118`, parameter `_: anytype`) | process (dead) |
| `compiler-adapter/bridge.zig:505` | `var previous_graph: ?[]u8` | last confirmed dependency graph, injected into `reactivity.previous` | until the next successful graph |
| `compiler-adapter/bridge.zig:557` | `var execution_paths: runner.Paths` | synthetic app/platform paths; native sets a real directory | process |

Constants such as `workspace.identity` (`workspace.zig:9` neighbour, `pub const`)
and `bridge.std_options` are not state and stay as they are.

### 1.2 Attribution depends on call nesting

Observations reach the response through `platform.observer` and are stamped
with `platform.observation_root`:

- `bridge.zig:381-382` and `bridge.zig:410-411` set `platform.observer = observe`
  and clear it with `defer`.
- `notebook.zig:340-341` (replay for failed compilations) and
  `notebook.zig:348-349` (root execution) set `host.observation_root` and clear
  it with `defer`.
- `bridge.zig:111` reads `platform.observation_root` when appending each event.
- `platform.zig:37`, `:176`, `:194` (hosted echo, `roc_dbg`, `roc_expect_failed`)
  and `engine.zig:376`, `:596`, `:717`, `notebook.zig:282`, `:290`, `:297`, `:307`,
  `:367` all call through the global `observer`.

Correct attribution therefore relies on the exact nesting of `defer`s across
three files. The embedding patch already gives compile-time events typed
provenance (`ModuleRootEvent` with module/root/source), but the last hop into
the response is still "whatever the global root string says right now".

### 1.3 The app header side channel

To learn which packages a notebook declares, both pipelines write the user's
header text into the global workspace and ask the compiler to read it back:

- `engine.zig:160-161` (`runEcho`): `global.put("/internal/header.roc", ...)`
  then `parseAppHeader(opts.fallback_io, ..., "/internal/header.roc")`.
- `notebook.zig:103-104` (`State.prepare`): the same two lines against
  `workspace.global.io(a)`.

`parseAppHeader` has no in-memory variant: `parseAppHeaderReporting`
(`.toolchain/roc/src/compile/app_header.zig:85-96`) starts with
`io.readFile(app_path, gpa)`. The write is harmless today because `put` is a
no-op when bytes are unchanged (`workspace.zig:47-52`), but it mutates shared
state during what should be a pure parse, and it is one more reason both
pipelines must share one global workspace.

### 1.4 Counters are reset by hand

`bridge.process` (`bridge.zig:293-299`) clears the workspace's `required` list
and zeroes five counters in `engine.zig` by name before dispatching. Anything
that adds a counter must remember to add a reset line here.

### 1.5 Consequences

- Native `roclet` can never hold two documents in one process; every test that
  needs the engine spawns the binary (`tests/native.zig`, `tests/documents.zig`,
  `tests/m4.zig` all go through `std.process.run`).
- In-process Zig tests of the evaluation path are impossible: `workspace.zig`'s
  tests work only because `Workspace` is already a struct and they construct
  their own instances (`workspace.zig:374-444`).
- Any future re-entrancy (a second request started while one is suspended) would
  silently corrupt `response`, `arena`, counters and attribution.

## 2. Why it matters

- **Testability.** Plans 01, 02 and 03 all change the evaluation pipeline. Each
  needs fast in-process tests that construct an engine, feed it two or three
  revisions, and inspect typed results, not a subprocess round trip through JSON.
- **Correctness of attribution.** Observations should be stamped with the root
  that owns the execution context, not with a global that happens to be set.
  Plan 02 moves per-root retained presentations into the engine; that code must
  not depend on the order of `defer`s in three files.
- **Multi-tenancy.** The native CLI and any future server or batch mode need
  more than one engine per process. A browser tab needs exactly one, which the
  WASM export layer can own explicitly.
- **Maintainability.** Resetting counters by name in `bridge.process` and
  clearing globals with `defer` is exactly the kind of coordination that grows
  silently. One struct with one `beginRequest()` replaces it.

## 3. Current design walkthrough

One request today:

1. `roclet_process` (`bridge.zig:448`) or native `main` (`native.zig:71`) calls
   `bridge.process(bytes)`.
2. `process` resets counters and `Workspace.global.required`, mounts `files`
   into `Workspace.global`, and dispatches to `processDocument`, the legacy
   `snapshot.evaluate` path, or `processSource`.
3. `processSourceImpl` (`bridge.zig:319`) resets the response globals, installs
   `platform.observer = observe`, builds `extras`, and calls either
   `notebook.run` (notebook requests) or `runner.runEcho` (check/run/export).
4. `notebook.run` (`notebook.zig:313`) consults `current`, prepares a new
   `State` if the input key changed, sets `host.observation_root`, calls
   `opts.analyze` (which writes into `bridge.response` through the globals), and
   executes one root. `State.execute` (`notebook.zig:246`) installs
   `host.g_roc_ops = &ops` for the interpreter run and clears it with `defer`.
5. Every observation goes through `platform.observer` to `bridge.observe`
   (`bridge.zig:93`), which enforces bounds using `bounded_events`,
   `event_bytes`, `events_truncated`, `rich_output`, `value_index`, and stamps
   `platform.observation_root`.
6. `serialize` (`bridge.zig:275`) reads `response`, `Workspace.global.required`
   and `runner.stats()`.

The pieces that are already instance-shaped and need no redesign:

- `Workspace` is a struct with methods; only the `global` binding is a global.
- `EchoEnv` (`platform.zig:13`) is per-execution and is reachable from every
  `RocOps` callback through `ops.env` (`platform.zig:48`, `:183`, `:192`, `:201`,
  `:213`). It already carries per-run state (`inline_expect_failed`).
- `engine.Diagnostics` (`engine.zig:43`) is a `{ctx, vtable}` pair; bridge passes
  `.ctx = null` (`bridge.zig:393`, `:421`) and uses globals instead.
- `compile_time_root_event_callback` (`engine.zig:201`, `notebook.zig:131`) is a
  `{context, notify}` pair into `DebugCapture`, which lives on the `State`.
- `notebook.State` owns its revision data, including `capture`.

## 4. Target design

### 4.1 `Engine`

New file `compiler-adapter/engine_state.zig` (not `Engine.zig`: the repo must
build on case-insensitive filesystems and `engine.zig` already exists).

```zig
//! One compiler engine instance: workspace, retained revision, counters.
const std = @import("std");
const Workspace = @import("workspace.zig").Workspace;
const notebook = @import("notebook.zig");
const runner = @import("engine.zig");
const eval = @import("eval");

pub const Engine = struct {
    gpa: std.mem.Allocator,
    workspace: Workspace,
    /// Process-wide immutable builtins, borrowed (see 4.6).
    builtins: *eval.BuiltinModules,
    /// Synthetic app/platform paths; native sets a real source directory.
    paths: runner.Paths = .{},
    /// Retained checked+lowered revision (was `notebook.current`).
    revision: ?*notebook.State = null,
    /// Counters reported as `workspaceCache`; zeroed by `beginRequest`.
    stats: runner.RequestStats = .{},
    /// Last confirmed dependency graph (was `bridge.previous_graph`).
    /// Removed entirely by plan 02.
    previous_graph: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, std_io: std.Io) !Engine;
    pub fn deinit(self: *Engine) void;
    /// Native only: serve a real directory under the synthetic paths.
    pub fn setNativeSourceDirectory(self: *Engine, directory: []const u8) !void;
    /// Clears per-request state: `workspace.clearRequired()`, `stats = .{}`.
    pub fn beginRequest(self: *Engine) void;
};
```

`RequestStats` (`engine.zig:728`) keeps its JSON shape; it becomes a value on
the engine instead of five separate `pub var`s plus a `stats()` function that
reads them.

### 4.2 `Observer`

Defined in `platform.zig` next to `EchoEnv`, because that is where the Roc
host callbacks live:

```zig
pub const Observer = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, kind: []const u8, message: []const u8, root: ?[]const u8) void,
    /// The root this execution is attributed to. Replaces `observation_root`.
    root: ?[]const u8 = null,

    pub fn observe(self: Observer, kind: []const u8, message: []const u8) void {
        self.emit(self.ctx, kind, message, self.root);
    }
};

pub const EchoEnv = struct {
    std_io: std.Io,
    inline_expect_failed: bool = false,
    /// Per-execution observer; null means "write to stdout/stderr" as today.
    observer: ?Observer = null,
};
```

Every callback that currently tests `if (observer) |emit|` instead reads the
observer from the environment it already has:

- `rocDbg`, `rocExpectFailed`, `rocCrashed` (`platform.zig:175-226`): the
  `EchoEnv` is `ops.env`, already cast at `:183`, `:192`, `:201`, `:213`.
- `echoHostedFn` (`platform.zig:31`): it already dereferences `g_roc_ops.?` for
  refcounting (`:32`); `ops.env` gives the `EchoEnv` and its observer.
- `runEchoView` (`engine.zig:376`) and `State.execute` (`notebook.zig:282-307`,
  `:367`): take `observer: ?Observer` as a parameter (it is the same value
  stored into the `EchoEnv` they construct).
- `DebugCapture.replay` / `replayExpression` / `replayFrom`
  (`engine.zig:623-629`): add an `observer: ?Observer` parameter and emit through
  it at `:717`. `observeCompileTime` (`engine.zig:594`) is unreferenced today;
  delete it.

The bridge-side implementation of `emit` is `ResponseBuilder.observe` (4.3). The
bounds logic moves verbatim; only its state moves from globals into the builder.

### 4.3 `ResponseBuilder` replaces the bridge globals

```zig
const ResponseBuilder = struct {
    arena: std.mem.Allocator,
    response: Response = .{},
    user_bytes: u32 = 0,
    failed: bool = false,          // was callback_failed
    bounded: bool = true,          // was bounded_events
    event_bytes: usize = 0,
    truncated: bool = false,       // was events_truncated
    rich_output: bool = false,
    value_index: usize = 0,
    expectations: []const notebook.Expectation = &.{},

    fn observer(self: *ResponseBuilder, root: ?[]const u8) platform.Observer;
    fn diagnostics(self: *ResponseBuilder) runner.Diagnostics; // ctx = self
    fn analyze(ctx: *anyopaque, env: *can.ModuleEnv, prefix: u32) void;
    fn serialize(self: *ResponseBuilder, engine: *Engine) ![]u8;
};
```

`Diagnostics.VTable.write` and `emitReport` already receive `ctx: ?*anyopaque`
(`engine.zig:48-51`); `writeFailure` (`bridge.zig:115`) and `emitReport`
(`bridge.zig:118`) cast it to `*ResponseBuilder` instead of touching globals.
The `analyze` callback type (`engine.zig:108`, `notebook.zig:34`) changes from
`*const fn (*can.ModuleEnv, u32) void` to a `{ctx, call}` pair so the analysis
can append to the builder it belongs to.

### 4.4 The one ABI-forced global: `g_roc_ops`

Hosted platform functions do not receive `RocOps`. The interpreter calls them
either through the register-image trampoline with the function's natural C ABI
(`.toolchain/roc/src/eval/interpreter.zig:5417-5434`, `HostedFn` is a
type-erased pointer, `host_abi.zig:111`) or, where no trampoline exists
(wasm32), through a uniform `(args_buf, ret_buf)` pair
(`interpreter.zig:5435-5446`). `Echo.line!(Str)` therefore arrives as
`fn (RocStr) callconv(.c) void` on native and `fn ([*]u8, [*]u8)` on wasm, with
no environment pointer in either shape. `echoHostedFn` needs `RocOps` to
`decref` its argument (`platform.zig:33`), so one static slot is unavoidable.

Keep it, but make it explicit and checked:

```zig
/// The only process-wide mutable slot. Hosted functions have no env parameter
/// (see host_abi.HostedFn), so the interpreter run that owns the current
/// RocOps publishes it here. Single-threaded; never nested.
var active_roc_ops: ?*host_abi.RocOps = null;

pub fn enterRocOps(ops: *host_abi.RocOps) void {
    std.debug.assert(active_roc_ops == null);
    active_roc_ops = ops;
}
pub fn leaveRocOps(ops: *host_abi.RocOps) void {
    std.debug.assert(active_roc_ops == ops);
    active_roc_ops = null;
}
```

`runEchoView` (`engine.zig:345`) and `State.execute` (`notebook.zig:269-270`)
call `enterRocOps`/`defer leaveRocOps`. The assertion turns a future nesting bug
into an immediate failure in ReleaseSafe test builds instead of silent
misattribution. Because the observer now travels inside `EchoEnv`, this slot
carries no attribution state; it is purely the refcount environment.

### 4.5 Header parsing without the workspace write

`parseAppHeader` reads through the `Io` vtable, so give it an `Io` that serves
the header text from memory for one virtual path and never touches the
workspace. `EchoCtx` (`engine.zig:422`) already does exactly this for the
synthetic app source; add a sibling in `engine.zig`:

```zig
/// Parse an app header held in memory. The path is virtual: nothing is written.
pub fn parseHeaderPackages(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    fallback: Io,
    header_text: []const u8,
) ![]const compile.app_header.PackageEntry {
    var ctx = EchoCtx{
        .paths = .{ .app_abs = "/internal/header.roc" },
        .synthetic_app_source = header_text,
        .extras = &.{},
        .fallback = fallback,
    };
    const info = try compile.app_header.parseAppHeader(ctx.io(), gpa, arena, "/internal/header.roc");
    return info.non_platform_packages;
}
```

Both `runEcho` (`engine.zig:158-168`) and `State.prepare`
(`notebook.zig:101-109`) call this helper. Plan 01 collapses the two header
*synthesis* loops into one; this plan only removes the workspace write. If plan
01 lands first, apply this inside the single remaining synthesis function.

### 4.6 What stays process-wide, and why

- `engine.persistentBuiltins()` (`engine.zig:589`): `BuiltinModules.init`
  (`.toolchain/roc/src/eval/BuiltinModules.zig:37`) decodes the embedded builtin
  artifacts (on wasm after a one-time decompression, `bridge.zig:377`). The
  result is immutable and `BuildEnv.initBorrowingBuiltinModules`
  (`.toolchain/roc/src/compile/compile_build.zig:349`) borrows it without
  ownership. Keep the lazily-initialized singleton; `Engine.builtins` points at
  it so callers never name the global. Two engines in one process share it,
  which is correct.
- `active_roc_ops` (4.4).
- `workspace.identity`, `std_options`, `is_wasm`: constants.

Everything else in section 1.1 becomes a field of `Engine`, `ResponseBuilder`,
`EchoEnv`, or a local.

### 4.7 Entry points

WASM (`bridge.zig`):

```zig
var wasm_engine: ?Engine = null;
fn engine() *Engine {
    if (wasm_engine == null) wasm_engine = Engine.init(gpa, .failing) catch @trap();
    return &wasm_engine.?;
}
export fn roclet_process(ptr: u32, len: u32) u32 { ... process(engine(), bytes) ... }
export fn roclet_file_put(...)  { engine().workspace.put(...) }
// likewise roclet_file_drop, roclet_cache_import, roclet_cache_take_updates,
// roclet_cache_stats (engine().stats), roclet_cache_identity, roclet_package_install
```

This is the single intentional instance for a worker. It is a `var` holding a
struct, not a scattering of state; the globals gate in 7.3 allows exactly this
one declaration in `bridge.zig`.

Native (`native.zig:24`, `:67`, `:71`):

```zig
var engine = try Engine.init(a, init.io);
defer engine.deinit();
if (is_document) try engine.setNativeSourceDirectory(dir);
const result = try bridge.process(&engine, request);
```

`bridge.setNativeIo` and `bridge.setNativeSourceDirectory`
(`bridge.zig:552-567`) are deleted; their bodies move into `Engine`.

Tests construct `Engine.init(std.testing.allocator, .failing)` directly.

## 5. Constraints and non-goals

- **Zero protocol change.** Every JSON request and response byte is identical.
  The parity suites (`tests/native.zig`, `tests/documents.zig`, `tests/m4.zig`
  and the browser pages that replay their recorded requests) prove it.
- **Zero behaviour change**, including observation bounds, truncation text,
  attribution of shared-dependency `dbg` events, `workspaceCache` counters, and
  `packagesRequired`.
- **No measurable performance change.** The refactor replaces global loads with
  pointer loads; the benchmark page must not regress.
- **Single-threaded stays single-threaded.** No locks, no threadlocals.
- **Do not fight the hosted-function ABI.** `active_roc_ops` remains; document
  it, assert on it, and move on.
- **No embedding patch growth.** Nothing here needs compiler changes.
- Not in scope: the typed pipeline (plan 01), baseline ownership (plan 02),
  deleting the legacy `cells`/`processCore` paths (plan 06). Where this plan
  touches `core_cache`, it only moves or deletes dead code it would otherwise
  have to thread through.

## 6. Step-by-step implementation plan

Each step compiles, passes `zig build test`, and can be committed alone.
Steps (a)-(c) are mechanical and should land before plan 01's typed calls so
that plan 01 writes its new signatures against `*Engine` from the start; steps
(d)-(i) can interleave with plan 01.

**(a) Introduce `Engine` around the existing workspace.**
Create `compiler-adapter/engine_state.zig` with the struct from 4.1, initially
holding only `gpa`, `workspace`, `builtins`, `paths`. Add `wasm_engine` and
`engine()` to `bridge.zig`; change every `Workspace.global.` use in `bridge.zig`
(`:288`, `:294`, `:341`, `:356`, `:415-416`, `:476-501`, `:512`, `:527`, `:537`,
`:549`, `:554`, `:559`) and `execution_paths` (`:340`, `:355`, `:387`, `:414`,
`:535`, `:557-567`) to go through an `*Engine` parameter. Thread `*Engine` into
`processSourceImpl`, `processDocument`, `mountFiles`, `withRequiredPackages`,
`snapshot.evaluate`'s `compile` callback (pass a context or a bound struct),
`notebook.run`/`State.prepare`/`inputKey` (`notebook.zig:103`, `:123`, `:125`,
`:267`, `:401`) and `runEcho` (`engine.zig:160`). `workspace.zig:9` `global`
is deleted in this step; `native.zig` constructs the engine.
Covered by: `zig build test` (all suites), browser parity pages.

**(b) Move the counters.**
Replace `engine.zig:600-602`, `:724-727`, `stats()` (`:747`) with
`engine.stats: RequestStats`. `bridge.process` calls `engine.beginRequest()`
instead of `:294-299`. Update increments at `engine.zig:208`, `:220`, `:272`,
`:322` and `notebook.zig:64`, `:143`, `:219`, `:320`, `:350`;
`State.reportCache` (`notebook.zig:62`) takes `*Engine`. `last_cache_stats`
becomes a local in `runEcho`.
Covered by: `tests/m4.zig` and `web/workspace-conformance.mjs` assert
`frontend_builds`/`lowerings`/`executions`/`prepared_hits`; `tests/harness.mjs`
`compilerSemantics` strips counters for parity, so also re-run the Wall Area
and module-edit benchmark and confirm the counter lines in
`docs/compiler-workspace.md` still hold.

**(c) Move the response state into `ResponseBuilder`.**
Replace `bridge.zig:76-85` with the struct in 4.3, constructed at the top of
`processSourceImpl`. `dupe`, `observe`, `writeFailure`, `emitReport`, `analyze`,
`analyzeFallible`, `serialize` become methods or take `*ResponseBuilder`
through `Diagnostics.ctx`. The `analyze` callback becomes `{ctx, call}`
(`engine.zig:108`, `notebook.zig:34`, call site `notebook.zig:346`,
`engine.zig:249-250`). `notebook_expectations` becomes
`builder.expectations`.
Covered by: `tests/native.zig` "selected roots and repeated dbg",
"atomic output failure", "heap-backed strings" (bounds and failure paths);
`tests/documents.zig` events/`root_errors`/`display_kinds` fixtures.

**(d) Thread `Observer` through `EchoEnv`, `RocOps` callbacks and `DebugCapture`.**
Add `Observer` and `EchoEnv.observer` (4.2). Change `platform.zig:37`, `:176`,
`:194`, and add a `rocCrashed` observer hop only if behaviour is unchanged (today
`rocCrashed` on wasm traps and on native exits, `platform.zig:209-221`; the
`crashed` event is emitted by the callers at `engine.zig:376` and
`notebook.zig:367`, keep it there). Give `runEchoView`, `State.execute`,
`DebugCapture.replay*` an `observer: ?Observer` parameter and delete the reads
of `echo_platform.observer` at `engine.zig:376`, `:596`, `:717` and
`host.observer` at `notebook.zig:282`, `:290`, `:297`, `:307`, `:367`. Bridge
creates the observer from the builder at the two sites that set the global
today (`bridge.zig:381`, `:410`) and passes it down. Delete
`platform.observer` (`platform.zig:10`) and `observeCompileTime`
(`engine.zig:594`).
Covered by: `tests/native.zig` `debug` fixture permutations and "selected roots
and repeated dbg"; `tests/documents.zig` CLI run attribution check
(`events[0].root == out_dimensions`, `cell == 2`); new test 7.2.

**(e) Replace `observation_root` with `Observer.root`.**
At `notebook.zig:340-341` and `:348-349`, construct the observer with the
root instead of assigning the global; `bridge.observe` reads the `root`
argument. Delete `platform.zig:9`.
Covered by: same as (d), plus new test 7.2.

**(f) Make `g_roc_ops` explicit.**
Rename to `active_roc_ops` with `enterRocOps`/`leaveRocOps` (4.4). Update
`engine.zig:345` and `notebook.zig:269-270`, and `platform.zig:32`.
Covered by: every evaluating test; the assertion is exercised by the two-engine
test in 7.1.

**(g) Remove the header side channel.**
Add `parseHeaderPackages` (4.5); replace `engine.zig:160-161` and
`notebook.zig:103-104`. Confirm with a workspace assertion in the new engine
test that `/internal/header.roc` never appears in `engine.workspace.files`.
Covered by: `tests/documents.zig` App header fixtures, the package fixtures
(`web/workspace-conformance.mjs` roc-time/roc-parser cases) and the
`demos/04-meeting-windows.roc` run.

**(h) Move the retained revision onto the engine.**
Replace `notebook.zig:312` `current` with `engine.revision`; `run` takes
`*Engine`. `Engine.deinit` deinitializes a retained `State`. Move
`previous_graph` (`bridge.zig:505`, `:514`, `:523-524`) onto `Engine` with
`deinit` freeing it (plan 02 deletes it later).
Covered by: `tests/m4.zig` (prepared-hit reuse across the check call and root
calls), `web/workspace-conformance.mjs` restart cases.

**(i) Delete what is left and add the gate.**
`core_cache`/`processCore` (`bridge.zig:312-315`, `:517`) are dead: delete them
and pass only `processSource` (coordinate with plan 06 if it lands first).
Run the globals gate (7.3) and make `zig build test` depend on it.

## 7. Validation

### 7.1 Commands

```sh
zig build test            # unit + workspace + fixture + native + documents + m4
zig build test-unit
zig build test-workspace
zig build test-documents
zig build test-m4
zig build test-engine     # new step, see 7.2
node --test tests/workspace.test.mjs
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
zig build package         # the pages workflow runs test + package
```

Record before/after from the benchmark page: warm round trip median and
worker request median for "Wall Area source edit" and "Imported Geometry
implementation edit" (compare against the table in
`docs/compiler-workspace.md`). A difference within run-to-run noise is
expected; anything beyond that needs an explanation before merging.

### 7.2 New tests

Add `tests/engine.zig` and a `test-engine` step in `build.zig`. The existing
`test-unit` step compiles `snapshot.zig` and `document.zig` without compiler
modules (`build.zig:88-92`); an engine test needs the same imports as the
`adapter()` helper (`build.zig:134-151`: the roc modules, `compiled_builtins`,
md4c, `Display.roc`, `display-package-url.txt`). Factor the import wiring in
`adapter()` into a helper that configures a `*std.Build.Module` and call it for
both `addExecutable` and `addTest`. `zig build test` depends on the new step.

Tests to write, each asserting through the typed entry points introduced in
plan 01 where available, otherwise through `bridge.process(&engine, json)`:

1. **Two engines, no crossing.** Construct `a` and `b`. Evaluate in `a` a
   notebook whose root emits `dbg "from-a"`, then in `b` one emitting
   `dbg "from-b"`, then `a` again. Assert each response's `events` contain only
   its own message and root, that `a.stats` and `b.stats` are independent, and
   that `a.revision` is a prepared hit on the third call while `b.revision` is
   untouched.
2. **Attribution by observer root.** One notebook with `shared = { dbg "s"\n 1 }`
   and two roots `out_1 = shared` and `out_2 = shared + 1`. Evaluate both roots
   in one request. Assert the `dbg` event appears once per root with
   `root == "out_1"` and `root == "out_2"` respectively (this is today's
   behaviour; `tests/native.zig` "selected roots and repeated dbg" covers the
   single-root case).
3. **Header parsing leaves the workspace untouched.** Evaluate a notebook with a
   non-empty `app_header` declaring a package; assert
   `engine.workspace.files.contains("/internal/header.roc") == false` and that
   the content fingerprint before and after the request is equal when no
   project files changed.
4. **Nesting assertion.** In a `Debug`/`ReleaseSafe` test build, call
   `enterRocOps` twice without `leaveRocOps` inside `std.testing.expectPanic`
   or equivalent, or, if panics are awkward to test, assert `active_roc_ops`
   is `null` after every evaluation in tests 1 and 2.
5. **Reset semantics.** After a request that recorded `packagesRequired`, the
   next `beginRequest` clears it and the counters; assert the second response
   reports `packagesRequired: []` and zeroed counters before any work.

### 7.3 Globals gate

A build step `check-globals` that `zig build test` depends on:

```sh
! grep -nE '^(pub )?var ' compiler-adapter/*.zig \
  | grep -vE 'platform\.zig:[0-9]+:var active_roc_ops|engine\.zig:[0-9]+:var builtin_modules|bridge\.zig:[0-9]+:var wasm_engine'
```

Implement it with `b.addSystemCommand(&.{ "sh", "-c", ... })` and
`has_side_effects = true`, or as a tiny Zig program under `tools/` that reads
the sources, whichever matches the repository's no-shell-dependency preference
(`tools/prepare-compiler.sh` already assumes `sh`, so the shell form is
acceptable).

## 8. Acceptance gates

All must be true before this plan's file is deleted:

- [ ] `grep -nE '^(pub )?var ' compiler-adapter/*.zig` lists exactly three
      declarations: `active_roc_ops` in `platform.zig`, `builtin_modules` in
      `engine.zig`, `wasm_engine` in `bridge.zig`.
- [ ] `platform.observer` and `platform.observation_root` no longer exist;
      every observation is emitted through an `Observer` value that carries
      its root.
- [ ] `enterRocOps`/`leaveRocOps` are the only writes to `active_roc_ops` and
      assert non-nesting.
- [ ] No code writes `/internal/header.roc` into a workspace; test 7.2.3 passes.
- [ ] `tests/engine.zig` exists, runs under `zig build test`, and tests 7.2.1
      through 7.2.5 pass.
- [ ] `zig build test` and `zig build package` pass.
- [ ] Browser parity pages (`document-conformance`, `m4-conformance`,
      `workspace-conformance`) pass with zero semantic diffs against native.
- [ ] `workspaceCache` counters for the Wall Area and module-edit workloads are
      unchanged (one frontend build, one lowering, two executions per warm edit;
      restart reports the same compiler-cache hits as before).
- [ ] Benchmark medians are within noise of the pre-change run, and both
      numbers are recorded in the PR description.
- [ ] `native.zig` constructs its own `Engine`; `bridge.setNativeIo` and
      `bridge.setNativeSourceDirectory` are gone.
- [ ] `compiler-adapter/README.md` and `docs/compiler-workspace.md` describe
      the engine instance, the observer, and the two permitted globals.

## 9. Risks, open questions, deferred decisions

- **Hidden coupling through `Diagnostics.ctx = null`.** Some call sites may rely
  on the global `response` from inside compiler callbacks that run on a
  different stack (coordinator callbacks). Grep for every `diag.` and
  `emitReport` call and confirm each has a builder reachable through `ctx`
  before deleting the globals. Default: fail loudly (`unreachable`) if `ctx` is
  null in a callback.
- **`analyze` callback shape.** Changing it to `{ctx, call}` touches plan 01's
  typed `Analysis` work. Default: do it in this plan; plan 01 then replaces the
  callback with a direct method on the revision.
- **WASM engine initialization failure.** `Engine.init` cannot fail today
  (workspace is a zero-initialized struct, builtins are lazily loaded later).
  If plan 05 makes `init` allocate, decide whether `roclet_process` returns `0`
  (allocation failure) or traps. Default: return `0`, matching the existing
  "zero indicates failure" contract in `compiler-adapter/README.md`.
- **Should the worker be able to reset the engine without terminating?**
  A `roclet_engine_reset()` export would let tests reuse one instance. Default:
  no. Worker termination is the documented cancellation and reset boundary
  (`design.md` section 9.2); do not add a second one.
- **Native multi-document CLI.** Nothing in this plan adds a user-facing
  feature; it only makes one possible. Default: leave `native.zig` with one
  engine per process.
- **Case-insensitive filesystems.** Do not name the new file `Engine.zig`.
- **Interplay with plan 06.** If plan 06 removes the legacy `cells` path and
  `processCore` first, step (i) is empty. If this plan lands first, delete only
  `core_cache`/`processCore` and leave the `cells` dispatch alone.

## 10. Cleanup

Delete when done:

- Globals: `workspace.global`, `platform.observation_root`, `platform.observer`,
  `engine.last_cache_stats`, `engine.request_cache_stats`,
  `engine.request_frontend_builds`, `engine.request_lowerings`,
  `engine.request_executions`, `engine.request_prepared_hits`,
  `notebook.current`, every `bridge.zig` global in section 1.1 except
  `wasm_engine`, and `engine.observeCompileTime`.
- Functions: `bridge.setNativeIo`, `bridge.setNativeSourceDirectory`,
  `engine.stats()`, `bridge.processCore`.

Update:

- `compiler-adapter/README.md`: describe `Engine`, `Observer`, the two permitted
  process-wide values, and that native hosts may construct several engines.
- `docs/compiler-workspace.md`: the "What changed" section's description of
  worker state (one engine per worker instance).
- `design.md` section 9.2 if it still says attribution relies on worker-level
  globals (it does not today; check after editing).

Finally delete `wip/04-engine-state-struct.md`.
