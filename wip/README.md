# Compiler integration and notebook management: handoff plans

**Temporary.** Everything in `wip/` is a handoff plan for work that has not
started. Delete each plan when its feature lands; delete this directory when
all seven are done. Nothing here is user documentation or a design record.

These plans came out of an architecture review of the core compiler
integration and notebook management on 2026-10-20, on branch
`integration/compiler-workspace` at commit `35c3716`. UI and UX were out of
scope. The review's summary verdict: the compiler contract itself is sound
(one checked graph and one lowered image per revision, a fresh interpreter per
root, compiler-owned package resolution and hash verification, opaque
compiler-keyed artifact persistence, a small typed embedding patch). The
changes below are about where state and work live, not about the contract.

Each plan is self-contained and written for an implementer with no other
context. Line references were verified when written; re-verify them before
relying on them, since the branch moves.

## Plans

| Plan | What changes | Why |
| --- | --- | --- |
| 01 Typed engine pipeline (done) | `document.zig` calls the retained revision through typed Zig functions instead of re-entering the public JSON entry point once per root. JSON exists only at the WASM/native boundary. | Per-root JSON re-parse, re-hash and a repeated O(definitions × CIR nodes) analysis scale with cells × roots. Also shares one app-header synthesiser between the notebook and script pipelines; the check/run/export script path keeps its own pipeline but loses its JSON hop. |
| 02 Engine-owned baseline (done) | The engine retains the last successful presentation per root and returns complete value sets with `reused` flags. JS stops carrying the previous graph and merging old results. | The previous graph lives in four places with duplicated elision logic; reuse is decided in Zig but performed in JS. |
| 03 Checked dependency graph (done) | Definition fingerprints come from checked CIR, not source text; type declarations and annotations become graph nodes and edges; the module-scope fallback shrinks. | A comment edit between cells invalidates every root today, and any nominal type declaration disables selective evaluation entirely. |
| 04 Engine state struct (done) | Module-level globals become an explicit `Engine` struct with a request-scoped observer. | Single-tenant engine, nesting-dependent event attribution, no in-process parallel tests, header parsed through a workspace side channel. |
| 05 Image buffer vs revision arena (done) | Only what the LIR image requires lives in a flat buffer; everything else in a growable arena; the flat buffer is sized adaptively. | A fixed 512 MiB reservation per revision sets both the memory floor and a hard ceiling that the Debug engine already hits. |
| 06 Retire legacy paths (done) | One worker protocol, one bridge dispatch, one source of truth for protocol types; dead build wiring removed. | Three dispatch paths, two session/worker protocols, an unused Roc core import and a drifting `protocol.d.ts`. |
| [07 Side-by-side notebooks](07-side-by-side-notebooks.md) | Two notebook panels on one page, each with its own worker and engine; the title moves to the top of each panel and the status bar to a fixed bar at its bottom. | Exercises plans 01, 02, 04, 05 and 06 with two engines alive at once (attribution, per-engine baselines, memory, shared caches, package prompts) in the real UI. Implement after 02. |

## Sequencing

```
01 typed pipeline  ──┬──>  02 engine-owned baseline  ──>  03 checked graph (keys 02's retained results)
04 engine struct   ──┘
        │
        └──>  05 image buffer (easier with one prepare path; can be done first on notebook.zig alone)
        └──>  06 retire legacy (JS/build-wiring parts any time; engine-side `cells` removal after 01)
```

- Do 01 and 04 together. They touch the same functions and each is simpler
  with the other in place.
- 02 is possible standalone but much easier once the retained revision is a
  typed object (01).
- 03 is independent of 01 in principle but edits the same analysis code, so
  land it after 01 or coordinate closely.
- 05 and 06 can be slotted in whenever convenient, with the stated caveats.

## Conventions every plan follows

- **Tree stays green at every step.** Each step names the tests that cover it.
- **Protocol-1 JSON at the boundary is preserved unless the plan says
  otherwise.** Native and WASM responses are compared field for field by the
  parity suites (`tests/documents.zig`, `tests/m4.zig` and
  the `web/*-conformance.html` pages through `tests/harness.mjs`
  `compilerSemantics`). Any protocol change must be documented in
  `compiler-adapter/README.md`, and the pinned wire shape in
  `tests/protocol-shape.json` regenerated with `-Dupdate-protocol-shape`. The
  `protocol` number is bumped only when an older client's request could be
  misinterpreted; JS and WASM ship together as a pinned set
  (`web/offline-release.json`), so additive response fields and rejected
  request fields do not need a bump. Plan 02 removes request fields and adds
  `reused` flags without a bump; it rejects the old fields with
  `protocol_error` instead.
- **Work counters keep their meaning.** `workspaceCache.frontend_builds`,
  `lowerings`, `executions` and `prepared_hits` are how tests prove reuse
  without wall-clock timing.
- **No retained Roc values across responses.** Retained presentation strings
  are allowed; Roc heap values, closures and interpreter state are not.
- **No new JavaScript dependencies, no Node or npm requirement.**
- **`zig build check` stays green.** It runs `zig fmt --check`, the tidy rules in
  `ci/tidy.zig` (including the dead private declaration and dead Zig file
  scans) and the lints in `ci/zig_lints.zig`; `zig build test` depends on it.
  When a plan deletes a file or a function, these are what notice leftovers.
- **The embedding patch stays small.** Prefer reading existing compiler
  structures; if an addition is unavoidable the plan specifies the minimal API.
