# Plan 06: Retire the legacy entry points

## 1. Status

| | |
| --- | --- |
| Status | **Temporary WIP handoff plan. Delete this file when the work lands.** |
| Branch | `integration/compiler-workspace` (plan written at commit `35c3716`) |
| Date | 2026-10-20 |
| Sequencing | Steps A–D and F–H (JavaScript, test drivers, build wiring, docs) can start **now**. Step E (removing the `cells` dispatch and `snapshot.zig`) waits for [`01-typed-engine-pipeline.md`](01-typed-engine-pipeline.md), which turns `snapshot.zig` into a thin edge adapter. |
| Touches | `web/`, `tests/`, `fixtures/`, `core/`, `compiler-adapter/`, `build.zig`, `tools/`, `.github/workflows/pages.yml`, docs |
| Index | [`wip/README.md`](README.md) |

Line references below were verified with `grep -n` at the commit above. Re-verify before editing; the branch moves.

## 2. Problem statement

Roclet reached its current shape through milestones M0–M5. Each milestone kept its predecessor's entry points alive "for conformance", so today there are:

**Three dispatch paths into the engine.** `compiler-adapter/bridge.zig:293-310` (`process`) probes the request JSON and routes on shape:

| Condition | Path | Live user |
| --- | --- | --- |
| object with `operation` (`bridge.zig:303`) | `processDocument` → `document.zig` | The notebook editor, the format playground, every browser conformance page except M0, `roclet run/check/convert`, `tests/documents.zig`, `tests/m4.zig` |
| object with `cells` (`bridge.zig:306-307`) | `snapshot.zig` `evaluate` (`snapshot.zig:125`) | **M0 only**: `tests/native.zig`, `web/conformance.mjs`, `web/app.mjs` |
| anything else (`bridge.zig:309`) | raw protocol-1 `Request` → `processSourceImpl` (`bridge.zig:319`) | Internal re-entry from `document.zig:316` (check/run/export) and from `snapshot.zig:115` (`invoke`); externally only the `tests/native.zig:155` "runtime dbg" case via `--bridge` |

The `cells` path is a second notebook model: it assembles cells with `\n\n`, selects roots by name, and maps definitions back to cell keys (`snapshot.zig:125-243`). The document path does all of that in `document_frontend.zig`. Both must agree, and both are covered by parity suites that replay their recorded responses in WASM.

**Two browser session/worker protocols.**

| Protocol | Files | Users |
| --- | --- | --- |
| M0: one worker per evaluation, `{type:'initialize'}`/`{type:'evaluate'}` messages, token-gated results | `web/session.mjs` (`BrowserSession`), `web/worker.mjs`, `compiler-adapter/adapter.mjs` (`CompilerAdapter`, `RevisionGate`, `assemble`, `tokenOf`, `sameToken`, `byteOffsetToUtf16`, `CAPABILITIES`) | `web/app.mjs:1`, `web/conformance.mjs:1`, `tests/unit.test.mjs:2,100` |
| Live: persistent worker, `{bytes|module, request, workspace}` messages, package round-trips | `web/document-session.mjs`, `web/format-worker.mjs`, `compiler-adapter/wasm.mjs` | `web/edit-model.mjs:1` and every other page |

Nothing on the live path imports `adapter.mjs`: `grep -rn adapter.mjs` finds only `web/worker.mjs:1`, `web/session.mjs:1` and `tests/unit.test.mjs:2`. The `compilerCommit` the live code uses comes from `artifacts/manifest.json` (`web/edit.mjs:613-616`, `web/sharing.mjs:22,40`), not from `CAPABILITIES`.

**Dead build wiring.**

- `build.zig:149` adds `core/Document.roc` as an anonymous import, but no Zig file embeds it (`grep -rn 'embedFile("Document.roc")' compiler-adapter` is empty). `compiler-adapter/README.md:23` says it "remains as a reference; it is not executed". It is still a hashed adapter input in `tools/build-tool.zig:5`, a CI cache-key input (`.github/workflows/pages.yml:42`, `core/**`), and a served prefix (`tools/serve.zig:27`).
- `bridge.zig:312-315` defines `core_cache`/`processCore` and passes `processCore` to `document.process` (`bridge.zig:517`), whose fourth parameter is `_: anytype` (`document.zig:117`). The only other consumer of `engine.CachedProgram` (`engine.zig:100,110`) is the `cold_core` buffer sizing at `bridge.zig:405-406`, which can only be true when `cache != null`, i.e. never on any reachable path.
- `compiler-adapter/overlay.json` is `[]`; `compiler-adapter/README.md:7` already says it is not part of the build. Nothing reads it.
- `core/Revision.roc` is live only as a test fixture module (`tests/native.zig:135`).

