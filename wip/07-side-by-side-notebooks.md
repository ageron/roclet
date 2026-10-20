# Plan 07: two notebooks side by side, per-panel title and status bar

## 1. Status

- **Temporary WIP plan.** Delete it when the feature lands (section 11).
- Branch: `integration/code-checks`. Written 2026-10-20 against HEAD `394f2f9`
  ("Mark plan 06 step E merged and fix plan 06 grep gates"). Every `path:line`
  below was verified at that commit. Re-verify before editing; the branch moves.
- Sequencing: implement **after plan 02 merges**. Plan 02 changes the
  request/response contract this UI consumes (`reactivity: {force?, reset?}`,
  complete responses with `reused` flags, `Notebook.baseline` becomes
  `lastChecked`, `mergeCheckedResults` deleted; see `plan/02-engine-baseline`).
  Building the panel component on the pre-02 model would mean porting the JS
  merge into it and then deleting it again. Ideally also after plan 03, so the
  reuse assertions in section 8 can include the comment-edit and type-declaration
  cases; the plan does not depend on 03 and section 8 marks the 03-only checks.
- Dependencies: plan 02 (hard), plan 03 (soft), plan 06 step F (soft: if the wire
  shape is pinned first, this plan must not add request fields; it adds none).
  Plans 01, 04, 05 and 06 A–E have landed and are what this feature validates.
- Scope: `web/` JavaScript, HTML and CSS, `tools/package.zig` asset list, new
  browser contract page, Node tests, docs. **No engine changes.** If two panels
  expose an engine bug, report it with a reproduction and stop; do not work
  around it in JS.

## 2. Goal and user-facing behaviour

The user asked for three things: two notebooks side by side on one screen; the
status bar as a fixed bar at the bottom of each notebook panel; the notebook
title at the top of the notebook instead of in the header. The purpose is to
exercise the recent engine changes (one `Engine` per worker, request-scoped
observers, the typed pipeline, the adaptive image buffer, the single operation
dispatch, and plan 02's engine-owned baseline) in a real UI with two engines
alive at once.

### 2.1 Layout

- **One panel (default).** Same content as today, re-arranged: a one-row global
  header; below it one notebook panel filling the rest of the viewport. The
  panel has a **title bar** at its top, a scrolling body (notice, document
  diagnostics, App header, cells or source view), and a **status bar** fixed at
  its bottom. The page itself no longer scrolls; the panel body does.
- **Two panels.** The workbench splits into two equal columns (fixed 50/50, a
  1px divider; resizing is a non-goal). Each column is a complete panel with its
  own title bar, body and status bar, scrolling independently.
- The status bar is a flex child of the panel, not `position: fixed`, so with
  two panels there are two bars, each pinned to the bottom of its own column.

### 2.2 Opening a second notebook

- **Command:** View → **Open side by side…** opens a small dialog listing:
  Recent notebooks (excluding any already open), **New notebook**, the bundled
  examples (the same map as `web/edit.mjs:638-644`), and **Independent copy of
  this notebook**. Choosing one opens it in the right panel. The command is
  disabled while two panels are open.
- **URL:** `edit.html?notebook=<A>&right=<B>`, where `right` is a draft id,
  `new`, or `example:<name>` (for example
  `edit.html?example=reactivity&right=example:weather`).
  Justification: the existing deep link is `?notebook=<id>`
  (`web/home.mjs:19`, consumed at `web/edit.mjs:634`), not `?id=`, and
  `web/studio.html:3` forwards the query string unchanged, so reusing
  `notebook` keeps every existing link valid. Naming the slot (`right`) rather
  than adding a second id list keeps one-panel URLs byte-identical to today.
  `example:` and `new` let validation open two known documents with one URL.
- One-panel mode keeps today's URL behaviour: `notebook`/`new` and `example` are
  stripped after loading (`web/edit.mjs:636`, `:653`). While two panels are
  open the workbench writes `?notebook=<A>&right=<B>` with `history.replaceState`
  whenever either panel's document id changes, so a reload restores both
  panels. The "most recent draft" fallback (`web/edit-model.mjs:77`) can only
  restore one panel and is never used for the right one.

### 2.3 Title at the top of each panel

The title is an editable `<input>` at the left of the panel's title bar,
exactly the control that is in the header today (`web/edit.html:99`, wired at
`web/edit.mjs:479` as an undoable `title` change group). Renaming stays where
it lives now: typing in the title input. Next to it, right-aligned in the same
bar: **Auto-run**, **▷ Run all**, **Stop** (today in the header,
`web/edit.html:100`), and, in two-panel mode only, a **×** close button. These
are per-notebook actions and must sit with the notebook they act on. The title
bar is `position: sticky; top: 0` inside the panel scroller, so it stays
visible.

`document.title` is `<title> — Roclet` with one panel (as at
`web/edit.mjs:438`) and `<left> | <right> — Roclet` with two.

### 2.4 Status bar at the bottom of each panel

Left side: the notebook status (`role="status"`, today `#status`,
`web/edit.html:128`) and the cell selection hint (today `#selection-status` in
the footer, `web/edit.html:133`). Right side: the save status (today
`#save-status`), the **Keyboard shortcuts** button (today `#help` in the
footer) and an optional **engine details** segment:

`worker 34 ms · 1 evaluated · 3 reused · 96 MiB`

from `result.workerMs`, `result.evaluation.evaluated_roots.length`, the count of
values with `reused: true` (plan 02; equal to `plan.reused.length`) and
`result.transportMetrics.memoryBytes` (`web/format-worker.mjs:35`). The segment
is a per-viewer preference (View → **Show engine details**, stored in
`localStorage` like the theme, wrapped in try/catch, default off) and shows
`—` until the panel's first completed response. The same numbers already appear
in the Dependencies & timing dialog (`web/edit.mjs:322`); the status bar reuses
that computation.

### 2.5 What stays in the global header

Logo and brand (home link), and the menus: File, Edit, View (including Theme
and the new side-by-side commands), Help. The header shrinks from two rows
(`web/edit.html:39`, `grid-template-rows:32px 26px`) to one. No document title
remains in the header in either mode (the user asked for it to move, and a
header title would be ambiguous with two panels).

### 2.6 Focus model

- Exactly one panel is **active**: the panel that last received `focusin` or
  `pointerdown`. Focus moving into the header or a dialog does not change it.
- The active panel's title bar carries an accent top border and the panel's
  accessible name ends in ", active"; with one panel this is invisible.
- Every header menu command (File, Edit, View items except Theme, Help's
  shortcuts dialog) acts on the active panel. Each menu's first row reads
  `For: <title>` when two panels are open, so the target is never a guess.
- Panel-scoped keyboard shortcuts (cell navigation, Enter, A/B, Delete,
  Cmd+Enter, Cmd+Z in cell mode, copy/cut/paste of cells) act on the panel that
  contains the event target. Global shortcuts (Cmd+S download, Shift+Cmd+F find,
  `?` with nothing focused, Cmd+Z with `document.body` focused) act on the
  active panel.
- Undo is per panel (each `Notebook` owns `history`/`future`,
  `web/edit-model.mjs:70`). There is no cross-panel undo.

### 2.7 Narrow widths

- One panel: unchanged compact layout, including the 390px contract width.
- Two panels at viewport width **≥ 900px**: columns. Each panel picks its own
  compact cell layout from **its own width** through a CSS container query, so a
  640px column on a 1280px screen gets the compact cell grid.
- Two panels **below 900px**: **tabs**, not stacking. A `role="tablist"` strip
  above the workbench shows both titles plus a status dot (running, needs
  attention, not saved); only the selected panel is displayed; the hidden panel
  stays alive (its worker keeps evaluating and its status keeps updating in the
  tab). Recommendation rationale: each panel needs its own scroll container and
  a bottom bar; stacking two of those on a phone produces nested scroll areas
  and a status bar in the middle of the screen, and the second notebook would be
  effectively unreachable below a long first one.

### 2.8 Closing a panel

The × button (and View → **Close side panel**) persists the closing panel
first; if the save fails, closing is refused with the existing "Download a
copy" guidance. Closing the right panel disposes it (`Notebook.dispose`,
`web/edit-model.mjs:321`, terminates its worker). Closing the left panel makes
the left slot adopt the right panel's document (`replace(record)`, which sends
`reset` under plan 02) and disposes the right panel; the right panel's undo
history is lost, which the confirmation text states. The primary slot never
moves, so the legacy element ids (section 5.2) stay stable.

