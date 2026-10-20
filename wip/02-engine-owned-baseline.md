# Plan 02: one owner for the reactive baseline

## 1. Status

- Temporary work-in-progress handoff document. Delete it when the change lands.
- Branch: `integration/compiler-workspace`. Written 2026-10-20 against the
  current HEAD; every `path:line` below was verified at that commit. Re-verify
  line numbers before editing if the branch has moved.
- Sequencing: easiest after `wip/01-typed-engine-pipeline.md` (the baseline then
  hangs off the engine struct next to the retained revision). Section 5.6 gives a
  standalone route that needs neither plan 01 nor plan 04. Plan
  `wip/03-checked-dependency-graph.md` changes the fingerprint the baseline is
  keyed on; this plan is indifferent to how the fingerprint is computed as long
  as `graph.definitions[].fingerprint` and `graph.context` keep their meaning.
- Scope: Zig engine (`compiler-adapter/`), browser session and notebook model
  (`web/`), native CLI test driver, tests and docs. No editor or UI changes
  beyond removing the JS merge code.

## 2. Problem statement

Roclet evaluates only the output roots whose dependencies changed since the
last successful check. To do that, something must remember the previous
dependency graph and the previous results. Today that memory is split across
four places, with two copies of the same elision logic and a result merge that
runs in JavaScript against a decision made in Zig.

### 2.1 Four copies of the previous graph

| Copy | Where | Set | Read |
| --- | --- | --- | --- |
| `Notebook.baseline.result.graph` | `web/edit-model.mjs:174-178` (`publish`) | after every result that has a `graph` | `reactiveRequest` at `web/edit-model.mjs:161-172` |
| `DocumentSession.graph` (JSON string) | `web/document-session.mjs:100-101` | after every ok/partial result with a graph | elision at `web/document-session.mjs:69-73` |
| `previousGraph` (JSON string, inside the worker) | `compiler-adapter/wasm.mjs:51` | same condition | elision at `compiler-adapter/wasm.mjs:28-36` |
| `previous_graph` (bytes, inside WASM) | `compiler-adapter/bridge.zig:505,521-525` | whenever the document response carries `graph` | injected into the request at `compiler-adapter/bridge.zig:513-515` when the request's `reactivity` has no `previous` |

### 2.2 Duplicated elision with a sentinel

`Notebook.reactiveRequest` always sends the full previous graph plus a
placeholder `current` graph:

```js
// web/edit-model.mjs:167-168
request.reactivity = {known:!!previous?.graph, previous:previous?.graph ?? {context:'',scope:'module',definitions:[]},
  current:{context:'',scope:'module',definitions:[]}, roots:[], available:[...], force:...};
```

Two layers then strip `previous` and `current` again if they match what the
engine already confirmed, using the same sentinel test:

```js
// web/document-session.mjs:69-73
if(!fresh && this.engineBaseline && this.graph && request.reactivity) {
  const {previous,current,...reactivity}=request.reactivity;
  const placeholder=current?.context==='' && current.scope==='module' && current.definitions?.length===0;
  if(previous && JSON.stringify(previous)===this.graph && (!current || placeholder || JSON.stringify(current)===this.graph)) request={...request,reactivity};
}
// compiler-adapter/wasm.mjs:32-35 is the same four lines against previousGraph.
```

The bridge then puts `previous` back from its own copy
(`compiler-adapter/bridge.zig:513-515`). The graph is serialized on the JS side
to decide whether to send it, so that the engine can parse it back to decide
whether to use it. `tests/workspace.test.mjs:33-41` exists only to pin this
elision behaviour.

### 2.3 The decision is made in Zig, the reuse is done in JS

- `reactivity.available` is computed by JS from its previous values and passed
  tests (`web/edit-model.mjs:168`).
- `document.zig` builds the current graph (`compiler-adapter/document.zig:236`,
  `dependencyGraph` at `:432-451`), fills `reactivity.current`, `roots`, and
  `force` (`:238-247`), and calls `frontend.plan` (`:248`). The plan logic is
  `compiler-adapter/document_frontend.zig:740-768`; a root is reused only when
  its reason is `Unchanged dependencies`, which requires it to be in `available`
  (`:763-765`).