**A protocol description nothing checks.** `compiler-adapter/protocol.d.ts` is hand-written, consumed by no tool (`grep -rn protocol.d.ts` outside `wip/` finds only `design.md:1483`, which points at a file in the Roc repository), and it has drifted from what the engine emits. Observed by collecting every key path in the recorded `artifacts/document-conformance.json`, `native-conformance.json` and `m4-conformance.json` responses:

| Drift | Detail |
| --- | --- |
| Missing operations | `operation: 'syntax'` (`document.zig:125`, used by `web/roc-highlighting.mjs:51`) and `operation: 'markdown'` (`document.zig:128`, used by `web/edit-conformance.mjs:172`, `web/math-conformance.mjs:11`) and their responses `{facts, blocks}` / `{status, events}` are not declared. |
| `evaluation` conflates two shapes | For `evaluate`/`analyze` it is the `snapshot.zig` `Result` (carries `requestId`, `documentRevision`, `inputRevision`, `workerGeneration`, `protocol`); for `check`/`run`/`export` it is the raw bridge `Response` (carries `display_module`, `workspaceCache`, `packagesRequired`). The d.ts declares neither set of extra fields. |
| Undeclared fields | `workerMs` (added by `web/document-session.mjs:102`), `draft.supplied`, `display_module`, snapshot-internal `possible_roots`/`failure_roots`/`app_header` (`snapshot.zig:7-20`). |
| Framing | The file presents the M0 `Snapshot` as "Roclet adapter protocol 1" and `DocumentRequest` as the "M1 formats" addendum, the inverse of what is live. |

## 3. Why it matters

- **Reasoning surface.** Anyone touching the engine must understand three request shapes, two worker protocols and two notebook models. Plans 01–04 all edit `bridge.zig`, `snapshot.zig` and `document.zig`; every retained legacy path is a second place each of those changes must be made and tested.
- **Parity suites spend effort on dead paths.** `tests/native.zig` records 36 cases, 21 of which are cell permutations through the M0 model, and `web/conformance.mjs` replays all of them in WASM through `BrowserSession`. That is real CI time and real maintenance protecting code no user runs.
- **Hidden coupling.** The live unit tests for project files, sharing bundles, `DocumentDraft` and `DocumentSession` (`tests/unit.test.mjs:6-50,129-176`) only run because the M0 page `web/conformance.mjs:5` imports the file. Deleting the M0 page naively would silently drop them.
- **Packaging and onboarding.** `tools/package.zig:76-134` ships an explicit asset list, so the M0 files are *not* in the offline bundle, but they are served by `roclet-serve`, linked from `web/index.html`, and documented as "the conformance suite" in `docs/m0.md:83` and `docs/m1.md:213`. A new contributor cannot tell which is current.
- **No enforced contract.** Browser and native are compared field for field, but nothing pins *which* fields exist. A field added on one path and forgotten on another is only caught if a parity fixture happens to exercise it.

## 4. Current design: inventory

