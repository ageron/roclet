# Compiler integration and notebook management: handoff plans

**Temporary.** Everything in `wip/` is a handoff plan for work that has not
started. Delete each plan when its feature lands; delete this directory when
all six are done. Nothing here is user documentation or a design record.

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
| [01 Typed engine pipeline](01-typed-engine-pipeline.md) | `document.zig` calls the retained revision through typed Zig functions instead of re-entering the public JSON entry point once per root. JSON exists only at the WASM/native boundary. | Per-root JSON re-parse, re-hash and a repeated O(definitions × CIR nodes) analysis scale with cells × roots. Also shares one app-header synthesiser between the notebook and script pipelines; the check/run/export script path keeps its own pipeline but loses its JSON hop. |
| [02 Engine-owned baseline](02-engine-owned-baseline.md) | The engine retains the last successful presentation per root and returns complete value sets with `reused` flags. JS stops carrying the previous graph and merging old results. | The previous graph lives in four places with duplicated elision logic; reuse is decided in Zig but performed in JS. |
| [03 Checked dependency graph](03-checked-dependency-graph.md) | Definition fingerprints come from checked CIR, not source text; type declarations and annotations become graph nodes and edges; the module-scope fallback shrinks. | A comment edit between cells invalidates every root today, and any nominal type declaration disables selective evaluation entirely. |
| [04 Engine state struct](04-engine-state-struct.md) | Module-level globals become an explicit `Engine` struct with a request-scoped observer. | Single-tenant engine, nesting-dependent event attribution, no in-process parallel tests, header parsed through a workspace side channel. |
| [05 Image buffer vs revision arena](05-image-buffer-vs-revision-arena.md) | Only what the LIR image requires lives in a flat buffer; everything else in a growable arena; the flat buffer is sized adaptively. | A fixed 512 MiB reservation per revision sets both the memory floor and a hard ceiling that the Debug engine already hits. |
| [06 Retire legacy paths](06-retire-legacy-paths.md) | One worker protocol, one bridge dispatch, one source of truth for protocol types; dead build wiring removed. | Three dispatch paths, two session/worker protocols, an unused Roc core import and a drifting `protocol.d.ts`. |

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
  parity suites (`tests/documents.zig`, `tests/m4.zig`, `tests/native.zig` and
  the `web/*-conformance.html` pages through `tests/harness.mjs`
  `compilerSemantics`). Any protocol change must be documented in
  `compiler-adapter/README.md` and `protocol.d.ts` (or its replacement). The
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
  `compiler-adapter/protocol.d.ts` until plan 06 step F lands, and
  `tests/protocol-shape.json` (a pinned, machine-checked wire shape) after it.
  Where a plan says "update `protocol.d.ts`", read it as "update whichever of
  the two exists".

## Shared validation commands

```sh
# Native: unit, workspace, package fixture, native conformance, document contracts, M4 workloads
zig build test
zig build test-unit
zig build test-workspace
zig build test-documents
zig build test-m4

# Node (no npm)
node --test tests/workspace.test.mjs

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