## 3. Why it validates the engine

Each engine change, the behaviour two panels force through it, and the
assertion that proves it (contract names refer to section 8.3).

| Engine change | What two panels exercise | Observable assertion |
| --- | --- | --- |
| Explicit `Engine` per worker (`compiler-adapter/engine_state.zig:10`; the WASM layer's single `wasm_engine`, `compiler-adapter/bridge.zig:85`) | Two notebook workers, each with its own `Engine`, run concurrently; neither can see the other's revision, workspace or counters | D2: both panels' values equal the values the same documents produce alone; D3: A's `workspaceCache.executions` for a one-root edit is 1 whether or not B ran in between |
| Request-scoped `Observer` attribution (`compiler-adapter/README.md:41-48`, `platform.zig`) | `dbg` and `expect` in different cells of two notebooks evaluated at the same time | D6: every `.debug`/`.tests` block appears only in its own panel and cell, with that notebook's unique message; no event has `cell == null` |
| Typed pipeline (`notebook.checkDocument`, `Checked.evaluate`, `analysis.zig`) | Each engine prepares and retains its own revision; edits in B never touch A's retained revision | D3: A re-run with no edit reports `prepared_hits == 1`, `analyses == 0`, `frontend_builds == 0`; after a one-cell edit `analyses == 1` |
| Adaptive image buffer (`image.zig`, `memoryBytes` in `web/format-worker.mjs:35`) | Two WASM instances plus the syntax highlighter instance alive at once; plan 05 replaced the fixed 512 MiB reservation that would have made this cost 1 GiB+ | D11: each panel reports its own `memoryBytes`, each ≤ 256 MiB and the sum ≤ 512 MiB for the fixtures; `image_retries == 0` on warm runs |
| Single `operation` dispatch (`bridge.zig`) | `syntax` requests from the shared highlighter and `document` requests from two notebooks interleave across three workers | D2/D6 responses contain no `protocol_error`; highlighting keeps working in both panels (D13) |
| Plan 02 engine-owned baseline, `reused` flags, `reset` | Two baselines, one per engine; document switches inside one panel | D4: reuse in A is unaffected by edits and runs in B; D5: after switching a panel to another document (even one with identical source) the first response has every `reused == false` and `plan.reused` empty |
| Plan 03 checked graph (soft) | A comment edit in A; a type declaration added in B | D4b (03 only): A's comment edit reuses every root; B's type declaration does not change A's `graph.scope` |
| Shared compiled `WebAssembly.Module` (`web/document-session.mjs:2-10`) | Three workers start from one compilation only if every session receives the same `ArrayBuffer` | D10: `WebAssembly.compile` is called exactly once for both panels and the highlighter |
| IndexedDB compiler cache (`web/build-cache.mjs`, imported at worker start `web/format-worker.mjs:18`, saved before the response `:34`) | B's worker starts after A has saved artifacts | D9: B's first response has `workspaceCache.hits ≥ 1` and `misses ≤` A's first-response misses |
| Package cache and prompts (`web/packages.mjs`, `web/package-dialog.mjs`) | Both notebooks require the same package that cannot be downloaded | D8: one dialog for one URL, both panels resume with the one selection; a later fresh worker restores it without a prompt |
| Cancellation (`DocumentSession.stop`, `web/document-session.mjs:48-57`; `Notebook.stop`, `web/edit-model.mjs:245-247`) and per-notebook timeout (`web/edit-model.mjs:208`) | Stop in A while B is mid-request | D7: B's worker object is unchanged, B's request resolves with values, B's status never shows "Stopped" |
| Workspace project files (`web/workspace.mjs`, `web/document-session.mjs:64-68`) | Same module path `Geometry.roc` with different contents in each notebook | D12: A shows `15`, B shows `24`; editing A's file never changes B's value |
| Draft store optimistic concurrency (`web/edit-store.mjs:162-177`) | Two notebooks saving concurrently; the same notebook requested in both panels | D14/D15: both save; the duplicate request follows the section 5.4 policy and never produces a silent overwrite |

## 4. Current design inventory: single-notebook assumptions

### 4.1 `web/edit.mjs` module state and lookups

| Where | Assumption | Change |
| --- | --- | --- |
| `web/edit.mjs:12` | `$ = id => document.getElementById(id)` for every panel element | Panel code uses `this.part(name)` scoped to its root (`[data-part=name]`); `$` survives only for global header and dialogs |
| `:13` | one `store`; one `compilerManifest` | store per panel (section 5.4); manifest stays shared |
| `:14` | one `notebook`, `sourceEditor`, `headerEditor`, `headerDocumentId`, `libraryToken`, `composing` | fields of `NotebookPanel`; `highlighter` stays shared |
| `:15` | one `cards` map | per panel |
| `:16` | `notice()` writes `#notice` | per panel |
| `:56` | `renderObservation` reads the global `notebook.status` | panel's notebook |
| `:66-67` | one `CellSelection`, `documentId`, `selectionActive` | per panel |
| `:71-77` | `closeMenus` closes every open popover in the document | stays global (closing all menus is correct) |
| `:82` | focus fallback `$('notebook')` | panel's notebook section |
| `:131`, `:596` | `#selection-status` | panel status bar |
| `:196-213` | find dialog searches the one notebook | searches the active panel, captured when opened |
| `:255` | `results.id = result-${cell.key}`; copies keep cell keys (`recoveryCopy` clones cells, `web/edit-model.mjs:307`), so two panels can hold equal keys and duplicate ids | prefix with the panel id |
| `:259` | completions fall back to `notebook.baseline` (`lastChecked` after 02) | panel's notebook |
| `:291-303` | `$('cells')` | panel part |
| `:307-327` | dependencies dialog reads the one `notebook.result` | opened for a given panel; the timing line (`:322`) is factored out for the status bar |
| `:328-338` | rename dialog closes over the one notebook | closes over the calling panel |
| `:342`, `:368-371`, `:421-423` | `#document-diagnostics` | panel part |
| `:425-433` | `refreshLibrary` fills one `#recent` select | File menu reflects the active panel; options open in the active panel subject to section 5.4 |
| `:434-463` | `reflect` writes header title (`:437`), `document.title` (`:438`), `#auto`/`#format` (`:439`), `#stop`/`#run` (`:440-441`), `#status` (`:443`), `#save-status` (`:444`), `#recovery-copy` (`:445`), `#undo`/`#redo` (`:446`), view toggles (`:447-449`), App header and source editors (`:450-454`), `#generated` (`:461`) | split: panel parts are rendered by the panel; header menu state (`format`, `recovery-copy`, `undo`, `redo`, view toggles) is rendered by the workbench from the active panel, and again whenever the active panel changes |
| `:465-478` | `document` `focusout` handler with the one notebook | listener on the panel root (focusout bubbles) |
| `:479`, `:483-484` | title, run, stop, auto handlers | panel title bar |
| `:490-497` | undo, recovery copy, new, rich example, recent, open file, preview | header commands routed to the active panel |
| `:498-520` | project files dialog bound to the one notebook | bound to the panel active when the dialog opened |
| `:521-538` | download, share/export | active panel |
| `:539-541` | offline dialog | global, unchanged |
| `:547-550` | document click closes menus | global, unchanged |
| `:551-586` | one `document` capture-phase `keydown` handler for everything | split into a global handler (Escape in header menus, Cmd+S, Shift+Cmd+F, `?`, body Cmd+Z) on `document`, and a panel handler registered capture-phase on each panel root (runs before CodeMirror's handlers for targets inside the root, as today) |
| `:587-607` | `copy`/`cut`/`paste` on `document`, `ownsClipboard` checks `$('notebook')` | listeners on the panel root |
| `:608` | `beforeunload` checks the one notebook | any panel not "Saved in this browser" |
| `:613` | the WASM binary is fetched once | keep: the same `ArrayBuffer` must go to every session, or the module cache at `web/document-session.mjs:2` (a `WeakMap` keyed by buffer identity) misses |
| `:617-628` | one highlighter; source and App header editors mounted on fixed ids | highlighter shared; editors per panel |
| `:629-631` | one `Notebook`, its `dispose` also disposes the shared highlighter | the workbench disposes the highlighter once |
| `:633-662` | URL params `notebook`, `new`, `example`, `publication` all target the one notebook | left slot keeps these; `right` targets the right slot |
| `:663-664` | `dataset.ready`; startup failure written to `#status` | ready after the left panel (and the right one if requested) initialised |

### 4.2 Other modules

| Where | Assumption | Change |
| --- | --- | --- |
| `web/edit.html:39-48`, `:96-126` | header grid holds the title (`:99`) and run actions (`:100`) | header one row; title and run actions move to the panel title bar |
| `web/edit.html:50`, `:128`, `:133` | status row at the top of `.shell`, footer at the bottom of the page | one status bar at the bottom of each panel |
| `web/edit.html:51` | `.cell { scroll-margin:110px }` compensates for the sticky page header | becomes the title bar height inside the panel scroller |
| `web/edit.html:67-68`, `:92` | compact rules are `@media(max-width:680px)` on the viewport | panel content rules become `@container panel (max-width:680px)`; header rules stay media queries |
| `web/edit.html:127-135` | one `<main class="shell">` with fixed ids | panel markup moves into a `<template>` (section 5.2) |
| `web/edit.html:161-169`, `web/package-dialog.mjs:2-33` | one package dialog; a second concurrent `loadPackageBundle` call overwrites `#package-load`'s `onclick` (`:29`), adds a second `change` listener, and the first call's `cleanup` closes the dialog under the second (whose `close` listener then rejects it as cancelled) | a page-level `PackagePrompts` coordinator (section 5.6) |
| `web/edit.html:191` | `edit-ui-conformance.html:5` and `m5-conformance.html:4` replace this exact startup script text | keep the line byte-identical |
| `web/edit-model.mjs:77` | `initialize` without an id opens the most recent draft | the right panel always passes an explicit id, `fresh`, or a record |
| `web/edit-model.mjs:307` | `recoveryCopy` keeps cell keys | copies made for a second panel regenerate keys (`makeCell` keys, `web/edit-model.mjs:7`) |
| `web/edit-store.mjs:131` | `versions` (the optimistic-concurrency token per draft) lives on the `DraftStore` instance | one instance per panel (section 5.4) |
| `web/packages.mjs:18` | a worker reads the persistent package cache once (`this.loaded ??=`), so it never sees an archive another worker verified and stored later, and prompts again | on a miss, reload the persistent cache once before fetching (section 5.6) |
| `web/build-cache.mjs:5` | `warm` is module state, i.e. per worker; compiler artifacts are imported only when a worker starts (`web/format-worker.mjs:18`) | no change; a second panel started later benefits, concurrent cold starts both miss (accepted, section 10) |
| `web/roc-highlighting.mjs:33-35` | one syntax worker per Roclet | stays one per page, shared by both panels |
| `web/editor-navigation.mjs:34` | page-motion height uses `innerHeight - 110` (the sticky header) | use the panel scroller's `clientHeight` minus the title bar |
| `web/edit-ui-conformance.mjs:13-16`, `tools/browser-*-probe.mjs` | `$('status')`, `$('run')`, `$('auto')`, `#notebook .value`, `document.querySelectorAll('.cell')` | unchanged: one-panel pages keep these ids on the primary panel |

## 5. Target design

### 5.1 Modules

- `web/notebook-panel.mjs` (new): `class NotebookPanel`. Owns one `Notebook`,
  its `DocumentSession`, its `DraftStore`, the `cards` map, `CellSelection`,
  source and App header editors, rendering (`renderCells`, `renderResults`,
  `renderSelection`, `renderObservation`), cell actions, the panel keyboard and
  clipboard handlers, and the title bar and status bar. Constructor:
  `new NotebookPanel({root, prefix, bytes, highlighter, store, packagePrompts, onActivate, onChange})`.
  Exposes `notebook`, `root`, `dispose()`, `focus()`, and command methods the
  header calls (`undo(redo)`, `download()`, `find()`, `openProjectFiles()`, ...).
- `web/workbench.mjs` (new): `class Workbench`. Owns the panel slots
  (`panels[0]`, optional `panels[1]`), the active panel, layout mode (single,
  columns, tabs), URL state, the same-notebook policy, the shared highlighter,
  the shared `PackagePrompts`, `document.title`, `beforeunload`, and the global
  keyboard handler. Pure helpers for Node tests: `parseLayout(url)`,
  `layoutUrl(url, ids)`, `openDecision(openIds, id)`.
- `web/edit.mjs`: keeps `startNotebook(drafts = new DraftStore())`, header menu
  and dialog wiring, and the URL bootstrapping. It creates the `Workbench`,
  routes every header command to `workbench.active`, and still **returns the
  left panel's `Notebook`** so existing tests keep working. A new export
  `workbench()` returns the instance for the dual contracts.
- `web/package-dialog.mjs`: gains `class PackagePrompts` (section 5.6);
  `loadPackageBundle` becomes its private dialog driver.
- `web/edit-store.mjs`: gains `fork()`, returning a new `DraftStore` on the
  same resolved database name (after `open()` has done the legacy-name lookup).

Two new files, so `tools/package.zig:75-135` gains `web/notebook-panel.mjs` and
`web/workbench.mjs` (offline asset list 98 → 100). Contract pages are not
packaged (`web/edit-ui-conformance.*` is not in the list today), so the new
`web/dual-conformance.*` is not either.

### 5.2 Markup and ids

The panel's markup (title bar, notice, diagnostics, App header, notebook and
source sections, status bar) moves into
`<template id="notebook-panel-template">`. The workbench clones it per panel.
Every element carries `data-part`; ids are assigned from a prefix: the primary
panel gets the **legacy ids unchanged** (`title`, `auto`, `run`, `stop`,
`status`, `save-status`, `selection-status`, `help`, `notice`,
`document-diagnostics`, `app-header`, `app-header-source`, `notebook`, `cells`,
`source-pane`, `source`), the right panel gets `right-` + the same names. Ids
are needed for `<label for>`, `aria-describedby` and the existing contracts and
probes; panel code never looks anything up by id. `#navigation-help` stays one
shared hidden paragraph. Result ids become `${prefix}result-${cell.key}`.

The workbench container is `<div class="workbench" data-panels="1|2"
data-layout="single|columns|tabs">`. Each panel root is
`<section class="notebook-panel" data-panel="left|right"
aria-label="Left notebook: <title>">` with `container: panel / inline-size`.
The body becomes a `100dvh` grid: header `auto`, workbench `1fr`. Inside a
panel: `.panel-scroll` (`overflow:auto`; holds the sticky title bar and the
existing `.shell` content, still `max-width:980px` centred) and `.status-bar`.

### 5.3 State ownership

| State | Owner | Shared? |
| --- | --- | --- |
| `Notebook` (state, history, result, timers, runId) | panel | no |
| `DocumentSession` and its notebook worker (one `Engine`, one baseline under plan 02, one workspace file set) | panel (`Notebook` constructor, `web/edit-model.mjs:67`) | no |
| `DraftStore` instance (`versions` tokens) | panel (`drafts.fork()`) | no; the IndexedDB database is shared |
| Compiled `WebAssembly.Module` | `prepareCompiler` cache, `web/document-session.mjs:2-10` | yes, keyed by the one `ArrayBuffer` |
| Compiler artifact cache and package archive cache (IndexedDB `roclet-build-cache`) | each worker reads and writes it | yes, by design; namespace is compiler digest + identity |
| Syntax highlighter worker | workbench | yes |
| Package prompt dialog | `PackagePrompts` | yes |
| Theme, engine-details preference | page (`localStorage`) | yes |

### 5.4 Same notebook in both panels: policy

Options considered:

1. **Allow two editable copies of one draft.** With a shared `DraftStore`
   instance both panels share one `versions` entry, so both saves pass the
   check at `web/edit-store.mjs:168` and the last writer silently wins. With
   separate instances the second panel's `initialize` refreshes its token
   (`get`, `:178`) and saves, so the *first* panel's next save fails with
   "Another tab changed this draft". Either way it loses edits or confuses the
   user. Rejected.
2. **Read-only mirror.** Needs a subscription from one `Notebook` to another
   (`edit-model.mjs` has none), doubles the CPU for identical revisions, and
   leaves undo and focus semantics unclear. Rejected.
3. **Refuse, and offer alternatives.** **Chosen.**

Policy: a draft id may be open in at most one panel. Every path that opens a
draft in a panel (URL `right=`, Recent select, the side-by-side dialog, home
links, closing the left panel) goes through `Workbench.open(slot, request)`,
which consults `openDecision(openIds, id)`. When the id is already open in the
other panel the panel keeps its document and shows a notice with two buttons:
**Go to it** (activates the other panel) and **Open an independent copy here**
(a new draft: new id, fresh cell keys, title `<title> (copy)`, same cells,
preamble, metadata and project files, saved as its own record). A URL with
`right` equal to `notebook` opens the left panel normally and the right panel
with that notice instead of a document.

Defence in depth: each panel uses its own `DraftStore` instance, so if the
check is ever bypassed the failure surfaces as the existing conflict message
and recovery-copy offer, never as a silent overwrite.

The copy path is also an engine check: the same source evaluated by two
engines must produce identical values (contract D2b).

### 5.5 Memory budget

- Instances per page: one per panel plus the shared highlighter, so three with
  two panels (two today). At most two notebook panels; more is a non-goal.
- Each panel shows its worker's `memoryBytes` (linear memory high-water mark;
  it never shrinks, `compiler-adapter/wasm.mjs:58-59`). Stop resets it because
  the worker is replaced.