| File | Role | Live users | Verdict |
| --- | --- | --- | --- |
| `web/session.mjs` | M0 `BrowserSession`: new worker per evaluation, `RevisionGate` | `web/app.mjs`, `web/conformance.mjs`, `tests/unit.test.mjs:100` | **Delete** |
| `web/worker.mjs` | M0 worker: `initialize`/`evaluate` messages via `CompilerAdapter` | `web/session.mjs:26` | **Delete** |
| `compiler-adapter/adapter.mjs` | M0 client: snapshot validation, `assemble`, `RevisionGate`, `byteOffsetToUtf16`, `CAPABILITIES` | `web/worker.mjs`, `web/session.mjs`, `tests/unit.test.mjs` | **Delete** (nothing live imports it; `CAPABILITIES` is a stale duplicate of `artifacts/manifest.json`) |
| `web/app.mjs`, `web/index.html` | M0 execution probe page | Reachable at `/web/index.html`; not packaged; links to `formats.html` and `conformance.html` | **Delete** |
| `web/conformance.html`, `web/conformance.mjs` | M0 parity + browser unit-test runner | `docs/m0.md:83`, `docs/m1.md:213` | **Delete**; move its live unit tests and lifecycle checks (see §6) |
| `tests/unit.test.mjs` | Mixed: live-path tests (lines 6–50, 129–176) and M0 tests (51–126) | `web/conformance.mjs:5` only | **Split**: live tests → `node:test`; M0 tests retired per §6 |
| `tests/fixtures.mjs` | `snapshot()` helper, fixture names, `permutations` | `tests/unit.test.mjs:3`, `web/conformance.mjs:3` | **Delete** with the above |
| `tests/harness.mjs` | Browser assert helper, `compilerSemantics`, `runTests` | All `web/*-conformance.mjs`, benchmarks | **Keep**; `runTests` (`harness.mjs:37`) becomes unused and can go |
| `fixtures/*.json` (7 M0 fixtures) | Cell-permutation notebook fixtures in snapshot shape | `tests/native.zig:120`, `web/app.mjs` (`debug.json`) | **Convert** to document `draft` fixtures in `tests/documents.json`, then delete |
| `tests/native.zig` | M0 native driver; writes `artifacts/native-conformance.json` | `build.zig:93-104` (`zig build test`) | **Retire** after its cases move (§6, §7 step A); keep only if plan 01 retains a raw request form that needs a driver |
| `compiler-adapter/snapshot.zig` | M0 notebook model + the internal per-root `invoke` loop | `bridge.zig:307`, `document.zig` (via `snapshot.evaluate`) | **Delete after plan 01** (plan 01 removes the internal use; this plan removes the external `cells` entry) |
| `bridge.zig:306-307` `cells` dispatch | External M0 entry | `tests/native.zig`, `web/conformance.mjs` | **Delete after plan 01** |
| `bridge.zig:309` raw `Request` entry | Lowest-level compile-and-run | `tests/native.zig:155`, internal callers | **Keep** as the engine's base contract; coordinate its external JSON form with plan 01 (§10) |
| `bridge.zig:312-315` `core_cache`, `processCore`; `engine.zig:100,110` `CachedProgram`; `bridge.zig:405-406` `cold_core` | Interpreted-`Document.roc` era program cache | none reachable | **Delete** |
| `core/Document.roc` | Reference implementation of the frontend policy, superseded by `document_frontend.zig` | `build.zig:149` (unused import), `tools/build-tool.zig:5`, CI cache key | **Delete**; the git history is the reference |
| `core/Revision.roc` | Test fixture module | `tests/native.zig:135-144` | **Move** to `fixtures/modules/Revision.roc`, then delete `core/` |
| `compiler-adapter/overlay.json` | Historical overlay list (`[]`) | none | **Delete** |
| `compiler-adapter/protocol.d.ts` | Hand-written types | none (no TypeScript in the build) | **Replace** with a pinned, machine-checked shape (§5) |
| `web/formats.html`, `web/formats.mjs` | M1 format playground on the live `DocumentSession` | `web/edit.html:123`; packaged (`tools/package.zig:102,111`) | **Keep** (live, out of scope) |
| `web/studio.html` | Redirect for old bookmarks | packaged (`tools/package.zig:128`); `docs/browser-package-validation.md:170` | **Keep** |
| `tools/serve.zig:27` prefixes, `:140-142` test | Serves `core/`, `fixtures/`, `tests/`; unit test uses the string `web/app.mjs` | — | **Update** |
| `docs/m0.md`, `docs/m1.md`, `docs/m2.md`, `docs/m*-validation.json` | Milestone records | historical | **Keep**, add a one-line "superseded" note where they name removed pages |

## 5. Target design

- **One worker protocol.** `web/document-session.mjs` → `web/format-worker.mjs` → `compiler-adapter/wasm.mjs`. Cancellation, generation gating, package round-trips and shared-module restarts already live there (`document-session.mjs:48-124`).
- **One bridge dispatch.** `bridge.process` accepts an object with `operation ∈ {document, syntax, markdown}`; everything else is a protocol error. The raw protocol-1 `Request` remains the engine's internal base contract (after plan 01, a typed Zig call; before it, the JSON form `processSourceImpl` parses). Whether a raw JSON form stays externally reachable through `--bridge` is decided with plan 01 (§10, Q1).
- **One notebook model.** `document_frontend.zig` segments, lowers and maps; `snapshot.zig`'s model is gone.
- **One test driver family.** `tests/documents.zig` (`Suite.call`, `documents.zig:31-40`) already records every request/response pair into `artifacts/document-conformance.json`, which `web/document-conformance.mjs:17-25` replays in WASM through the production session and again through fresh workers (`:30-43`). Migrated M0 cases inherit WASM parity for free. `tests/m4.zig:3,28` already reuses `docs.Suite` this way.
- **One source of truth for the wire shape.** Delete `protocol.d.ts`. Add `tests/protocol-shape.json`: the sorted set of `key.path type` lines observed across all recorded document responses and requests, checked by `tests/documents.zig` after the suite runs. Intentional protocol changes update the JSON in the same commit (a reviewable diff); accidental ones fail `zig build test`. Prose stays in `compiler-adapter/README.md`. Rationale for this choice over the alternatives: generating a d.ts from Zig is impossible today because `document.zig` assembles responses as `std.json.Value`, not structs (plan 01 phase 2 may change that, and the pinned shape file keeps working either way); a Node-side checker would need TypeScript to read a d.ts and would not run in CI, which only runs `zig build test` and `zig build package` (`pages.yml:53-54`).
- **No `core/` directory.** The Roc document core was replaced by Zig in M4/M5; keeping its file in the build inputs makes every manifest and CI cache key depend on dead code.