- Only `plan.evaluate` roots are executed (`compiler-adapter/document.zig:250-263`).
  The response contains values, events and tests for those roots only.
- `mergeCheckedResults` in `web/edit-model.mjs:37-62` then splices the old
  value strings, old events and old test results for every root in
  `plan.reused` back into the new response, re-sorts values and events by cell
  position, renumbers event `sequence`, and remaps each reused test's
  `cell/start/end/location/scope` through the new revision's `expectations`
  and `mappings` (`:46-61`). That remap duplicates the engine's own test
  location code at `compiler-adapter/document.zig:281-301`.
- `publish` (`web/edit-model.mjs:174-178`) stores the merged result as the new
  baseline. `check()` (`:192-197`) and `run()` (`:198`, publish at `:213`) both
  go through it; `inspect` for rename (`:249-262`) deliberately does not.

### 2.4 Restart and divergence handling

`DocumentSession.stop()` clears `graph` and `engineBaseline`
(`web/document-session.mjs:48-57`). On the next request `fresh` is true, so the
session skips elision and sends the JS baseline graph to a brand-new worker.
`engineBaseline` is set from `workspaceCache` presence at `:100`. The flag, the
`fresh` check, the placeholder sentinel, and the bridge injection are all
coordination code whose only purpose is to keep four copies in step. Any new
reuse feature (for example reusing events differently, or plan 03's richer
graph) has to be threaded through all of them.

### 2.5 Reuse logic lives apart from attribution logic