- Bounds used by the contracts: each notebook worker ≤ 256 MiB for the
  fixtures (the bound `tests/workspace-benchmark.mjs:25` uses for warm Wall
  Area) and the sum of both ≤ 512 MiB. Plan 02 adds up to 64 MiB of retained
  presentations per engine (`retained_limit`), well above what the fixtures
  retain.
- A worker that cannot instantiate or grow memory fails only its panel
  ("Run failed: …"); the other panel keeps working. No automatic refusal to
  open a second panel on small devices (section 10).

### 5.6 Package prompts when both panels wait

`PackagePrompts.request({url, error, retry, signal})` is the `loadPackage`
callback every panel's `Notebook` receives (today `loadPackageBundle`,
`web/edit.mjs:629`).

- **Same URL, concurrent:** the second request joins the open prompt. The
  dialog shows "Needed by: <left title>, <right title>". One file selection
  resolves every joiner, each with its **own copy** of the bytes
  (`bytes.slice()`), because `DocumentSession` transfers the buffer to its
  worker (`web/document-session.mjs:87`), which detaches it.
- **Different URLs:** queued; one dialog at a time, first come first served.
- **Abort:** a joiner whose signal aborts (Stop, edit, document switch) leaves
  the group; the dialog stays open while any joiner remains and closes when
  none do. **Cancel** in the dialog rejects every joiner with `AbortError`, so
  each panel shows "Package loading cancelled · run to retry". One dialog is one
  decision.