## 6. Constraints and non-goals

- **No loss of coverage.** Every M0 case moves or has a documented reason to retire:

| M0 case (`tests/native.zig`) | What it proves | Where it lives afterwards |
| --- | --- | --- |
| `forward`, `dependencies`, `anonymous`, `recursion`, `types`, `imports`, `debug` × all cell permutations (`:120-123`, 21 runs) | Cell order never matters; forward references; a false cell cycle (`c → b → a → out_1` across two cells); typed recursion; type declaration and annotation in different cells; in-memory module import; `dbg` attributed to its root | `tests/documents.json` `draft` evaluate fixtures with a new `permute: true` expectation flag expanded by `documents.zig` (the existing "notebook: wall permutation N" entries show the request shape; six are hand-expanded today) |
| `valid before errors`, `error/deletion/0-3`, `valid after errors` (`:124-127,134`) | Undefined name, type error, parse error, duplicate definition each yield a non-`ok` status with **no** values; the engine recovers afterwards | Same sources as consecutive `documents.json` evaluate fixtures with `status` + `evaluated_values: []` (add the trivial `evaluated_values` empty-array check if the harness does not already express it) |
| `supplied import` / `removed import` (`:128-133`) | Module present → value; removed → diagnostic | `documents.json` fixtures with `modules` |
| `Roc revision core` (`:135-144`) | A multi-definition Roc module imported from a file fixture evaluates | Same fixture with `modules: [{name:'Revision', content: <fixtures/modules/Revision.roc>}]`; `documents.zig` reads the file so the module is not inlined into JSON |
| `UTF-8 regions` (`:145-151`) | Definition byte regions index the original UTF-8 source correctly past multibyte characters | New `documents.zig` expectation `definition_source_text`: map `evaluation.definitions[0].region` through `mappings` (`source_start + start − generated_start`) into the request source (or the draft cell) and compare the slice |
| `selected roots and repeated dbg` (`:152`) | An unreachable definition's `dbg` is not reported; repeated identical `dbg`s are both kept | `documents.json` fixture with `events` expectation (`documents.zig` already compares event lists) |
| `atomic output failure` (`:153`) | Without error isolation a crashing root yields `runtime_error` and an empty value list | `documents.json` evaluate fixture **without** `isolateErrors`, expecting `status: runtime_error`, `evaluated_values: []` |
| `runtime dbg` (`:154-155`, raw request) | `dbg` inside `main!` at interpreter run time reaches the host observer; CLI args reach `main!` | Only reachable through a handwritten `main!`, which the document frontend diagnoses and never executes. Keep as a raw `--bridge` case **if** plan 01 retains an external raw JSON form (§10 Q1); otherwise move to a Zig unit test in `compiler-adapter/engine.zig` that calls the typed run entry with `args` and asserts the observed `dbg` message |
| `heap-backed strings` (`:156-157`) | Long (heap) strings inspect correctly | `documents.json` fixture |
| `unknown output root` (`:158`) | Requesting a root that does not exist is a diagnostic | Retired: roots are derived from `out_*` bindings in the document model, so the request cannot be expressed. The equivalent engine-internal guard (`error.EntrypointNotFound`, `notebook.zig:258,363`) stays. Note the retirement in the commit message |
| `web/conformance.mjs:39-45` cancel / restart / deletion lifecycle | Stop rejects with `AbortError`; restart works; a deleted name has no stale value | Already covered on the live session by `web/document-conformance.mjs:71-79` and `tests/workspace.test.mjs` ("session mounts unchanged files once and remounts after worker restart") |
| `tests/unit.test.mjs:51-69` `RevisionGate` | Stale tokens are rejected | Retired with the class; live gating is `document-session.mjs:78` (`this.worker !== worker || this.pending?.resolve !== resolve`) and is tested at `tests/unit.test.mjs:149-176` and in `tests/workspace.test.mjs` |
| `tests/unit.test.mjs:70-77` `byteOffsetToUtf16`, `assemble` | Byte→UTF-16 at character boundaries; cell assembly offsets | Retired: the live editor converts in `web/compiler-tools.mjs:3-15` (`sourceRange`), exercised by the M4 rename/UTF-8 browser contracts (`web/m4-conformance.mjs`). `assemble` has no live equivalent (the frontend owns assembly, tested by `document_frontend.zig` "source assembly names results without losing UTF-8 source ranges") |
| `tests/unit.test.mjs:78-82` `CompilerAdapter` validation | Invalid roots / duplicate keys rejected before compiling | Retired with the snapshot model; `snapshot.zig` "reject invalid snapshots before compilation" covers the Zig side until plan 01/step E removes it; the document model has no client-supplied roots or keys |
| `tests/unit.test.mjs:83-97` request ownership | A request is not affected by caller mutation after submission | Add a `node:test` for `DocumentSession.request` on the fresh-worker path (the only path where posting happens after an `await`, `document-session.mjs:116-122`): mutate the caller's request object after calling `request()` and assert the posted message is unchanged |
| `tests/unit.test.mjs:99-126` `BrowserSession` generations | Late results from a terminated worker are dropped | Retired; equivalent live test is `tests/unit.test.mjs:149-176` ("document worker survives completed requests but cancellation rejects late results") |