- **Docs are updated in the same change**: `compiler-adapter/README.md`,
  `docs/compiler-workspace.md`, the protocol description, and the relevant
  `docs/m*.md` adapter-contract sections. The protocol description is
  `tests/protocol-shape.json`, a pinned, machine-checked wire shape that
  replaced `compiler-adapter/protocol.d.ts`.

## Shared validation commands

```sh
# Native: unit, workspace, package fixture, native conformance, document contracts, M4 workloads
zig build test
zig build test-unit
zig build test-workspace
zig build test-documents
zig build test-m4

# Node (no npm)
node --test tests/*.test.mjs

# Browser parity and UI contracts (Node 22+ and a local Chrome; no npm)
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/edit-ui-conformance.html
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000

# Formatting, tidy rules, lints, dead Zig files (also part of zig build test)
zig build check

# Packaging (also run by CI)
zig build package
```

Record benchmark numbers with the machine, Chrome version and optimisation
mode, as `docs/compiler-workspace.md` does. Wall-clock timings are
measurements, not pass gates; counters and result equality are the gates.

## Coordination status

Work happens on `plan/*` branches in agent worktrees and lands on
`integration/code-checks` by fast-forward or rebase, so history stays linear.
Iterate with the self-hosted backend (`-Dllvm=false`, native suites and
`node --test tests/*.test.mjs`). LLVM builds, browser pages and benchmarks are
deferred to one final validation pass when the PR is ready.

| Plan | State |
| --- | --- |
| 06 steps A–D (JS, tests, build wiring), G | Merged (`plan/06a-retire-legacy-js`) |
| 04 engine struct | Merged (`plan/04-engine-struct`) |
| 01 typed pipeline | Merged (`plan/01-typed-pipeline`) |
| 05 image buffer | Merged (`plan/05-image-buffer`; step 6 landed with plan 01) |
| 02 engine-owned baseline | Merged (`plan/02-engine-baseline`) |
| 06 step E (single `operation` dispatch) | Merged (`plan/06e-retire-legacy-dispatch`) |
| 03 checked dependency graph | Merged (`plan/03-checked-graph`) |
| 06 step F (pin the wire shape), H | Merged (`plan/06f-protocol-shape`) |
| 07 side-by-side notebooks | In progress |

### Deferred final validation (LLVM)

- `zig build`, `zig build test`, `zig build package`; packaged asset list
  identical to before plan 06 (98 entries).
- Browser pages: document-conformance (expect at least 261 responses and 115
  fresh-worker runs before plan 06 step E), edit-ui (46 contracts, desktop and
  compact), workspace, m4, m5, edit, math, m3, demos conformance.
- Benchmarks: `web/workspace-benchmark.html` against the recorded medians.
- Plan 04: first LLVM WASM build of the Observer change (`echoHostedFn`'s
  `js_echo` branch now reads `ops.env`); `test-engine` under LLVM ReleaseFast;
  workspaceCache counters unchanged in the benchmark (1 frontend build, 1
  lowering, 2 executions per warm edit).
- Plan 05: first LLVM WASM link and run of the image path (`rawAlloc` on the
  wasm allocator, 1 MiB first buffer, `roclet_options` import);
  `zig build test -Dimage-initial-bytes=65536`; `zig build -Doptimize=Debug`
  then `zig-out/bin/roclet run demos/04-meeting-windows.roc` (expect ok, six
  values, two passing tests); benchmark `imageRetriesMedian == 0`, warm Wall
  Area `memoryBytesMedian` at most half the baseline measured at `4cd70fb`,
  the 256 MiB `maxWallMemoryBytes` bound (chosen without a browser
  measurement), timings within 10 %; add a memory column to the
  `docs/compiler-workspace.md` measurements table.
- Plan 01: first WASM run of the typed bridge, `engine.prepareBuiltins`, and
  script runs through `image.build` on wasm32; `test-engine` under LLVM;
  `node tests/pipeline-benchmark.mjs` on the ReleaseFast binary (self-hosted
  60-cell median went 377 ms to 180 ms); packaged assets exclude
  `tests/pipeline-benchmark.mjs`; benchmark asserts `analyses == 1` per warm
  edit with medians near 9.7 ms and 8.1 ms.
- Plan 06 step E: document-conformance replays 262 cases including the
  `operation: "program"` runtime dbg fixture; `workspace-conformance` and
  `m5-conformance` run their converted document requests in a browser for the
  first time (they sent M0 `cells` requests before).
- Plan 02: `zig build test` re-records `artifacts/m4-conformance.json` (45
  cases replayed in order through one worker, with `reset` sequences);
  m4-conformance asserts `reused:true` after `check()` and no reuse after
  `session.stop()`; edit-ui (desktop and 600x900) lines ~401-404;
  `tools/browser-expect-probe.mjs`; workspace-benchmark counters still 1/1/2
  with `analyses == 1`, and `requestBytes` should drop (no graph in requests).
- Plan 03: m4-conformance replays 84 responses; native vs WASM determinism of
  graph v2 fingerprints (module identity hashes, type strings); edit-ui
  dependency dialog with type nodes, changed scope note, F2 rename; benchmark
  worker ms (each analysis adds one parser pass over the user program).
- Plan 06 step F: document-conformance replays 264 cases, including the new
  `syntax` and `markdown` fixtures; packaged asset list unchanged
  (`protocol.d.ts` was not packaged). `docs/compiler-workspace.md` still
  quotes "30 complete selective/full evaluation responses"; M4 now records 84
  across 28 workloads, so refresh the validation section with the LLVM run.