- **Rejected bytes:** a worker that rejects the bytes asks again with
  `retry: true`; that starts a new prompt for that worker only.
- **Sequential case:** after panel A's worker verified and stored an archive,
  panel B's existing worker still holds its old snapshot (`web/packages.mjs:18`)
  and would prompt again. Fix in `BrowserPackages.install`: on a miss in the
  in-memory map, reload `this.cache.load()` once and retry the lookup before
  fetching. This is a JS fix; it also helps two browser tabs today.

The per-notebook execution timeout already pauses while that notebook waits
(`onPackageWaiting`, `web/edit-model.mjs:211`); joining or queueing keeps that
behaviour because each worker still sends its own `packageNeeded`.

### 5.7 Accessibility

- Each panel is a labelled region; the active panel's label ends ", active".
- Both status bars keep `role="status"`, but the inactive panel's status is
  `aria-live="off"` so background auto-runs do not interrupt; the tab (compact)
  or title bar shows the status dot visually.
- Tabs follow the ARIA tabs pattern (arrow keys move between the two tabs).
- Title inputs are labelled "Left notebook title" / "Right notebook title"
  (one panel: "Document title", as today, `web/edit.html:99`).
- Focus never moves between panels on its own; opening the side panel focuses
  its first cell; closing a panel focuses the remaining panel's selected cell.

