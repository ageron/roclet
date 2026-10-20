# Plan 01: typed engine pipeline (remove JSON re-entry inside the engine)

**Status:** temporary WIP handoff document. Delete this file when the work lands.
**Branch:** `integration/compiler-workspace` **Date:** 2026-10-20
**Sequencing:** do together with `wip/04-engine-state-struct.md` (same refactor surface:
the engine entry points, the observer, the counters). This plan unblocks
`wip/02-engine-owned-baseline.md` (retained results need a typed revision to hang off)
and `wip/06-retire-legacy-paths.md` (the M0 `cells` entry and `snapshot.zig` can only
be retired once the document path no longer depends on them).

All `path:line` references below were verified against this branch's HEAD on the date
above. Re-check them with `grep -n` before editing; the files are dense and lines move.

---

## 1. Problem statement with evidence

Roclet's engine is one Zig binary (native `roclet`, WASM `roclet.wasm`) whose public
surface is a single JSON request/response call: `roclet_process` in
`compiler-adapter/bridge.zig:448` for WASM, and `roclet --bridge request.json`
(`compiler-adapter/native.zig:31`) for native. That boundary is fine. The problem is that
the *internal* layers of the same binary also talk to each other through JSON strings and
re-enter the public entry point, once per evaluated output root.

### 1.1 The flow for one `evaluate` request

Follow a notebook `evaluate` request with N selected output roots:

| # | Where | What happens |
|---|---|---|
| 1 | `compiler-adapter/wasm.mjs:37` | JS stringifies the document request. |
| 2 | `bridge.zig:300` (`process`) | Parses the whole request into `std.json.Value` as a *probe* to decide which dispatch path to take. |
| 3 | `bridge.zig:511` (`processDocument`) | Parses the same bytes **again** into a mutable `Value`, injects `workspaceFingerprint` (`:512`) and the retained `previous` graph (`:514`), then **re-stringifies** (`:516`). |
| 4 | `document.zig:121` (`process`) | Parses that string into a `Value` a third time. |
| 5 | `document.zig:223` | Builds a *snapshot* JSON (containing the full generated program text) and calls `snapshot.evaluate` with `roots: []` to check the module and obtain definitions. |
| 6 | `snapshot.zig:125` (`evaluate`) | Parses the snapshot JSON into `Snapshot`; `:141` calls `invoke` for the check pass. |
| 7 | `snapshot.zig:118` (`invoke`) | Stringifies a bridge `Request` containing the full program text again and calls `compile(request)`, which is `bridge.processSource` (`bridge.zig:316`). |
| 8 | `bridge.zig:319` (`processSourceImpl`) | Parses the `Request`, resets the global `response`, detects the Display import by re-running the syntax parser over the source, then calls `notebook.run` (`:383`). |
| 9 | `notebook.zig:313` (`run`) | Hashes the full program plus every extra module and the workspace identity (`inputKey`, `:373`) to find the retained revision; on a hit, `:346` runs `opts.analyze` (the bridge's full dependency analysis, see 1.2) **before** the `if (opts.root == null) return 0;` at `:347`. |
| 10 | `bridge.zig:275` (`serialize`) | Stringifies the analysis as a protocol-1 `Response`. |
| 11 | `snapshot.zig:121` | Parses that string into `RawResponse`. |
| 12 | `snapshot.zig:242` | Stringifies the check `Result`; `document.zig:234` parses it back into a `Value`. |
| 13 | `document.zig:248` | Computes the reactive `plan` in Zig; if `plan.evaluate` is non-empty, `:252` builds a **second** snapshot JSON with the selected roots and calls `snapshot.evaluate` again. |
| 14 | `snapshot.zig:141` | The second `evaluate` performs **another** check `invoke` (steps 7–11 again, analysis again). |
| 15 | `snapshot.zig:181`–`:188` | For each of the N roots: `invoke` stringifies the full program (`:118`), `processSourceImpl` parses it, `notebook.run` re-hashes it (`:314`), runs the analysis again (`:346`), executes the root (`:350`), `serialize` stringifies the response, `snapshot` parses `RawResponse` (`:121`) and keeps only the `events`. |
| 16 | `snapshot.zig:242` → `document.zig:262` | Stringify the evaluation `Result`; parse it into a `Value`. |
| 17 | `document.zig:332` | Stringifies the whole document result. |
| 18 | `bridge.zig:519`–`:529` | Parses it, injects `workspaceCache` and `packagesRequired` (each via stringify+parse of small structs), stringifies the final response. |
| 19 | `wasm.mjs:50` | JS parses it. |

Counting only passes over document-sized payloads: about **eight** parse/stringify
stages before the first root executes, **four** per root, and **four** on the way out.
For the analysis pass alone (`action: "analyze"`, used on every debounce when auto-run is
off), steps 5–12 still happen.

### 1.2 The analysis is recomputed N+2 times and discarded

`bridge.analyzeFallible` (`bridge.zig:159`) is the notebook's dependency analysis. It:

- walks every CIR node once to collect binders and scope facts (`:173`),
- for every top-level definition, collects name references
  (`can.DependencyGraph.collectNameReferences`, `:206`) and then **scans every CIR node
  again** to find occurrence regions of that definition's pattern (`:215`), and
- instantiates a type writer per definition (`:232`).

The occurrence scan nested in the per-definition loop makes it O(definitions × CIR nodes).
`notebook.run` invokes it unconditionally at `notebook.zig:346`, before the early return
for `root == null` at `:347`, so it runs on the first check pass, on the second check
pass, and once per executed root: **N+2 times for N roots**. `snapshot.invoke` parses the
resulting `definitions` into `RawResponse` every time (`snapshot.zig:121`) but
`snapshot.evaluate` reads them only from the first call (`:150`); the other N+1 copies are
allocated, parsed and dropped.

The same applies to `inputKey` (`notebook.zig:373`): SHA-256 over the full program text,
the app header, every extra module's content and the workspace content identity, computed
once per `notebook.run` call, i.e. N+2 times per request.

### 1.3 What has and has not been measured

`docs/compiler-workspace.md` records a warm Wall Area edit (2 outputs) at **9.7 ms**
median worker time and the module edit at 8.1 ms. At that size none of the above is
visible. The scaling concern is **inferred from the complexity**, not measured: with
C cells, D definitions, K CIR nodes and N roots, the per-request work added by this
pipeline is roughly `(N+2) × (D × K + hash(program) + json(program))`, while the compiler
itself does one check and one lowering.

**First task for the implementer: measure.** Before changing anything, build a baseline:

```sh
zig build                      # produces zig-out/bin/roclet
node tests/pipeline-benchmark.mjs   # new script, see §8.3; prints ms and bytes for 10/30/60-cell docs
```

Record the numbers in the PR description. If 60 cells / 60 roots is still well under the
UI's debounce budget, the refactor is still worth doing for the structural reasons in §3,
but the performance claim in the PR must say what was measured.

---

## 2. Why it matters

- **Scaling cliff on the hot path.** Every keystroke with auto-run on goes through steps
  1–19. The cost grows with roots × definitions × nodes for work the compiler already did
  once. The product target in `design.md` §16 is a 100-cell notebook under 300 ms p95.
- **The engine cannot hold a handle to its own revision.** `document.zig` can only reach
  the retained revision by re-sending the inputs and hoping `inputKey` matches
  (`prepared_hits`). Any accidental difference in inputs between the check call and a
  root call silently costs a full rebuild of the 512 MiB revision.
- **Duplicated pipelines.** `engine.runEcho` (`engine.zig:153`) and
  `notebook.State.prepare` (`notebook.zig:72`) both synthesise the app header
  (`engine.zig:157`–`:169` and `notebook.zig:97`–`:110`), both write the user header into
  the global workspace as `/internal/header.roc` to call `parseAppHeader`
  (`engine.zig:160`, `notebook.zig:103`), both set up `BuildEnv`, the cache manager, the
  Display package skip, and the synthetic source mapping. They must agree, and nothing
  checks that they do.
- **Blocks the next steps.** `wip/02-engine-owned-baseline.md` wants the engine to retain
  per-root presentation results on the revision; `wip/04-engine-state-struct.md` wants to
  remove the globals that `processSourceImpl` resets on each call (`bridge.zig:322`–`:327`).
  Both are far simpler once the document path calls typed functions.

---

## 3. Current design

| File | Role today |
|---|---|
| `compiler-adapter/bridge.zig` | WASM exports; JSON dispatch (`process`, `:293`): `operation` → `processDocument`; `cells` → `snapshot.evaluate` (M0 path); else raw `Request` → `processSourceImpl`. Owns the global `response`, the bounded observer `observe` (`:93`), the dependency analysis (`analyzeFallible`, `:159`), diagnostics rendering (`emitReport`), and `processSourceImpl` (`:319`) which chooses between `notebook.run` (when `req.notebook` is set) and `engine.runEcho` (raw/script path with a fresh 256 MiB or 1–2 GiB buffer, `:405`–`:406`). |
| `compiler-adapter/snapshot.zig` | The M0 "cells + roots" protocol. `evaluate` (`:125`) assembles cells, validates, performs one check `invoke` and one `invoke` per root, maps definitions to cells, applies the status/`isolate_errors`/designated-value rules, and emits the protocol-1 `Result`. `document.zig` reuses it as its evaluation back end by wrapping the generated program as a single cell named `document`. |
| `compiler-adapter/document.zig` | Notebook document operations. Segments cells (via `document_frontend.zig`), lowers expressions, builds `program`/`execution`, calls `snapshot.evaluate` twice (`:223` check, `:252` selected roots), computes `graph` (`dependencyGraph`, `:432`) and `plan`, attributes events to cells, remaps test locations, maps compiler diagnostics (`mapDiagnostics`, `:357`), and for `check`/`run`/`export` calls the raw `evaluate` callback with the full `execution` text (`:313`–`:318`). Everything is assembled as `std.json.Value`. |
| `compiler-adapter/notebook.zig` | The retained revision. `run` (`:313`) keys a single `current: ?*State` (`:312`) by `inputKey`; `State.prepare` (`:72`) synthesises the app, checks it, selects output and test roots, lowers once and builds the LIR image inside a 512 MiB fixed buffer (`:322`); `State.execute` (`:246`) runs one root in a fresh interpreter and emits `value`/`test_*`/`dbg` events through the global `platform.observer`. |
| `compiler-adapter/engine.zig` | `runEcho` (`:153`): the original whole-program pipeline (check, lower, image, run `main!`), used for `check`, `run`, `export` verification and the raw request path. Also `DebugCapture` (`:607`), compile-time observation replay, the counters (`:724`–`:727`, `stats()` `:747`). |

Observation bounds live in `bridge.observe` (`:93`): at most 1,000 events and 256 KiB of
observations per root, 64 KiB per message or text result, 512 KiB for the rich wire, one
`truncated` marker, UTF-8-safe truncation. They are enforced through global counters
reset in `processSourceImpl`.

### 3.1 The script path (`check`, `run`, `export`)

`document.zig:313`–`:318` sends the complete `execution` text (user program plus the
generated `display!` helper and `main!`) through the raw `Request` JSON path to
`engine.runEcho`, with `check_only` for `check` and roc-target `export` verification.
`tests/documents.zig` asserts on this path's `value` event stream (`values` expectation)
and `export` byte-identity for the demos. `native.zig:70` maps the CLI `run` verb to the
document `evaluate` action, so `run` as a document action is only reachable through
`--bridge` and tests.

---

## 4. Target design

JSON exists in exactly two places: parsing the request at the edge (`bridge.process`,
`native.zig`) and serialising the response at the edge. Everything between is typed Zig.

### 4.1 Types

Put these in a new `compiler-adapter/revision.zig` (or evolve `notebook.zig` in place and
rename later; the implementer may choose, but the names below are referenced by plans 02
and 04).

```zig
pub const Expectation = struct { root: []const u8, start: u32, end: u32, cell: u64 };

/// Everything that determines the retained revision. Hashed once per request.
pub const Inputs = struct {
    program: []const u8,                 // document_frontend `program`: user cells only, no main!
    app_header: []const u8,              // user App header (packages); may be empty
    extras: []const engine.ExtraFile,    // supplied `modules` (name/content), already including Display when needed
    roots: []const []const u8,           // every possible output root (out_*), document order
    expectations: []const Expectation,   // test roots with generated-program byte spans
    rich_support: bool,                  // trusted `import Display` detected (see §4.4)
    target_usize: base.target.TargetUsize,
    roc_target: roc_target.RocTarget,
    paths: engine.Paths,
};

pub const Region = struct { start: u32, end: u32 };
pub const Definition = struct {
    name: []const u8, type: []const u8,
    region: Region, name_region: Region,
    dependencies: []const []const u8, references: []const Region, rename_safe: bool,
};
pub const DependencyScope = enum { definitions, module };

/// Computed once per revision, in the revision's arena, from the checked app module.
pub const Analysis = struct {
    definitions: []const Definition,     // value defs + one synthetic entry per expectation (as today)
    binders: []const []const u8,
    dependency_scope: DependencyScope,
};

pub const EventKind = enum { value, dbg, expect_failed, crashed, truncated, test_passed, test_failed };
pub const Event = struct { kind: EventKind, message: []const u8 };

/// Bounded per-root observation buffer: moves the limits from bridge.observe here.
pub const EventBuffer = struct {
    arena: std.mem.Allocator,
    rich: bool,
    events: std.ArrayList(Event) = .empty,
    bytes: usize = 0, values: usize = 0, truncated: bool = false, failed: bool = false,
    pub fn observe(self: *EventBuffer, kind: EventKind, message: []const u8) void; // same rules as bridge.observe today
};

pub const RootStatus = enum { ok, runtime_error, test_passed, test_failed };
pub const RootOutcome = struct {
    root: []const u8,
    status: RootStatus,
    text: ?[]const u8 = null,            // designated `Str.inspect` result
    wire: ?[]const u8 = null,            // Display wire JSON when rich
    failure: ?[]const u8 = null,         // runtime failure / test message
    events: []const Event,               // bounded, attributed to this root (excludes the designated value events)
};

pub const Diagnostic = struct { title, severity, message: []const u8, filename: ?[]const u8, location: ?Location };

pub const RevisionStatus = enum { ready, diagnostic, constant_failures };

pub const Revision = struct {
    key: [32]u8,
    status: RevisionStatus,
    diagnostics: []const Diagnostic,     // rendered once from the drained reports
    // ...today's State fields: buffer/fba, build, capture, labels, expectations, requests, lowered, header, entry_names...
    analysis_cache: ?Analysis = null,

    pub fn analysis(self: *Revision) !*const Analysis;         // computes on first call, cached
    pub fn execute(self: *Revision, root: []const u8, events: *EventBuffer, isolate_errors: bool) !RootOutcome;
    pub fn replayCompileTime(self: *Revision, root: []const u8, events: *EventBuffer) !void; // for failed revisions, as notebook.run:342 does today
};

/// Keyed single-slot cache exactly as `notebook.run` does today. Returns the retained
/// revision or builds a new one, incrementing `frontend_builds`/`lowerings` as today.
pub fn prepare(gpa: std.mem.Allocator, inputs: Inputs, diagnostics: engine.Diagnostics) !*Revision;
```

Until plan 04 lands, `prepare` keeps using the module-level `current` slot and
`platform.observer` is pointed at a trampoline that appends to the active `EventBuffer`
for the duration of `execute`. Plan 04 replaces that with a request-scoped observer
carried in `EchoEnv`/`RocOps.env`. Write the trampoline so it is a two-line deletion.

### 4.2 The document evaluation call

Replace both `snapshot.evaluate` calls in `document.zig` with one typed function that
reproduces `snapshot.evaluate`'s semantics (`snapshot.zig:125`–`:242`) without JSON:

```zig
pub const Evaluation = struct {
    // Field-for-field the same shape as snapshot.zig `Result` so phase 1 is byte-identical.
    protocol: u32 = 1,
    requestId: []const u8 = "cli-1", documentRevision: u64 = 1, inputRevision: u64 = 0, workerGeneration: u64 = 1, // legacy defaults, see §9 risk 3
    status: []const u8 = "ok",
    definitions: []const Definition, dependency_scope: []const u8, binders: []const []const u8,
    root_errors: []const RootError, evaluated_roots: []const []const u8,
    values: []const Value, tests: []const TestResult, events: []const AttributedEvent,
    diagnostics: []const Diagnostic, failure: ?[]const u8,
};

/// One prepare, one analysis, one execute per selected root.
pub fn evaluateDocument(gpa, arena: std.mem.Allocator, inputs: Inputs, selected_roots: []const []const u8,
                        failure_roots: []const []const u8, isolate_errors: bool) !Evaluation;
```

Semantics to carry over verbatim from `snapshot.evaluate`:

1. Validation of root identifiers and duplicate modules (`snapshot.zig:96`).
2. A failed check returns `status`/`failure`/`diagnostics` and replays compile-time
   observations for the failure roots (today: `notebook.run:338`–`:344`, attributing to
   `runtime_roots`).
3. Duplicate notebook binding → `diagnostic` + `Duplicate notebook binding: X`;
   unknown root → `diagnostic` + `Unknown output root: X` (`snapshot.zig:167`, `:173`).
4. Per root: expectations become `tests` entries (`test_passed`/`test_failed` events are
   consumed, other events kept); outputs require exactly one designated value (two when
   rich) or `runtime_error` with the exact message at `snapshot.zig:230`; with
   `isolate_errors` failures go to `root_errors` and the status becomes `partial`;
   without it the first failure returns immediately with the values gathered so far
   discarded (`snapshot.zig:224`, and the "atomic" unit test at `:261`).
5. `evaluated_roots` is appended *before* executing each root (`snapshot.zig:182`), so a
   crash mid-way still lists the root.
6. The rich `display` payload is parsed from the wire string, and a malformed wire never
   discards the text value (`snapshot.zig:235`).

`document.zig` phase 1 consumes the typed `Evaluation` via its existing
`value(a, typed)` helper (one stringify + parse at the end of the request, not per root).
Phase 2 removes even that (§4.5).

### 4.3 Analysis once, hashing once

- `Revision.analysis()` is the body of `bridge.analyzeFallible` moved into the revision
  module, allocating from the revision arena and cached on the revision. It is computed at
  most once per revision, regardless of how many requests or roots touch the revision.
  (Plan 03 later changes *what* it computes; keep the function boundary.)
- `inputKey` is computed once in `prepare`, not once per root. The second `inputKey` at
  `notebook.zig:332` (after `prepare`, to account for the header side channel changing the
  workspace fingerprint) stays until plan 04 removes the side channel; document that.
- `display_module`/`rich_support` is decided once per request in `document.zig` (which
  already parses the preamble and sees the generated program) and passed in `Inputs`,
  instead of `processSourceImpl` re-running `syntax.roc` on every call
  (`bridge.zig:362`–`:372`).

### 4.4 The script path: keep `runEcho`, drop its JSON hop, share the header code

Do **not** fold `run`/`export` verification into the retained revision. They execute a
different program (`execution` = user program + generated `display!` helper + `main!`)
whose exact bytes are what users run with ordinary `roc`; `tests/documents.zig` asserts on
its `value` event stream and on export byte-identity. Folding would change what `export`
verifies. These actions are cold (CLI and tests), not on the editing hot path.

Instead:

```zig
pub const ScriptInputs = struct { source: []const u8, app_header: []const u8, extras: []const engine.ExtraFile, check_only: bool, args: []const []const u8, ... };
pub const ScriptOutcome = struct { status: []const u8, exit_code: u8, diagnostics: []const Diagnostic, events: []const Event, failure: ?[]const u8 };
pub fn runScript(gpa: std.mem.Allocator, inputs: ScriptInputs) !ScriptOutcome;   // wraps engine.runEcho
```

`document.zig:316` calls `runScript` directly. The raw `Request` path in
`processSourceImpl` becomes a thin JSON adapter over `runScript` (kept alive for
`tests/native.zig` "runtime dbg" until plan 06 decides).

Extract one header synthesiser used by both `runEcho` and `prepare`:

```zig
/// app [main!<, exposes...>] { pf: platform "./.roc_echo_platform/main.roc"<, shorthand: "spec"...> }\n\nimport pf.Echo\n\n
pub fn synthesizeAppHeader(a: std.mem.Allocator, io: compile.CoreCtx, app_header: []const u8, exposes: []const []const u8) ![]const u8;
```

`check` may use either path; recommended default: keep it on `runScript` with
`check_only` so all three script actions share one semantics. (Optional later: route
`check` through `prepare` with no roots to avoid the 256 MiB buffer; not required here.)

### 4.5 Phasing (why `document.zig` stays `Value`-based in phase 1)

`document.zig` builds its result as `std.json.Value` and `tests/documents.zig`,
`tests/m4.zig`, `web/document-conformance.mjs` and `web/m4-conformance.mjs` compare those
responses between native and WASM. Converting the whole of `document.zig` to typed structs
at the same time as replacing the evaluation back end would make a parity failure hard to
attribute. So:

- **Phase 1** replaces only the evaluation link (`snapshot.evaluate` → `evaluateDocument`)
  and must be response-identical (modulo `workspaceCache`). It removes the per-root JSON
  stages and the repeated analysis, which is the bulk of the benefit.
- **Phase 2** parses the document request once into a typed `DocumentRequest`, builds the
  response from typed structs (`DocumentResponse`), and serialises once in `bridge`. This
  removes the remaining whole-document parse/stringify stages (steps 2–4 and 16–18).
- **Phase 3** types the script path and shares the header synthesiser.
- **Phase 4** re-implements the M0 `cells` adapter in `snapshot.zig` over the typed API so
  `snapshot.invoke` and the JSON re-entry are gone from the binary entirely. Plan 06 then
  decides whether the adapter survives.

### 4.6 What remains of `snapshot.zig`

After phase 4, `snapshot.zig` is only: the M0 `Snapshot` request struct, cell assembly
with definition→cell mapping, and a call to `evaluateDocument`. No `invoke`, no `compile`
callback parameter, no JSON construction. It exists solely for `web/app.mjs`,
`web/conformance.mjs` and `tests/native.zig`'s `cells` cases.

---

## 5. Constraints and non-goals

- **Protocol 1 JSON at the boundary is unchanged** in this plan: every field, order and
  default seen by `tests/documents.zig`, `tests/m4.zig`, `tests/native.zig`, and the
  browser parity pages (`compilerSemantics` in `tests/harness.mjs:13` strips only
  `workspaceCache`, `transportMetrics`, `workerMs` and empty `packagesRequired`).
- **Counters:** `workspaceCache.frontend_builds`, `lowerings`, `executions` keep their
  meaning and values (Wall Area warm edit: 1/1/2; module edit: 1/1/2, asserted in
  `tests/workspace-benchmark.mjs:33` and `:48`). `prepared_hits` currently counts
  `notebook.run` calls that hit the slot (N+1 per warm request); after this change it
  counts requests served by the retained revision (0 or 1). Document the new meaning in
  `compiler-adapter/README.md`; no test asserts its value. Add an `analyses` counter.
- **Event bounds** (1,000 events / 256 KiB / 64 KiB per message / 512 KiB rich wire /
  single `truncated` marker, UTF-8-safe cut) are preserved exactly; move them, do not
  reinterpret them.
- Preserve: Display rich path (`text` + `wire` entrypoints), top-level `expect` test
  roots, `isolateErrors`/`isolate_errors`, the constant-crash `EvaluationFailureSummary`
  path (`notebook.zig:210`–`:216`), `packagesRequired` (`Workspace.global.required`
  reported in the response), compile-time observation replay for failed revisions, all
  native CLI verbs.
- **No growth of `compiler-adapter/embedding.patch`.** Everything here is adapter-side.
- **No new JS or npm dependencies.** Node scripts use only `node:` built-ins, as today.
- Non-goals: changing the fingerprint/plan (plan 03), retaining results (plan 02),
  removing globals beyond what the typed call forces (plan 04), the 512 MiB buffer
  (plan 05), deleting M0 entry points (plan 06).

---

## 6. Step-by-step implementation plan

Each step leaves `zig build test` green. Run the browser parity pages at the end of each
phase (they need Chrome; see §7).

**Phase 0 — baseline**
1. Add `tests/pipeline-benchmark.mjs` (§8.3). Run it and `node tools/browser-check.mjs
   --page web/workspace-benchmark.html --timeout 180000`; paste both outputs into the PR.
2. Run `zig build test-documents && zig build test-m4` and copy
   `artifacts/document-conformance.json` and `artifacts/m4-conformance.json` to
   `/tmp/before/` (they hold complete request/response pairs; §8.4 diffs them later).

**Phase 1 — typed evaluation link** (files: `notebook.zig`, `bridge.zig`, `document.zig`, `engine.zig`)
3. Add an `analyses: u64` counter next to `request_frontend_builds` in `engine.zig:724`
   and include it in `RequestStats.jsonStringify` (`engine.zig:734`). Increment it inside
   `analyzeFallible`. Tests still pass (optional counters are allowed:
   `tests/harness.mjs` strips `workspaceCache`; `tests/m4.zig` only reads named fields).
   Observe `analyses == N+2` in a saved response: this is the "before" evidence.
4. Move `analyzeFallible` from `bridge.zig:159` into `notebook.zig` (or `revision.zig`) as
   `fn analyzeRevision(state: *State) !Analysis`, allocating from the state's arena
   (`self.fba.allocator()`), and cache the result on `State`. Keep the bridge `analyze`
   callback signature for now but have it copy from the cached analysis. Counter drops to
   1 per revision. Covered by `zig build test` (native conformance, documents, m4).
5. Add `EventBuffer` to `notebook.zig` with the exact rules of `bridge.observe`
   (`bridge.zig:93`–`:119`), and a unit test for the bounds (1,001 events, a 70 KiB
   message, a UTF-8 cut inside a multibyte sequence, rich value at 512 KiB). Make
   `State.execute` take `*EventBuffer`; the bridge's global `observe` becomes a trampoline
   into the active buffer.
6. Add `Inputs`, `RootOutcome`, `Evaluation`, and `evaluateDocument` to `notebook.zig`
   implementing §4.2. Add a Zig unit test that calls it directly with two roots and one
   expectation and asserts: one `frontend_builds`, one `lowerings`, one `analyses`, three
   `executions`, `evaluated_roots` order, per-root event attribution, `isolate_errors`
   partial status. (These tests need the compiler modules; add them to the `test-unit`
   list in `build.zig:88`–`:89` with the same imports as the adapter executables, or add a
   `test-engine` step.)
7. In `document.zig`, replace the call at `:223` (check) and `:252` (selected roots) with
   `evaluateDocument`, converting with the existing `value(a, typed)` helper so the
   `evaluation` JSON stays identical. Remove the `evaluate`/`_: anytype` parameters from
   `document.process` (`:117`) for the notebook path; keep a `runScript` callback for
   `check`/`run`/`export` until step 11. Run §8.4 (before/after diff) and §8.2 parity.
8. Assert `workspaceCache.analyses == 1` in `tests/workspace-benchmark.mjs:33`/`:48` and
   in `tests/m4.zig` after each `suite.call` for `analyze`/`evaluate` requests.

**Phase 2 — typed document request/response** (files: `bridge.zig`, `document.zig`, new `protocol.zig`)
9. Introduce `protocol.zig` with `DocumentRequest` (every field read by `document.zig`,
   plus `workspaceFingerprint` and `reactivity.previous` set by the bridge as struct fields
   instead of JSON injection at `bridge.zig:512`–`:514`) and `DocumentResponse` (the fields
   enumerated in `compiler-adapter/protocol.d.ts` `DocumentResponse`). Parse the request
   once with `std.json.parseFromSlice(DocumentRequest, ...)` (`ignore_unknown_fields`).
10. Convert `document.process` to build `DocumentResponse` directly: event cell attribution
    (`document.zig:265`–`:280`), test location remap (`:281`–`:301`), Markdown events for
    rich `markdown` displays (`:302`–`:308`), `mapDiagnostics`, `locateDiagnostics`,
    `rendering`, `compact` stripping (`finishCompact`). Serialise exactly once in
    `bridge.processDocument`, and append `workspaceCache`/`packagesRequired` as struct
    fields rather than `:526`–`:527`. Delete the probe parse at `bridge.zig:300` by
    sniffing the first object key cheaply (or parse once into `DocumentRequest` with a
    union discriminator). §8.4 diff must still be clean.

**Phase 3 — script path and shared header** (files: `engine.zig`, `notebook.zig`, `document.zig`, `bridge.zig`)
11. Extract `synthesizeAppHeader` (§4.4) and use it from both `runEcho` and `prepare`.
    Gate: `grep -c 'pf: platform' compiler-adapter/*.zig` reports one definition site.
12. Add `runScript` wrapping `runEcho`; `document.zig` script actions call it directly;
    `processSourceImpl`'s raw path calls it. Delete the `evaluate` callback parameter
    entirely. `tests/documents.zig` (`values`, `export` demos, `roundtrip`) and
    `tests/native.zig` "runtime dbg" cover this.

**Phase 4 — M0 adapter over the typed API** (files: `snapshot.zig`, `bridge.zig`)
13. Re-implement `snapshot.evaluate` as cell assembly + `evaluateDocument`; delete
    `invoke`, the `compile` parameter, and `processSourceImpl`'s notebook branch
    (`bridge.zig:383`–`:403`). `tests/native.zig` fixture permutations cover this; the
    `snapshot.zig` unit tests that mock `compile` (`:245`–`:304`) are rewritten to mock
    at the typed boundary or moved to the `evaluateDocument` tests.
14. Delete `bridge.analyze`, the global `response`/`arena`/`user_bytes`/`bounded_events`/
    `event_bytes`/`events_truncated`/`rich_output`/`value_index`/`notebook_expectations`
    (plan 04 lists them; delete here whatever the typed path no longer touches).

**Docs**
15. Update `compiler-adapter/README.md` ("One compilation per revision", "WASM byte
    operations", counters), `docs/compiler-workspace.md` ("What changed"),
    `compiler-adapter/protocol.d.ts` (`CompilerCacheStats.analyses`). Delete this file.

---

## 7. Validation

### 7.1 Existing suites (all must pass at every step)

```sh
zig build test            # unit (snapshot/document/tools), workspace, package-fixture, native conformance, documents, m4
zig build test-unit
zig build test-workspace
zig build test-documents  # writes artifacts/document-conformance.json
zig build test-m4         # writes artifacts/m4-conformance.json
node --test tests/workspace.test.mjs
```

Browser parity and UI (requires Chrome; `CHROME_PATH` if not on PATH):

```sh
node tools/browser-check.mjs --page web/conformance.html            # M0 native-conformance replay in WASM
node tools/browser-check.mjs --page web/document-conformance.html   # document contracts, native vs WASM
node tools/browser-check.mjs --page web/m4-conformance.html         # selective evaluation parity + reactivity
node tools/browser-check.mjs --page web/workspace-conformance.html  # cache restore, packages, invalidation
node tools/browser-check.mjs --page web/edit-ui-conformance.html    # editor contracts (desktop)
node tools/browser-check.mjs --page web/edit-ui-conformance.html --viewport 640x900
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
```

### 7.2 New tests

- `notebook.zig` unit tests (step 6): typed `evaluateDocument` with 2 outputs + 1 expect;
  counters `frontend_builds=1, lowerings=1, analyses=1, executions=3`; `evaluated_roots`
  order; events attributed per root; `isolate_errors=true` yields `partial` with
  `root_errors` for a crashing root while the other value is present; `isolate_errors=false`
  returns `runtime_error` with no values (mirrors `snapshot.zig:261` "atomic" test).
- `EventBuffer` unit test (step 5) for every bound.
- `tests/workspace-benchmark.mjs` and `tests/m4.zig`: `workspaceCache.analyses == 1` for
  every `analyze`/`evaluate` response (step 8).
- Header synthesiser unit test: empty header, header with two packages, header containing
  the embedded Display package (must be skipped, `engine.isEmbeddedDisplayPackage`).

### 7.3 `tests/pipeline-benchmark.mjs` (new, Node built-ins only)

Generates documents with C ∈ {10, 30, 60} code cells (`a = 1`; `out_i = a + i`, one
`dbg` in every tenth cell, one `expect` in the last cell), writes them as `--bridge`
document `evaluate` requests, runs `zig-out/bin/roclet --bridge` five times each and
prints median wall time, request bytes, response bytes, and `workspaceCache` counters.
Not a pass/fail gate; record before/after numbers in the PR. Keep it under `tests/` and
out of `tools/package.zig`'s asset list.

### 7.4 Before/after response diff

```sh
node -e '
const strip=r=>{const {workspaceCache,transportMetrics,workerMs,...v}=r;if(v.evaluation)v.evaluation=strip(v.evaluation);return v;};
for (const f of ["document-conformance.json","m4-conformance.json"]) {
  const a=JSON.parse(require("fs").readFileSync("/tmp/before/"+f)), b=JSON.parse(require("fs").readFileSync("artifacts/"+f));
  for (let i=0;i<a.cases.length;i++) { const x=JSON.stringify(strip(a.cases[i].result)), y=JSON.stringify(strip(b.cases[i].result)); if(x!==y){console.log("DIFF",f,a.cases[i].name);process.exitCode=1;} }
}'
```

Must print nothing after phase 1, phase 2 and phase 4.

---

## 8. Acceptance gates

- [ ] `zig build test` green; all seven browser pages in §7.1 green at desktop and
      compact widths where applicable.
- [ ] §7.4 diff clean: every recorded document and M4 response is identical to the
      pre-change response modulo `workspaceCache`/timing.
- [ ] `workspaceCache` for the Wall Area warm edit is `frontend_builds=1, lowerings=1,
      executions=2` and for the module edit the same (benchmark assertions unchanged).
- [ ] `workspaceCache.analyses == 1` for every document `analyze`/`evaluate` request,
      including N-root requests (asserted in m4 and benchmark tests).
- [ ] No JSON stage between `document.zig` and the retained revision: `grep -n
      "snapshot.evaluate\|processSource" compiler-adapter/document.zig` is empty;
      `snapshot.zig` has no `invoke` and no `compile` parameter.
- [ ] After phase 2: `bridge.zig` parses a document request exactly once and serialises
      the response exactly once (code review + `grep -c parseFromSlice`).
- [ ] `grep -c 'pf: platform' compiler-adapter/*.zig` shows one definition site.
- [ ] `runEcho` is reachable only through `runScript` (script actions and the raw
      adapter); no notebook `evaluate`/`analyze` request calls it.
- [ ] `tests/pipeline-benchmark.mjs` 60-cell median is not slower than before, and the
      Wall Area / module-edit worker medians from `workspace-benchmark.html` are within
      noise of the recorded 9.7 ms / 8.1 ms (ReleaseFast, same machine, same Chrome).
- [ ] Event bounds unit test passes and the existing `truncated` behaviour in
      `web/document-conformance.mjs`/`tests/documents.json` cases is unchanged.
- [ ] `compiler-adapter/README.md`, `docs/compiler-workspace.md`, `protocol.d.ts` updated;
      this file deleted.

---

## 9. Risks, open questions, deferred decisions

1. **Revision arena pressure.** The analysis now lives in the 512 MiB fixed buffer with
   the revision. It is small (strings + small slices) but it is never freed until the
   revision is replaced. Default: accept; plan 05 restructures the buffer.
2. **Global observer until plan 04.** The trampoline keeps attribution dependent on
   set/clear ordering around `execute`. Default: assert in `execute` that no buffer is
   active on entry (non-reentrancy), and delete the trampoline in plan 04.
3. **Legacy token fields inside `evaluation`.** Document responses embed
   `requestId: "cli-1", documentRevision: 1, inputRevision: 0, workerGeneration: 1`
   because `snapshot.Snapshot` defaults them. Keep emitting them in phases 1–4 (parity).
   Drop them when plan 02 changes the evaluation shape (plan 02 does not bump the
   `protocol` number; it documents the change and rejects removed request fields).
4. **`prepared_hits` meaning changes** (N+1 per warm request → 0/1). No test asserts it,
   `docs/compiler-workspace.md` quotes "five compiler artifact hits" which is the cache
   `hits` field, not `prepared_hits`. Document the new meaning.
5. **Display detection.** `processSourceImpl:362`–`:372` sets `display_module` by scanning
   `import` statements in the user source with the syntax parser, and trusts the supplied
   `Display` module only if byte-identical to the embedded one (`:348`–`:361`). Move this
   into `document.zig` (or a helper in `revision.zig`) once per request and pass
   `rich_support` in `Inputs`. Keep the trust check; add a unit test (`import Display`
   present / absent / shadowed by a local `Display` type).
6. **Error-to-status mapping.** `processSourceImpl` maps `error.CompilationFailed` →
   `diagnostic`, other errors → `runtime_error`, and `callback_failed` → `OutOfMemory`.
   Reproduce in `evaluateDocument`; the §7.4 diff will catch drift because
   `tests/documents.json` includes failing cases.
7. **Where typed structs live.** Default: `revision.zig` for revision types,
   `protocol.zig` for request/response structs, `notebook.zig` shrinks to the
   prepare/execute implementation. Renaming can wait; keep diffs reviewable.
8. **Should `check` fold into the retained revision?** Default no (§4.4). Revisit when
   plan 05 shrinks the script-path buffer or if `roclet check` latency matters.
9. **Native `--bridge` raw path and M0 `cells` path.** Keep working over the typed API;
   their removal is plan 06's decision. Plan 06 (§10 Q1) recommends that the raw form
   survive as `operation: "program"` with the fields `{protocol, source, user_bytes,
   args?, check_only?, app_header?, modules?}`, so that `bridge.process` dispatches on
   `operation` alone. If you adopt that here, phase 3's raw adapter is that operation.

---

## 10. Cleanup when done

Delete: `snapshot.invoke`, the `compile`/`evaluate` callback parameters, the
`processSourceImpl` notebook branch, `bridge.analyze`/`analyzeFallible`, the bridge
observation globals listed in step 14, the JSON injection at `bridge.zig:512`–`:514` and
`:526`–`:527`, the duplicated header writer in whichever of `engine.zig`/`notebook.zig`
did not become `synthesizeAppHeader`, and `document.process`'s ignored fourth parameter.

Update: `compiler-adapter/README.md` (sections "One compilation per revision",
"Compiler build cache" counters, "WASM byte operations"), `docs/compiler-workspace.md`
("What changed"; re-measure and replace the benchmark table), `compiler-adapter/protocol.d.ts`
(`CompilerCacheStats.analyses`, `prepared_hits` comment).

Then delete `wip/01-typed-engine-pipeline.md`.