- `zig build test` and `zig build package` stay green at every step; CI runs exactly those (`pages.yml:53-54`).
- No UI change. `web/edit.html`, `web/formats.html` and `web/studio.html` are untouched.
- The offline bundle asset list (`tools/package.zig:76-134`) contains none of the deleted files; `unzip -l zig-out/roclet-pages.zip` before and after must differ only by `web/vendor/md4c.LICENSE.md` ordering noise, i.e. not at all.
- No new JavaScript dependencies. Node is used only for optional tests, as today.
- Milestone documents under `docs/` are historical records; they are annotated, not rewritten.

## 7. Step-by-step plan

Each step leaves `zig build test` green. Steps A–D, F, G, H do not depend on plan 01.

**Step A — Move the M0 native cases into the document suite.**

1. Add to `tests/documents.zig` `Suite.run`:
   - `permute: true`: when the request has `draft.cells`, run the fixture once per permutation of those cells (reuse the recursive swap from `tests/native.zig:62-74`), naming cases `<name>/<n>`. Expected values are order-independent in every migrated fixture, so the same `expect` block applies to each permutation.
   - `definition_source_text: "<text>"`: take `evaluation.definitions[0].region`, find the `mappings` entry containing `region.start`, compute `source_start + (region.start − generated_start)` and the same for `end`, slice the request `source` (or, for `draft` requests, the draft cell named by the mapping's `cell` plus its `body_start`), and compare.
   - `modules_from: [{name, path}]`: read module content from a repo-relative file before issuing the request, so `fixtures/modules/Revision.roc` is not inlined.
2. Add fixtures to `tests/documents.json` (document `evaluate`, `format: roc`, `draft` with `kind: code` cells, `isolateErrors` only where the M0 case had it, i.e. nowhere) for every row of the §6 table except the two "retired" rows and "runtime dbg".
3. Move `core/Revision.roc` to `fixtures/modules/Revision.roc`.
4. Run `zig build test-documents`; confirm the new case count equals the old `tests/native.zig` count minus the retired cases (36 − 2 "unknown root"/"runtime dbg" + the `documents.json` roundtrip sub-cases). Record the before/after counts in the commit message.
5. Run `node tools/browser-check.mjs --page web/document-conformance.html`; the migrated cases now replay in WASM, including through fresh workers.

Tests: `zig build test-documents`, document-conformance page.

**Step B — Move the live unit tests to `node:test`.**

1. Create `tests/edit-model.test.mjs` with `import {test} from 'node:test'` and `assert from 'node:assert/strict'` and port `tests/unit.test.mjs:6-50` (project modules, project paths, portable bundles) and `:129-176` (`DocumentDraft` ×2, `DocumentSession` late results). `web/archive.mjs` and `web/offline-cache.mjs` use only `TextEncoder`, `Blob`, `crypto.subtle` and `DecompressionStream`, all present in Node 22+; `tests/workspace.test.mjs` already imports `edit-model.mjs` and `document-session.mjs` under Node.
2. Add the fresh-worker request-ownership test from §6.
3. Run `node --test tests/`. Confirm 13 workspace + the ported count pass.
4. Delete `tests/unit.test.mjs` and `tests/fixtures.mjs`; remove `runTests` from `tests/harness.mjs:37-43` if nothing else calls it (grep).

Tests: `node --test tests/`.

**Step C — Delete the M0 browser surface.**

1. Delete `web/session.mjs`, `web/worker.mjs`, `web/app.mjs`, `web/index.html`, `web/conformance.html`, `web/conformance.mjs`, `compiler-adapter/adapter.mjs`.
2. `tools/serve.zig:140-142`: change the asset-path unit test string from `/web/app.mjs?version=1` to a file that exists, e.g. `/web/edit.mjs?version=1`.
3. Grep gate (§8) must be empty for `BrowserSession|session\.mjs|worker\.mjs|app\.mjs|adapter\.mjs|conformance\.mjs|conformance\.html` outside `docs/m*.md`, `docs/*-validation.json` and `design.md`.
4. `/web/` with no `index.html`: `roclet-serve` returns 404 for `/web/index.html`; the site root `index.html` is the home page and does not link there. Nothing else changes.

Tests: `zig build test` (serve.zig unit test), `node tools/browser-check.mjs --page web/edit-ui-conformance.html`.

**Step D — Remove dead engine wiring that does not depend on plan 01.**

1. `bridge.zig`: delete `core_cache` and `processCore` (`:312-315`); change `document.process(..., processSource, processCore)` (`:517`) to pass only `processSource`; delete the `cache` parameter of `processSourceImpl` (`:319`), the `cold_core` sizing (`:405-406`; keep the 256 MiB non-cold size, which is what every reachable call uses), `.cached_program = cache` (`:424`), and `bounded_events = cache == null` (`:325`, becomes constant `true`); `.analyze = if (cache == null) analyze else null` (`:422`) becomes `.analyze = analyze`.
2. `engine.zig`: delete `CachedProgram` (`:100`) and `RunOptions.cached_program` (`:110`).
3. `document.zig:117`: drop the fourth parameter.
4. `build.zig:149`: delete the `Document.roc` anonymous import. `tools/build-tool.zig:5`: remove `core/Document.roc` from `inputs` (this changes `artifacts/manifest.json` `inputs`, which only lists hashes; `web/sharing.mjs:22,40` compares `compilerCommit` and the WASM hash, not this list, so existing bundles still open).
5. Delete `core/Document.roc`, `compiler-adapter/overlay.json`, and the now-empty `core/` directory. Update `.github/workflows/pages.yml:42` to drop `core/**` from the cache key and `tools/serve.zig:27` to drop `core/`.
6. `compiler-adapter/README.md:7` (overlay sentence) and `:23` (Document.roc reference sentence): delete.

Tests: `zig build test`, `zig build package`.

**Step E — Remove the `cells` entry and `snapshot.zig` (after plan 01).**

Precondition: plan 01 has made `document.zig` call the retained revision directly, so `snapshot.evaluate` has no internal caller and `tests/native.zig` has been retired by step A.

1. `bridge.zig:306-307`: delete the `cells` branch. `bridge.process` becomes: parse JSON; require an object with `operation`; else return a `protocol_error` response (keep the `files` mounting at `:302` for document requests only).
2. Decide the raw path per §10 Q1. If plan 01 keeps an external raw JSON form, keep `:309` for it and add the "runtime dbg" case to `tests/documents.json` as a raw fixture (extend `Suite.run` with `raw: true`, mirroring `tests/native.zig:24`); otherwise delete `:309` and the `Request` struct, and add the engine unit test described in §6.
3. Delete `compiler-adapter/snapshot.zig`, its entry in `build.zig` unit-test list (`build.zig:89` `inline for` list) and in `tools/build-tool.zig:5` inputs, and `tests/native.zig` plus its `roclet-conformance` wiring (`build.zig:93-104`). Delete `fixtures/*.json` (the seven M0 fixtures). Remove `fixtures/` from `tools/serve.zig:27` only if nothing under `fixtures/` is served (`fixtures/documents/rich-outputs.roc` is fetched by `web/edit.mjs:494`, so keep the prefix).
4. `artifacts/native-conformance.json` is no longer produced; nothing else reads it after step C.

Tests: `zig build test`, document-conformance page, m4-conformance page.

**Step F — Pin the wire shape.**

1. Add `tests/protocol-shape.json`: a sorted JSON array of strings `"<key.path> <type|type>"`, where `[]` marks array elements and types are `string|number|boolean|null|object` as JSON sees them. Generate it from the recorded responses and requests of the document suite (the M4 suite's responses are a subset; include them anyway).
2. In `tests/documents.zig` `main`, after writing `artifacts/document-conformance.json`, walk every recorded `request` and `result`, collect the observed set, and compare with the pinned file. On mismatch print the added and missing lines and fail. Add `zig build test-documents -Dupdate-protocol-shape` (a build option passed through as an argv flag) to rewrite the file.
3. Delete `compiler-adapter/protocol.d.ts`. In `compiler-adapter/README.md`, replace mentions of the d.ts with: "The wire shape is pinned in `tests/protocol-shape.json` and checked by `zig build test-documents`; `operation: syntax` and `operation: markdown` are part of that shape."
4. Exclude `model.cells[].facts`, `blocks` and `first_block` subtrees from the pin only if their token-tag enumeration proves noisy across compiler bumps; otherwise pin everything.

Tests: `zig build test-documents` must fail when a field is renamed in `document.zig` without updating the pin (try it once, locally, and revert).

**Step G — Docs.**

- `README.md`: no change expected (it does not mention the removed pages); verify.
- `docs/installation.md:84-86`: already lists the live conformance pages; verify nothing else.
- `docs/m0.md:83` and `docs/m1.md:213`: add "(superseded; see `web/document-conformance.html`)" after the `conformance.html` mention. Leave `docs/*-validation.json` untouched.
- `docs/compiler-workspace.md` "Validation" section: replace "36 compiler cases" wording with the document-suite count after step A.
- `compiler-adapter/README.md`: remove the "WASM byte operations" references to `adapter.mjs` if any (grep; today it names `wasm.mjs` only).

**Step H — Final sweep.**

Run every command in §8, the grep gates, and the packaged-asset diff. Delete this file.

## 8. Validation

```sh
# Native suites (CI runs the first and last of these)
zig build test
zig build test-documents
zig build test-m4
zig build test-unit
zig build package

# Node (no npm); Node 22+
node --test tests/*.test.mjs

# Browser parity and UI contracts (Node 22+ and a local Chrome)
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/edit-ui-conformance.html
node tools/browser-check.mjs --page web/edit-conformance.html
node tools/browser-check.mjs --page web/m5-conformance.html
node tools/browser-check.mjs --page web/math-conformance.html
node tools/browser-check.mjs --page web/m3-conformance.html
node tools/browser-check.mjs --page web/demos-conformance.html
```

Pages that remain after this plan: `document-`, `edit-`, `edit-ui-`, `m3-`, `m4-`, `m5-`, `math-`, `workspace-`, `demos-conformance.html`, plus `workspace-benchmark.html` and `m4-benchmark.html`. Removed: `web/conformance.html`.

Grep gates (run from the repository root; every command must print nothing):

```sh
grep -rn "BrowserSession\|RevisionGate\|CompilerAdapter\|byteOffsetToUtf16" --include=*.mjs --include=*.html --include=*.zig --include=*.md . | grep -v "^./web/vendor\|^./zig-pkg\|^./.toolchain\|^./zig-out\|^./docs/m[0-9]\|^./docs/.*-validation.json\|^./design.md\|^./wip/"
grep -rn "web/session.mjs\|web/worker.mjs\|web/app.mjs\|adapter.mjs\|web/conformance.mjs\|web/conformance.html\|tests/unit.test.mjs\|tests/fixtures.mjs" --include=*.mjs --include=*.html --include=*.zig --include=*.md --include=*.yml . | grep -v "^./web/vendor\|^./zig-pkg\|^./.toolchain\|^./zig-out\|^./docs/m[0-9]\|^./docs/.*-validation.json\|^./wip/"
grep -rn "processCore\|core_cache\|CachedProgram\|cold_core\|overlay.json\|Document\.roc\|core/" compiler-adapter build.zig tools .github | grep -v "ROC-LICENSE"
grep -rn "protocol.d.ts" . --include=*.md --include=*.mjs --include=*.zig | grep -v "^./design.md\|^./wip/\|^./zig-pkg\|^./.toolchain"
# After step E only:
grep -rn "snapshot.zig\|native-conformance\|contains(\"cells\")" compiler-adapter build.zig tools tests web | grep -v "^web/vendor"
```

Packaged assets: `unzip -l zig-out/roclet-pages.zip | awk '{print $4}' | sort` before step C and after step H must be identical.

Counts to record in the final commit message: `tests/documents.json` fixture count before/after; `node --test tests/` test count before/after; the number of `artifacts/document-conformance.json` cases replayed by the document-conformance page before/after.

## 9. Acceptance gates

- [ ] `zig build test` and `zig build package` pass on a clean checkout after `sh tools/prepare-compiler.sh`.
- [ ] `node --test tests/` passes and includes the six ported live unit tests plus the fresh-worker ownership test.
- [ ] Every row of the §6 coverage table has either a named fixture/test in the tree or a commit-message note for the two retired rows; the "runtime dbg" row has one of its two stated homes.
- [ ] `bridge.process` has exactly one JSON dispatch (`operation`) after step E, and no `cells` handling before it is reachable from any test or page.
- [ ] `compiler-adapter/` contains no `snapshot.zig`, `adapter.mjs`, `overlay.json` or `protocol.d.ts` after step H; `core/` does not exist; `fixtures/` contains only `documents/` and `modules/`.
- [ ] `tests/protocol-shape.json` exists, is checked by `zig build test-documents`, and a deliberate field rename in `document.zig` fails that step (verified once locally, change reverted).
- [ ] The document-conformance page replays at least as many WASM parity cases as `native-conformance` + `document-conformance` did before (sum recorded in the commit message), including the migrated permutations.
- [ ] All grep gates in §8 print nothing.
- [ ] `unzip -l zig-out/roclet-pages.zip` file list is unchanged.
- [ ] `docs/m0.md`, `docs/m1.md` carry the "superseded" note; `compiler-adapter/README.md` and `docs/compiler-workspace.md` no longer mention removed files or counts.
- [ ] This file is deleted.

## 10. Risks, open questions, deferred decisions

**Q1 — Does an external raw request form survive plan 01?** Today `document.zig:316` and `snapshot.zig:115` re-enter the raw JSON `Request`; plan 01 replaces those with typed calls. The only *external* use is the `tests/native.zig:155` "runtime dbg" case through `--bridge`. Recommended default: plan 01 keeps a minimal raw JSON form `{protocol, source, user_bytes, args?, check_only?, app_header?, modules?}` behind `operation: "program"` (so dispatch stays single-keyed), and this plan moves "runtime dbg" to a raw `documents.json` fixture. If plan 01 drops it, use the engine unit test instead. Decide when plan 01's design is fixed; step E is the only step affected.

**Q2 — Permutation expansion in `documents.zig` versus literal JSON.** Literal expansion of the seven fixtures is 21 entries and keeps the driver simple; a `permute` flag keeps the JSON readable. Default: the flag; it also lets the six hand-expanded "wall permutation" entries collapse to one.

**Q3 — Pinning `facts`/`blocks`.** Token-tag names (`model.cells[].facts.tokens[].tag`) are compiler enum names and will change on compiler bumps. The pin records key paths and JSON types, not values, so a compiler bump does not break it unless a key is added or removed. Default: pin everything; revisit if churn appears.

**Q4 — Removing `web/index.html` leaves `/web/` without an index.** Acceptable: the site root is `index.html` (home page), and `tools/serve.zig` only special-cases the root. If a landing page for `/web/` is wanted later, that is a UI decision outside this plan.

**Q5 — `tests/harness.mjs` `compilerSemantics` strips `workspaceCache`, `transportMetrics`, `workerMs`, `packagesRequired`.** The pinned shape must include them (they are part of the wire shape) while parity comparison must keep ignoring them. Keep the two concerns separate: the pin is computed from raw recorded responses in Zig; `compilerSemantics` stays as is.

**Risk — silently dropped tests.** The main hazard in this plan is step B/C ordering: deleting `web/conformance.mjs` before porting the live unit tests removes their only runner with no failing signal. Do B before C and confirm `node --test tests/` runs the ported tests by making one fail deliberately once.

**Risk — manifest `inputs` change.** Removing `core/Document.roc` from `tools/build-tool.zig:5` changes `artifacts/manifest.json`; `tools/build-tool.zig:82-86` compares inputs to detect an outdated adapter, so a stale `artifacts/` directory reports "Adapter inputs changed" until `zig build` reruns. Expected; mention it in the commit message.

**Risk — CI cache key.** Dropping `core/**` from `pages.yml:42` changes the key, causing one cold CI build. Expected.

## 11. Cleanup

Delete:

```
web/session.mjs  web/worker.mjs  web/app.mjs  web/index.html
web/conformance.html  web/conformance.mjs
compiler-adapter/adapter.mjs  compiler-adapter/overlay.json  compiler-adapter/protocol.d.ts
compiler-adapter/snapshot.zig              (step E)
tests/unit.test.mjs  tests/fixtures.mjs  tests/native.zig   (native.zig at step E)
fixtures/forward.json fixtures/dependencies.json fixtures/anonymous.json
fixtures/recursion.json fixtures/types.json fixtures/imports.json fixtures/debug.json   (step E)
core/Document.roc  core/  (Revision.roc moves to fixtures/modules/)
wip/06-retire-legacy-paths.md
```

Edit: `compiler-adapter/bridge.zig`, `compiler-adapter/engine.zig`, `compiler-adapter/document.zig`, `build.zig`, `tools/build-tool.zig`, `tools/serve.zig`, `.github/workflows/pages.yml`, `tests/documents.zig`, `tests/documents.json`, `tests/harness.mjs`, `compiler-adapter/README.md`, `docs/compiler-workspace.md`, `docs/m0.md`, `docs/m1.md`.

Add: `tests/edit-model.test.mjs`, `tests/protocol-shape.json`, `fixtures/modules/Revision.roc`.

Update `wip/README.md`'s plan table only to strike this row when done, then delete the directory with the last plan.