## 6. Constraints and non-goals

- No new dependencies, no npm, no build step for JS; Chrome-supported CSS only
  (container queries, `dvh`).
- Single-panel behaviour and all 46 UI contracts (desktop and compact) keep
  passing; the probes in `tools/browser-*-probe.mjs` and
  `web/m5-conformance.html` keep working unmodified, because the primary panel
  keeps the legacy ids and the startup script line stays byte-identical.
- Offline packaging: `tools/package.zig` lists every new runtime file; the
  offline release must verify with the new count.
- Accessibility basics as in section 5.7.
- No engine changes. No protocol changes (no new request fields; plan 06 step F
  may pin the wire shape at any time).
- Non-goals: more than two panels, resizable split, synchronized scrolling,
  cross-panel drag and drop of cells (copy/paste between panels via the
  clipboard works already because the format is text, `web/edit-cells.mjs`),
  sharing one worker between panels, a home-page "open side by side" button.

## 7. Implementation steps

Each step leaves the tree green. Browser pages need an LLVM WASM build
(section 8.1); the engine does not change in this plan, so build it once after
rebasing onto plan 02 and iterate the JS against that artifact.

**Step 0: baseline.** Rebase onto `integration/code-checks` with plan 02
merged. Build the LLVM WASM, run the edit-ui contracts at both widths and
record the pass count (46). This is the regression baseline.