Reused `dbg` transcripts are chosen in JS, but the logic that decides which
compile-time observations belong to a root is `engine.DebugCapture.replay`
(`compiler-adapter/engine.zig`, `pub const DebugCapture`). Presentation reuse
and observation attribution are two halves of one question ("what is the
current transcript for this root?") answered in two languages.

## 3. Why it matters

- Maintenance: every reactive change touches `edit-model.mjs`,
  `document-session.mjs`, `wasm.mjs`, `bridge.zig`, `document.zig`,
  `tests/m4.zig`, `web/m4-conformance.mjs`, `tests/m4-benchmark.mjs`,
  `tests/workspace-benchmark.mjs` and `tools/browser-expect-probe.mjs`, each of
  which reimplements either the request shape or the merge.
- Correctness surface: the JS merge reconstructs an evaluation that the engine
  never produced. The native `tests/m4.zig` harness has to simulate the same
  merge (`tests/m4.zig:52-62`) to assert anything, so the thing actually shipped
  to the UI is only tested in the browser.
- Plan 01 moves the retained revision into a typed engine object. If the
  baseline stays in JS, plan 01 cannot simplify the request path (the bridge
  still has to inject and strip graphs).
- Plan 03 wants richer graph nodes (types, imports). With one owner, the graph
  never has to be serialized into requests at all, so its shape becomes an
  engine-internal detail with only `plan` and `explanations` public.

## 4. Current design walkthrough

1. `Notebook.run`/`check` call `reactiveRequest` (`web/edit-model.mjs:161-172`):
   `request.compact = true`, `reactivity = {known, previous, current(placeholder),
   roots:[], available, force}`, plus `forceAll`, `selectedCell`, `isolateErrors`.
2. `DocumentSession.request` (`web/document-session.mjs:59` onward) strips
   `previous/current` if they equal its confirmed string (`:69-73`), then posts
   to the worker.
3. `wasm.mjs` transport repeats the strip (`:32-35`) and encodes the request.
4. `bridge.processDocument` (`compiler-adapter/bridge.zig:506-528`) adds
   `workspaceFingerprint`, injects `previous` from `previous_graph` if absent,
   calls `document.process`, and stores the response's `graph` as the new
   `previous_graph`.
5. `document.process` (`compiler-adapter/document.zig:204-313` for the
   analyze/evaluate branch): assembles `all_roots` (outputs then expectations,
   `:204-207`), runs the check call, builds `graph`, computes `plan`, runs the
   selective call for `plan.evaluate`, attributes events to cells (`:266-280`),
   locates tests (`:281-301`), renders rich Markdown (`:302-308`), maps
   diagnostics and sets `status` (`:309-312`).
6. `Notebook.publish` merges and stores the baseline (`web/edit-model.mjs:174-178`).
7. Consumers of the merged result: `web/edit.mjs:380-381` (value per cell via
   `evaluation.values`), `:311-324` (dependencies dialog using
   `plan.explanations`, `plan.reused.length`, `graph.definitions`,
   `evaluation.evaluated_roots`), `:259` (completions fall back to
   `notebook.baseline?.result` while `notebook.result` is null during edits).
8. Test replicas of the merge: `tests/m4.zig:41-63`, `web/m4-conformance.mjs:20-24`
   (through the real `Notebook`), `tests/m4-benchmark.mjs:8-12`,
   `tests/workspace-benchmark.mjs:18,30,46`, `tools/browser-expect-probe.mjs:11,30,33`,
   `web/edit-ui-conformance.mjs:399-404`.

## 5. Target design

### 5.1 Ownership

The engine owns one `Baseline` per engine instance (one per WASM instance, one
per native process). The baseline outlives the retained revision: the revision
(`compiler-adapter/notebook.zig:33` `State`, replaced in `run` at `:313-333`
whenever the input key changes) is per source snapshot, while the baseline
spans snapshots. In plan 01/04 terms, `Baseline` is a field of `Engine`, not of
`Revision`.

```zig
// Engine-level, memory only. Never persisted, never imported from files.
pub const Baseline = struct {
    /// Serialized frontend.Graph of the last request that participated.
    graph: []u8,
    /// Per root: the raw per-root presentation exactly as produced by the
    /// snapshot layer BEFORE document.zig post-processing (cell attribution,
    /// test locations, Markdown rendering). Stored as serialized JSON so the
    /// std.json.Value-based document.zig can splice it back without a typed
    /// model; plan 01 may replace the bytes with a typed RootOutcome later.
    presentations: std.StringHashMapUnmanaged(Retained),
    bytes: usize,                 // sum of presentation sizes, for the cap
    pub const Retained = struct { json: []u8, size: usize, tick: u64 };
};
pub const retained_limit: usize = 64 * 1024 * 1024; // drop least recently stored beyond this
```

`Retained.json` is `{"value": Value|null, "events": [Event...], "test": TestResult|null}`
using the shapes from `compiler-adapter/snapshot.zig:32-64` (`Event`, `Value`,
`TestResult`). A root has a retained entry only if its last evaluation in this
engine succeeded: a value was produced, or the test passed.

### 5.2 Request shape

`reactivity` becomes a participation flag with two optional fields:

```ts
reactivity?: { force?: string[]; reset?: boolean };
// still top-level: forceAll?: boolean; selectedCell?: number; isolateErrors?: boolean
```

- Present (even `{}`): the request reads and updates the engine baseline.
- Absent: the request is stateless. It neither reads nor writes the baseline
  and evaluates every root (today's behaviour for requests without
  `reactivity`). This keeps parity replays and the rename candidate check
  (`web/edit-model.mjs:249-262`, `requestFor` without reactivity) from
  disturbing the live baseline.
- `reset: true`: drop the baseline before planning. The notebook sends it on
  the first reactive request after `replace`, `open`, `recoveryCopy`
  (`web/edit-model.mjs:305-320`) so a different document never sees
  "Unchanged dependencies" explanations inherited from the previous one.
  Correctness never depends on it (reuse requires equal context and
  fingerprints), it is for explanation hygiene.
- `known`, `previous`, `current`, `available`, `roots` are removed from the
  request. `document.zig` already overwrites `current` and `roots`.

### 5.3 Response shape

Every analyze/evaluate response that carries `graph` is complete:

```ts
evaluation.values: { root, text, display?, reused: boolean }[]   // one per current root with a value
evaluation.tests:  { root, passed, message, cell?, start?, end?, location?, scope?, reused: boolean }[]
evaluation.events: { kind, message, root?, cell, sequence, reused: boolean }[]
evaluation.evaluated_roots: string[]   // unchanged: exactly plan.evaluate
evaluation.root_errors: ...            // unchanged: failures from this request only
plan: { changed, evaluate, reused, explanations }   // unchanged
```

Ordering: iterate `all_roots` (document order, `compiler-adapter/document.zig:204-207`);
for each root append its retained presentation (when in `plan.reused`) or its
fresh presentation (when in `plan.evaluate`). This is the order a full run
produces, so `values` equals the full run's `values` modulo the `reused` flag.
Events keep that per-root grouping; `sequence` is assigned over the merged
list by the existing loop at `:266-268`.

`analyze` responses also return retained values for `plan.reused` roots. The
UI relies on that: `web/edit-ui-conformance.mjs:401-404` edits a cell, calls
`notebook.check()`, and expects the independent cell's value node to remain
current; `web/m4-conformance.mjs:21-22` expects `values` to equal the
retained right-hand value after a check.

### 5.4 Reuse rule

A root `r` is reused when all of the following hold. The first four are
already what `frontend.plan` computes; the fifth replaces `available`.

1. The request carries `reactivity` and `reset` is not set.
2. The engine has a baseline (`known`).
3. `baseline.graph.context == current.context` and scopes are equal, and not
   (`scope == "module"` and any definition changed).
4. Every definition in `r`'s transitive dependency closure has an unchanged
   fingerprint and unchanged dependency list (`definitionEqual`,
   `compiler-adapter/document_frontend.zig:725-739`), and `r` is not forced.
5. `baseline.presentations` has an entry for `r` (its last evaluation in this
   engine succeeded).

Forced roots (`force`, `forceAll`, `selectedCell`) are never reused. Failed
roots (runtime error, failed test) have no entry and are re-evaluated next
time, exactly as today's "No successful result".

### 5.5 Commit rule (what the engine remembers after a request)

After a participating request whose check succeeded (a `graph` exists):

- `baseline.graph` := current graph.
- For each root in `all_roots`:
  - evaluated this request and succeeded: store its fresh presentation;
  - in `plan.reused`: keep;
  - otherwise (failed, or listed in `plan.evaluate` by an `analyze` that ran
    nothing): drop.
- Roots not in `all_roots` are dropped.
- If `bytes > retained_limit`, drop entries with the smallest `tick` until
  under the limit. They are simply re-evaluated later.

After a participating request whose check failed (`diagnostic`,
`protocol_error`, runtime failure before a graph): leave the baseline as it was.
This mirrors `publish`, which only replaces the baseline when `result.graph`
exists (`web/edit-model.mjs:177`).

Bounds: each stored presentation is already bounded by `bridge.observe`
(`compiler-adapter/bridge.zig:93-111`: 64 KiB per text value, 512 KiB for a
rich wire payload at `:97`, 1000 events / 256 KiB per root at `:99-100`). The
64 MiB cap above is the only new limit.

### 5.6 Where the code goes

Two routes; pick the one matching whether plan 01 has landed.

**After plan 01/04 (preferred).** `Engine` gains `baseline: ?Baseline`.
`Revision.execute(root)` returns a typed `RootOutcome`; the merge in 5.3 and
commit in 5.5 operate on typed outcomes and `Retained` becomes
`RootOutcome` rather than JSON bytes. `document.zig`'s evaluate branch calls
`engine.plan(...)`, `engine.executeSelected(...)`, `engine.commit(...)`.

**Standalone (no plan 01).**

- `compiler-adapter/bridge.zig`: replace `previous_graph` (`:505`) with
  `var baseline: ?Baseline`. Remove the injection at `:513-515` and the capture
  at `:521-525`. Pass `&baseline` into `document.process` through the fourth
  parameter, which is currently the dead `processCore` argument (`:518`;
  `document.process` ignores it at `compiler-adapter/document.zig:117`).
- `compiler-adapter/document.zig`: in the evaluate/analyze branch
  (`:232-264`), after `dependencyGraph`: set `reactivity.known`, `previous`
  (parsed from `baseline.graph`) and `available` (keys of
  `baseline.presentations`) from the baseline instead of the request; honour
  `reset`. After the selective call, build the merged `evaluation` with two
  new pure helpers placed next to `dependencyGraph`:

```zig
/// Pure: builds the complete evaluation from the fresh selective evaluation
/// and retained presentations, in all_roots order, with reused flags.
fn mergeRetained(a: A, all_roots: []const V, plan: V, fresh: V, retained: *const std.StringHashMapUnmanaged(Baseline.Retained)) !V;
/// Pure: computes the next baseline presentation set per the commit rule.
fn commitPlan(gpa: A, baseline: *?Baseline, graph: V, all_roots: []const V, plan: V, fresh: V, action: []const u8) !void;
```

  The merged evaluation must be built before the post-processing loops at
  `:266-308` so cell attribution, test locations and Markdown rendering run
  over reused entries too. That deletes the JS remap wholesale.

- Both helpers must be testable without the compiler: keep them on
  `std.json.Value` only, so `zig build test-unit` (which compiles
  `compiler-adapter/document.zig` tests without the roc modules, see
  `build.zig` `test-unit` loop) can exercise them.

### 5.7 Native driver support

`tests/m4.zig` spawns one `roclet --bridge file` process per request
(`tests/documents.zig` `Suite.call`), so a native process never has a baseline.
Add a sequence mode to `compiler-adapter/native.zig` (`--bridge` handling at
`:31,64,101`): `roclet --bridge a.json b.json ...` processes the files in order
in one process and prints one JSON response per line. `tests/documents.zig`
gains `Suite.callSequence(names, requests)` that records each (request,
response) pair as a separate case in the same order. `tests/m4.zig` then runs
`before`, `selective`, `full` as one sequence; `web/m4-conformance.mjs:12-16`
already replays `native.cases` in order through one `DocumentSession`, so the
browser sees the same engine state as native and parity holds. `full` carries
no `reactivity`, so its position in the sequence does not matter.

## 6. Constraints and non-goals

- Protocol change is allowed: request fields removed, `reused` flags added.
  Document it in `compiler-adapter/README.md` and `protocol.d.ts`; no
  `protocol` number bump (JS and WASM ship together, and the
  `web/offline-release.json` manifest already pins them as a set).
- Native/WASM parity suites (`tests/documents.zig`, `tests/m4.zig`,
  `tests/native.zig` and their browser replays) must pass unchanged in spirit:
  responses compared field for field after `compilerSemantics`.
- Invariant kept: `plan.evaluate` equals `evaluation.evaluated_roots`
  (`tests/m4.zig:63`).
- No retained Roc values. Retained presentations are the bounded strings JS
  keeps today, now held one layer down. Nothing is written to IndexedDB,
  bundles, or the compiler artifact cache (`web/build-cache.mjs` stays
  artifact-only; `web/sharing.mjs` snapshots stay a separate explicit export).
- A baseline is a scheduling hint over a deterministic evaluation, never
  evidence (`docs/m4.md:60-64`). The engine must never return a retained value
  for a root whose closure or context changed.
- UI behaviour unchanged: same values, same explanations, same `reused` counts.
- Not in scope: cell-level request deltas, retaining results across worker
  restarts (see 10.1), changing how fingerprints are computed (plan 03).

## 7. Implementation steps

Each step leaves `zig build test` and the browser suites green.

### Step 1: engine-side baseline, backward compatible (Zig only)

Files: `compiler-adapter/bridge.zig`, `compiler-adapter/document.zig`,
`compiler-adapter/document_frontend.zig` (no change to `plan` itself),
`compiler-adapter/native.zig`, `tests/documents.zig`, `tests/m4.zig`.

1. Add `Baseline` and `retained_limit` (5.1) in `document.zig` (or a new
   `compiler-adapter/baseline.zig`); add `var baseline: ?Baseline` in bridge
   replacing `previous_graph`; pass it as the fourth `process` argument.
2. In `document.process`: if the request's `reactivity` has no `previous` and
   no `available`, use engine mode (5.4/5.5). If it has them, keep today's
   behaviour exactly (legacy mode: plan from request, response contains only
   evaluated roots, no `reused` flags, no commit). Engine mode responses carry
   `reused` on values, tests and events and are complete.
3. Implement `mergeRetained` and `commitPlan` with unit tests in `document.zig`
   (`zig build test-unit`): ordering, flags, drop-on-failure, drop-on-analyze,
   cap eviction, reset.
4. Add `--bridge` sequence mode to `native.zig` and `Suite.callSequence` to
   `tests/documents.zig`.
5. Extend `tests/m4.zig`: for every workload run both the legacy sequence (as
   today) and an engine-mode sequence `[before, selective{reactivity:{}}, full]`
   in one process; assert the engine-mode `selective.evaluation.values`
   stripped of `reused` equals `full.evaluation.values`, that each value's
   `reused` equals membership in `plan.reused`, and that `plan.evaluate ==
   evaluated_roots`. Record both sequences into `artifacts/m4-conformance.json`.
6. Run `zig build test`; run the browser m4 replay
   (`node tools/browser-check.mjs --page web/m4-conformance.html`). The replay
   now also exercises engine mode because the recorded sequence includes it.

### Step 2: switch the browser to engine mode (JS)

Files: `web/edit-model.mjs`, `web/document-session.mjs`,
`compiler-adapter/wasm.mjs`, `web/edit.mjs`, `web/m4-conformance.mjs`,
`tests/m4-benchmark.mjs`, `tests/workspace-benchmark.mjs`,
`tools/browser-expect-probe.mjs`, `tests/workspace.test.mjs`.

1. `reactiveRequest` (`web/edit-model.mjs:161-172`): send
   `reactivity = {force: forceAll ? [] : [], ...(this.resetBaseline ? {reset:true} : {})}`
   where `forceAll` maps to the existing top-level `forceAll` flag (the engine
   already expands it, `compiler-adapter/document.zig:241-243`). Remove
   `previous`, `current`, `known`, `available`, `roots`. Note the current
   `force: forceAll ? roots : []` where `roots` came from the baseline; with
   `forceAll` handled engine-side, `force` can be `[]`.
2. `publish` (`:174-178`): `this.result = result` (no merge). Keep a
   `this.lastChecked = result` when `result.graph` exists, used only by
   `web/edit.mjs:259` completions fallback (rename `baseline` to `lastChecked`
   there). Delete `mergeCheckedResults` (`:37-62`) and the `baseline` field
   initialisation (`:71`).
3. Set `this.resetBaseline = true` in `replace`, `open`, `recoveryCopy`
   (`:305-320`); clear it after the next reactive request is sent.
4. `DocumentSession`: delete `graph`, `engineBaseline` (`:52-53,69-73,100-101`).
5. `wasm.mjs`: delete `previousGraph` and the strip (`:28-36,51`).
6. Update harnesses that hand-build `reactivity`:
   `tests/m4-benchmark.mjs:8-12` (send `reactivity:{}`, compare complete
   `values` modulo `reused`), `tests/workspace-benchmark.mjs:18` (`reactive`
   helper becomes `{...request, compact:true, reactivity:{}}`; keep the
   `frontendBuilds/lowerings/rootExecutions` assertions at `:33,48`),
   `tools/browser-expect-probe.mjs:11` (`notebook.baseline=null` goes away;
   `setup` should trigger `reset`), `web/m4-conformance.mjs:20-24` (assertions
   hold as written; values now come from the engine).
7. `tests/workspace.test.mjs:33-41`: replace the elision test with
   "session forwards `reactivity` untouched and never adds graph fields".
8. Run `node --test tests/workspace.test.mjs`, the browser suites in section 8.

### Step 3: remove legacy mode (Zig + docs)

1. `document.process`: ignore (or reject with `protocol_error`, recommended:
   reject, so stale callers fail loudly) `reactivity.previous/current/available/known`.
2. `tests/m4.zig`: drop the legacy sequence.
3. `document_frontend.Reactive`: `known`, `previous`, `available` become
   engine-filled fields; consider renaming to `PlanInput` so the request shape
   and the planner input are visibly different types.
4. Docs and types: section 11.

### Step 4 (optional, small): typed retained outcomes

If plan 01 has landed, replace `Retained.json` with the typed `RootOutcome` and
move `mergeRetained`/`commitPlan` onto `Engine`. Behaviour and tests unchanged.

## 8. Validation

Commands (all from the repository root):

```sh
zig build test                     # unit, workspace, fixture, native, documents, m4 steps
zig build test-m4                  # selective vs full, writes artifacts/m4-conformance.json
zig build test-unit                # document.zig/snapshot.zig unit tests incl. mergeRetained/commitPlan
node --test tests/workspace.test.mjs
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/edit-ui-conformance.html
node tools/browser-check.mjs --page web/edit-ui-conformance.html --viewport 600x900
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000
```

`tools/browser-expect-probe.mjs` is driven through `browser-check` the same
way the other probes are; run it as before this change.

New tests and their assertions:

1. `document.zig` unit tests (`zig build test-unit`), pure `std.json.Value`:
   - merged `values`/`tests`/`events` follow `all_roots` order and carry
     `reused` matching `plan.reused`;
   - a root in `plan.evaluate` with no fresh value (analyze) is absent from
     `values` and dropped from the baseline;
   - a failed root (`root_errors`) is absent from the baseline afterwards;
   - `reset` empties the baseline before planning;
   - exceeding `retained_limit` evicts the oldest `tick` first;
   - a stateless request (no `reactivity`) leaves the baseline byte-identical.
2. `tests/m4.zig`, every workload in `tests/m4-workloads.json` (12 today):
   - engine-mode `selective.evaluation.values` minus `reused` equals
     `full.evaluation.values`;
   - `plan.evaluate` equals the workload's `evaluate`, `plan.reused` equals
     `reused`, `evaluated_roots` equals `plan.evaluate`;
   - the recorded sequence replays identically in the browser.
   Add workloads: `forced-root` (`force:[out_right]` with no change: `out_right`
   in evaluate, flagged `reused:false`), `failed-not-reused` (crash in `before`,
   fixed in `after`: the previously failed root is evaluated, the other reused),
   `context-change` (import added: everything evaluated, nothing reused),
   `test-reuse` (an `expect` root reused with its `cell/start/location`
   recomputed for the new revision).
3. `tests/workspace.test.mjs`: the session never adds `previous`, `current`,
   `known` or `available` to a request; a restarted session sends the request
   unchanged.
4. Browser, `web/m4-conformance.mjs:20-24` as is, plus: after
   `session.stop()` and a new reactive run, `plan.reused` is empty and every
   value is `reused:false` (restart has no baseline).
5. Benchmark: record `web/workspace-benchmark.html` medians before and after
   (`workerMs`, `requestBytes`, `responseBytes`). Request bytes must drop
   (no graph in requests); worker time must not rise beyond noise. Record the
   numbers in the PR description, not in docs, since docs/compiler-workspace.md
   measurements are tied to a named artifact.

## 9. Acceptance gates

All must be true before deleting this document.

- [ ] `grep -rn "previousGraph\|engineBaseline\|mergeCheckedResults\|previous_graph" web compiler-adapter tests tools` returns nothing.
- [ ] `grep -rn "context:'',scope:'module',definitions:\[\]" web tests tools` returns nothing (sentinel gone).
- [ ] Exactly one place holds a previous graph: `Baseline.graph` in the engine.
- [ ] `reactivity.previous`, `current`, `available`, `known` are rejected or ignored by the engine and sent by no caller.
- [ ] Every analyze/evaluate response with `graph` lists every current root's value, test and events, each with `reused`.
- [ ] For all workloads, selective values minus `reused` equal full-run values; `plan.evaluate == evaluated_roots`.
- [ ] A forced root is never `reused:true`; a root that failed in the previous request is never `reused:true`; a context change yields no `reused:true`.
- [ ] `analyze` after an edit keeps the independent root's retained value (`web/edit-ui-conformance.mjs:401-404` and `web/m4-conformance.mjs:21-22` pass).
- [ ] Reused tests carry `cell/start/end/location/scope` computed by the engine for the current revision; the JS remap code is deleted.
- [ ] Native sequence mode exists; `tests/m4.zig` runs before/selective/full in one process and the browser replay of `artifacts/m4-conformance.json` passes.
- [ ] `tests/workspace-benchmark.mjs` counter assertions (`frontendBuilds == 1`, `lowerings == 1`, `rootExecutions == 2`) still hold for warm edits.
- [ ] Retained bytes are capped (unit test) and never written to IndexedDB (`web/build-cache.mjs` untouched; `grep -n baseline web/build-cache.mjs web/sharing.mjs` empty).
- [ ] `zig build test`, `node --test tests/workspace.test.mjs`, and the browser pages in section 8 pass at desktop and compact widths.
- [ ] Docs in section 11 updated; `protocol.d.ts` matches the shipped shapes.

## 10. Risks, open questions, deferred decisions

### 10.1 Reuse across worker restart (behaviour change, accepted)

Today a restarted worker receives the JS baseline graph and the JS keeps its
value strings, so after Stop, a timeout, a WASM trap or a cancelled package
load, unchanged roots are not re-evaluated. With engine ownership a fresh
engine has no baseline, so the first run after a restart evaluates every root
once. Recommended default: accept it. Restarts are rare, the restarted worker
must rebuild the revision anyway, and the alternative (importing a baseline
from JS) reintroduces the second owner this plan removes. If measurements show
it matters, the only sanctioned extension is an explicit
`reactivity.import` that carries presentation strings and is treated as a
hint, never as evidence. Do not build it speculatively.
`tests/workspace-benchmark.mjs:55-57` (restored worker runs a stateless
request) is unaffected.

### 10.2 `reset` on document switch

Recommended: implement (one boolean, three call sites). Without it, opening a
second notebook with identical definitions in the same worker would show
"Unchanged dependencies" explanations that are true but surprising.

### 10.3 Should `plan.reused` remain in the response?

Yes. `web/edit.mjs:322` shows the count and `plan.explanations` are the user
facing reasons. The per-item `reused` flags are for consumers that only look at
`evaluation` (rendering, tests). Keep both; they must agree (unit test).

### 10.4 Should `analyze` return retained values?

Yes (5.3). The UI contract depends on it. The alternative (UI keeps old values
for reused roots) is exactly the JS-side ownership this plan removes.

### 10.5 Events: flag per event or infer from root?

Recommended: flag per event, for uniformity with values and tests and so the
browser replay compares complete objects. Cost is a few bytes per event.

### 10.6 Legacy mode rejection

Recommended: reject `previous/current/available/known` with `protocol_error`
after step 2 so a stale harness fails immediately rather than silently
evaluating everything.

### 10.7 Interaction with plan 03

Plan 03 may change `graph.definitions[].fingerprint` and `graph.context`
and may add type nodes. This plan only requires `definitionEqual` semantics
and a context string; `Baseline.graph` stores whatever `frontend.Graph`
becomes. Coordinate on the `Reactive`/`PlanInput` rename in step 3.

### 10.8 Memory

Worst case per root is ~832 KiB (64 KiB text + 512 KiB rich + 256 KiB events);
500 cells could in theory reach the 64 MiB cap quickly with rich images. The
cap just forces re-evaluation. Reconsider the cap if real notebooks hit it.

## 11. Cleanup when done

Code to delete:

- `web/edit-model.mjs`: `mergeCheckedResults` (`:37-62`), `baseline` field
  (`:71`, `:164`, `:175-177`), graph fields in `reactiveRequest` (`:167-168`).
- `web/document-session.mjs`: `graph`, `engineBaseline` (`:52-53`, `:69-73`, `:100-101`).
- `compiler-adapter/wasm.mjs`: `previousGraph` and the strip (`:28-36`, `:51`).
- `compiler-adapter/bridge.zig`: `previous_graph`, injection and capture (`:505`, `:513-515`, `:521-525`).
- `tests/workspace.test.mjs:33-41` elision test (replaced).
- Hand-built `reactivity` objects in `tests/m4-benchmark.mjs:8`,
  `tests/workspace-benchmark.mjs:18`, `tests/m4.zig:41-44`,
  `tools/browser-expect-probe.mjs:11`.

Docs and types to update:

- `compiler-adapter/README.md:143-145` ("The compiler retains its previous
  dependency graph. The transport omits ..."): describe the engine-owned
  baseline, the `reactivity` participation flag, `reset`, complete responses
  with `reused`, and the restart behaviour.
- `docs/compiler-workspace.md:57-58` ("Subsequent requests also omit the
  worker's already confirmed dependency graph."): requests no longer carry a
  graph at all.
- `docs/m4.md:53-64` adapter contract: the caller no longer keeps the previous
  graph or merges observations; the engine does.
- `compiler-adapter/protocol.d.ts:108` (`reactivity`), `:156-161`
  (`RecomputePlan` unchanged), `:196-202` (`evaluation` values/tests/events
  gain `reused`).
- Delete `wip/02-engine-owned-baseline.md`.