**Step 1: extract `NotebookPanel`, no visual change.** Move everything per
notebook from `web/edit.mjs` (section 4.1) into `web/notebook-panel.mjs`.
The panel root is the existing `<main class="shell">`; `part(name)` maps to
the existing ids for now. Split the keyboard handler into global and panel
halves; move `focusout` and clipboard listeners to the panel root. `edit.mjs`
creates one panel and routes header commands to it. Add the file to
`tools/package.zig`. Tests: `node --test tests/*.test.mjs`, edit-ui contracts
at both widths (46, unchanged), m5 contracts, `zig build package`.

**Step 2: template and prefixed ids.** Move the panel markup into
`<template id="notebook-panel-template">`; assign ids from the prefix
(legacy ids for the primary panel); prefix result ids. Still one panel and no
visual change. Tests as step 1, plus a contract that no id in the document is
duplicated.

**Step 3: title bar and status bar.** Title, Auto-run, Run all and Stop move
into the panel title bar; status, selection hint, save status and Keyboard
shortcuts into the bottom status bar; the header becomes one row; the panel
body becomes the scroll container; convert the panel compact rules to
`@container panel`; fix `scroll-margin` and `web/editor-navigation.mjs:34`;
add the engine-details preference. Tests: the 46 contracts at both widths, plus
new contracts U1–U3 (section 8.3), header and time probes.

**Step 4: shared services.** `PackagePrompts` and the `BrowserPackages`
persistent-cache recheck; `DraftStore.fork()`; panels receive the shared
highlighter, bytes and prompts from a `Workbench` that still has one slot.
New `tests/workbench.test.mjs` (section 8.2). Tests: Node suites,
edit-ui contracts, `tools/browser-package-load-probe.mjs` at both widths.

**Step 5: second panel.** `Workbench` with two slots, `right=` URL parsing and
writing, View → Open side by side… dialog, View → Close side panel and the ×
button, active panel tracking and the `For:` menu row, `document.title`,
`beforeunload` over both panels, the same-notebook policy. Columns layout only
(≥ 900px). Tests: Node suites, new `web/dual-conformance.html` contracts D1–D15
at 1280px.

**Step 6: compact tabs.** Tabs below 900px; status dots; ARIA tabs keyboard.
Tests: dual contracts at 390px (`?compact`) and 1000px (`?medium`), edit-ui
contracts at both widths.

**Step 7: real package flow and docs.** `tools/browser-dual-package-probe.mjs`
(section 8.4); update `docs/m2.md` (UI contract description and counts),
`docs/compiler-workspace.md` validation list, `README.md` if it describes the
editor layout, and this plan's row in `wip/README.md`.

## 8. Validation

### 8.1 Commands

Iteration (self-hosted backend, no browser):

```sh
zig build test -Dllvm=false
node --test tests/*.test.mjs
zig build check -Dllvm=false
```

Final pass (LLVM WASM; Node 22+ and a local Chrome):

```sh
zig build && zig build test && zig build package
node tools/browser-check.mjs --page web/edit-ui-conformance.html
node tools/browser-check.mjs --page 'web/edit-ui-conformance.html?compact'
node tools/browser-check.mjs --page web/dual-conformance.html
node tools/browser-check.mjs --page 'web/dual-conformance.html?medium'
node tools/browser-check.mjs --page 'web/dual-conformance.html?compact'
node tools/browser-check.mjs --page web/m5-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page 'web/edit.html?example=meeting-windows&right=example:meeting-windows' \
  --script tools/browser-dual-package-probe.mjs --upload-plan <plan.json>
node tools/browser-check.mjs --page 'web/edit.html?example=meeting-windows&right=example:meeting-windows' \
  --script tools/browser-dual-package-probe.mjs --upload-plan <plan.json> --viewport 390x960
```

### 8.2 Node tests (`tests/workbench.test.mjs`)

- `parseLayout`/`layoutUrl`: `notebook` + `right` (id, `new`, `example:x`),
  unknown examples rejected, one-panel URLs unchanged, round trip.
- `openDecision`: refuses an id open in the other slot, allows it in the same
  slot (no-op), allows any id after the other panel closed.
- `PackagePrompts` with an injected dialog driver: two concurrent requests for
  one URL show one prompt and both receive equal but distinct `Uint8Array`s;
  aborting one joiner keeps the prompt for the other; aborting all closes it;
  cancel rejects both with `AbortError`; two URLs are queued in order;
  `retry: true` opens a new prompt for that requester only.
- `BrowserPackages.install` with a fake cache whose contents change after the
  first `load()`: the second install finds the new archive without calling
  `fetch` or `loadBundle`.
- Two `Notebook`s with fake sessions: `stop()` on one never calls the other's
  `session.stop()`/`invalidate()`; each sends `reactivity.reset` only on its own
  document switch.

### 8.3 Browser contracts

New one-panel contracts in `web/edit-ui-conformance.mjs` (46 → 49, both widths):

- **U1** The title input is inside the panel's title bar, above the first cell
  (`title.getBoundingClientRect().bottom <= firstCell.top`), and the header
  contains no title input.
- **U2** The status bar's bottom equals the panel's bottom (±1px) before and
  after scrolling the panel body to its end; `#status` and `#save-status` are
  inside it; the page itself does not scroll (`scrollHeight <= innerHeight`).
- **U3** No duplicated element ids in the document.

New page `web/dual-conformance.html` + `web/dual-conformance.mjs`, built like
`web/edit-ui-conformance.html` (iframe with the startup script replaced; `?compact`
sets the iframe to 390px, `?medium` to 1000px, default 1280px). It uses its own
`DraftStore` name and deletes the database at the end. It wraps
`WebAssembly.compile` with a counter before `startNotebook`, opens two
documents through `workbench().open`, and locates everything through the panel
roots (`[data-panel=left]`, `[data-panel=right]`), never global ids. Fixture A
has `dbg` in cell 3 with message `111` and a passing `expect`; fixture B has
`dbg` in cell 1 with message `222` and a failing `expect`; both define
`Geometry.roc` project files with different contents.

- **D1 Layout.** Two panels; each has its own title bar at its top and status
  bar at its bottom; titles show each document's title; `document.title` names
  both; no horizontal page overflow; at 390px a tablist with two tabs is shown
  and exactly one panel is visible.
- **D2 Independent, concurrent evaluation.** `Promise.all([A.run(), B.run()])`;
  at one moment both `session.pending` are non-null; each panel's values equal
  the values recorded when that document ran alone in a fresh one-panel
  workbench. **D2b:** an independent copy of A in the right panel produces
  values identical to A's.
- **D3 Engine counters per panel.** With B's runs interleaved between them:
  A re-run without edits reports `prepared_hits == 1`, `analyses == 0`,
  `frontend_builds == 0`; a one-cell edit in A reports `analyses == 1` and
  `executions` equal to the number of changed roots.
- **D4 Reuse unaffected by the other panel.** Run A; edit and run B five times;
  edit an independent cell in A and run: A's unchanged roots have
  `reused == true`, the edited root `reused == false`, and A's value nodes for
  unchanged roots are the same DOM nodes. **D4b (after plan 03):** a comment
  edit in A reuses every root; adding `Point := { x : F64, y : F64 }` in B leaves
  A's `graph.scope` unchanged.
- **D5 Reset on document switch.** In the left panel switch from A to an
  independent copy of A (same source): the request carries
  `reactivity.reset == true`, the response has `plan.reused` empty and every
  value `reused == false`; the right panel's next run is unaffected (its reuse
  as in D4).
- **D6 Attribution.** After D2: left panel cell 3 shows `dbg: 111` and nowhere
  else; right panel cell 1 shows `dbg: 222` and nowhere else; the left tests
  block shows the pass, the right the failure; no event in either result has
  `cell == null`; the text `111` appears nowhere in the right panel and `222`
  nowhere in the left.
- **D7 Stop is per panel.** Start runs in both; Stop in A: A's status starts
  with "Stopped", A's worker object is replaced; B's worker object is the same
  object as before, B's run resolves with values, and B's status starts with
  "Current".
- **D8 Shared package prompt.** With `loadPackage` driven by a stub dialog
  driver that counts prompts and serves a valid bundle from the package fixture
  (`tools/package-fixture.zig`), both panels requiring the same URL produce one
  prompt and both resume; Stop in one while waiting leaves the prompt open for
  the other. The real file-picker flow is section 8.4.
- **D9 Compiler cache shared across workers.** After A's first completed run,
  open a document in the right panel: B's first response has
  `workspaceCache.hits >= 1` and `misses <=` A's first-response misses.
- **D10 One compilation.** The `WebAssembly.compile` counter is 1 after both
  panels and the highlighter have started, and still 1 after Stop in A and a
  re-run (worker restart shares the module).
- **D11 Memory.** Each panel's `transportMetrics.memoryBytes` is a positive
  number shown in its own status bar (engine details on); each ≤ 256 MiB, sum
  ≤ 512 MiB; `workspaceCache.image_retries == 0` on warm runs.
- **D12 Project files per panel.** `Geometry.area` evaluates to 15 in A and 24
  in B; editing A's `Geometry.roc` through the Project files dialog (opened from
  the left panel) changes only A's value.
- **D13 Focus and keyboard.** Escape in a left cell then ArrowDown moves the
  left selection only; Cmd+Z in the right panel undoes only the right panel's
  last edit; clicking the right panel makes it active and File → Download a copy
  names the right document; highlighting spans appear in both panels.
- **D14 Concurrent saves.** Edit both panels within the same debounce window:
  both save statuses reach "Saved in this browser"; both records in IndexedDB
  have the new sources.
- **D15 Same notebook policy.** Choosing the left document from the right
  panel's Recent list (and the URL `?notebook=A&right=A`) leaves the right panel
  unchanged with the notice; **Go to it** activates the left panel; **Open an
  independent copy here** opens a new id with fresh cell keys and title
  `<title> (copy)`; no save ever reports a conflict.
- **D16 Close.** Closing the right panel disposes its worker and returns to the
  one-panel layout with legacy ids intact; closing the left panel makes the left
  slot show the right document, whose first request carries `reset`.

### 8.4 Real package flow

`tools/browser-dual-package-probe.mjs`, modelled on
`tools/browser-package-load-probe.mjs`, on a static server with
`endpoint: null`: both panels open meeting-windows (the right one as an
independent copy); one dialog appears whose "Needed by" lists both; one
roc-time selection makes both panels show six current values and two passing
tests; IndexedDB holds one verified package entry; Stop and Run in either panel
restores it without a dialog. Desktop and 390px.

### 8.5 Manual checklist for the user

1. Open `web/edit.html?example=reactivity&right=example:weather`. Both
   notebooks evaluate; each title is at the top of its own column; each status
   bar is at the bottom of its own column.
2. Type in the left notebook; the right notebook's values and status never
   change. Then the reverse.
3. Turn on View → Show engine details. Edit one cell; the edited panel shows
   `1 evaluated` and the others `reused`; the other panel's numbers do not move.
4. Press Stop in one panel during a run; the other finishes.
5. From the right panel's Recent list choose the left notebook; you are offered
   Go to it / Open an independent copy here.
6. Narrow the window below 900px; tabs appear, and the hidden notebook still
   finishes running (its tab dot changes).
7. Close the right panel; the editor is back to one notebook and behaves as
   before. Reload a two-panel URL; both panels come back.
8. Open meeting-windows in both panels on a static host; one package dialog
   serves both.

## 9. Acceptance gates

- [ ] Plan 02 merged before this work; no request field added.
- [ ] `zig build test -Dllvm=false`, `node --test tests/*.test.mjs`,
      `zig build check -Dllvm=false` pass.
- [ ] Final LLVM pass: `zig build`, `zig build test`, `zig build package`
      pass; offline asset list = previous list + `web/notebook-panel.mjs` +
      `web/workbench.mjs` (98 → 100) and verifies.
- [ ] Edit UI contracts: 49 at desktop and 49 at compact (46 existing unchanged
      + U1–U3).
- [ ] Dual contracts D1–D16 pass at 1280px, 1000px and 390px (D4b only once
      plan 03 has landed; otherwise recorded as skipped).
- [ ] m5, workspace and document conformance pages pass unchanged.
- [ ] `tools/browser-package-load-probe.mjs` and the new dual package probe
      pass at desktop and compact widths.
- [ ] Existing probes and `web/m5-conformance.html` run without modification.
- [ ] One-panel URLs (`?notebook=`, `?new=1`, `?example=`, `?publication=`)
      behave as before.
- [ ] No engine source changed; any engine bug found is reported separately
      with a reproduction.
- [ ] Docs updated (section 7 step 7); this plan deleted.

## 10. Risks, open questions, deferred decisions

| Item | Recommended default | Notes |
| --- | --- | --- |
| Two workers on low-end devices | No automatic refusal; failure is per panel | Phones get tabs, but both workers stay alive. Revisit if a real device fails D11; an option is to suspend the hidden tab's auto-run. |
| Concurrent cold starts | Accept two misses | Workers import compiler artifacts only at start (`web/format-worker.mjs:18`), so two panels opened together both compile cold. Cross-worker sharing at runtime is out of scope. |
| CPU contention and the 15 s timeout | Keep per-notebook 15 s | Two heavy notebooks on two cores could time out one panel; the message already says automatic execution paused. |
| Shared vs per-panel undo | Per panel | Matches ownership; cross-panel undo has no clear meaning. |
| URL scheme | `?notebook=A&right=B`; kept in the URL while two panels are open | Alternative `?notebooks=A,B` rejected: it breaks existing links and has no slot names. |
| Header title in one-panel mode | None | The user asked for the title to move; `document.title` keeps the tab name. |
| Engine details default | Off, per-viewer preference | The user may prefer it on while validating; trivial to flip. |
| Tabs breakpoint | 900px viewport | Each column then has at least 450px; tune after screenshots. |
| Closing the left panel | Left slot adopts the right document; right undo history lost | Keeps legacy ids stable; alternative is swapping DOM and ids, which is fragile. |
| Scroll model change | Panel body scrolls, page does not | Existing contracts that rely on page scrolling would surface in step 3; none was found by grep (`scrollY`/`scrollTo` are unused in `web/`). |
| Package prompt cancel semantics | Cancel applies to all joiners | One dialog is one decision; each panel can Run to retry. |
| Engine bugs found | Report, do not work around | E.g. if D3 or D6 fails, that is an engine attribution/state bug, not a UI bug. |

Open questions for the user: whether engine details should be on by default;
whether tabs below 900px are acceptable or stacking is preferred; whether
closing the left panel should instead keep the right panel in place.

## 11. Cleanup

- Delete this file and its row in `wip/README.md` when step 7 lands.
- Remove any temporary diagnostics added during the work (counters in contract
  pages are part of the tests and stay).
- Record the final validation in `docs/compiler-workspace.md` (contract counts,
  dual contract widths, Chrome version, memory numbers from D11) in the same
  change.
