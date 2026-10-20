# Real browser package validation

Tested on 2026-10-20 (Australia/Melbourne) with Chrome 153.0.8010.52. The Roc
compiler pin is `7894793d1454103d47c4368c942b3fec1406e8fd`.

Direct GitHub release downloads fail browser CORS (`MissingAllowOriginHeader`).
The supported workflow uses a download proxy while retaining the original Roc
package URL and hash. Notebook compilation and evaluation stay in the browser.
The PR remains a draft; the hosted Pages deployment still needs a deployed HTTPS
proxy endpoint before its package examples can download dependencies.

## Download service

The bundled `roclet-serve` exposes `/api/packages/`. It accepts GitHub release
`.tar.zst` archives containing Roc content hashes, verifies BLAKE3 before caching,
limits redirects to GitHub asset hosts, bounds archive size and cache memory,
and applies a download deadline. The browser's compiler independently verifies
and unbundles the archive before persisting it under its original URL identity.

`web/package-config.json` selects the endpoint. The default works with the
bundled local server. A static host can select an external HTTPS endpoint; see
[deployment instructions](installation.md#package-downloads-on-a-static-host).
The configuration is loaded only when an uncached package needs downloading.

The real released roc-parser 2.0.0 archive and its transitive Unicode 4.2.0
archive passed Chrome tests through both the local endpoint and a separate
proxy origin. These tests use real GitHub downloads, without browser interception
or manually installed archives. The actual notebook verifies number parsing,
invalid input, editing, and worker restart.

```sh
zig build
./zig-out/bin/roclet-serve . 4179
```

In another terminal:

```sh
node tools/browser-check.mjs --base-url http://127.0.0.1:4179 \
  --page web/edit.html --script tools/browser-package-probe.mjs
```

The expected report is `result: "pass", passed: true`. This probe also attempts
a direct GitHub fetch to record the CORS restriction; its failure is expected.
A failed notebook run reports `result: "blocked"`, so inspect the report in addition
to the command's exit status.

## roc-time demonstration

[`demos/04-meeting-windows.roc`](../demos/04-meeting-windows.roc) imports the real
[roc-time 0.2.0 release](https://github.com/lukewilliamboswell/roc-time/releases/tag/0.2.0).
The notebook investigates the earliest 45-minute opening for a design review.
It shows the supplied calendar, normalizes offset-bearing bookings, merges
occupied coverage, subtracts it from the planning window, filters by meeting
length, and recommends a concrete slot. Each step displays its intermediate
result beside the algorithm.

Four bookings become three busy blocks. The free gaps are 09:00–10:00,
12:30–14:00, 14:30–15:00, and 16:00–17:00 UTC. The 30-minute gap is too short;
the first recommendation is **Book 15 Jun 2026, 09:00–09:45 UTC.** Increasing
the requested length to 90 minutes leaves only the 12:30–14:00 gap. At 120 minutes there is no opening.
Moving a booking outside the working day verifies clipping at the planning bounds.

The **App header** card starts collapsed. Expand it to edit the actual Roc app
declaration and imports in place, with normal highlighting, auto-run, undo,
autosave, and Ctrl/Cmd+Enter to run. The notebook retains the original released
package URL; there is no separate package declaration format.

All result tables use roc-time’s `EnglishGregorian.date` and `.clock` formatters,
for example `15 Jun 2026, 09:00`. Supplied offsets remain explicit in the input
table. Whole-minute clocks omit seconds; nonzero seconds and fractions remain
exact. Recommendations spanning midnight include both dates.

Two standalone `expect` assertions check the meeting-length rule against small
fixtures: a gap exactly 45 minutes long qualifies, and zero length is rejected.
They remain independent of the editable booking data and show pass/fail beside
their source. The probe deliberately breaks one expected value, verifies that
the failed test keeps all independent tables visible, then restores it.

```sh
node tools/browser-check.mjs --base-url http://127.0.0.1:4179 \
  --page 'web/edit.html?example=meeting-windows' \
  --script tools/browser-time-probe.mjs \
  --screenshot /tmp/roclet-time.png
```

The probe asserts the actual rendered table, edits, worker restart, and a fresh
worker with package networking disabled. That worker restores verified package
bytes and checked compiler artifacts from IndexedDB. Reports include the build
mode and actual WASM digest. Repeat with `--viewport 390x960` for compact layout.

To exercise the separate-host deployment pattern:

```sh
./zig-out/bin/roclet-serve . 4180 --proxy-only
node tools/browser-check.mjs \
  --package-endpoint http://127.0.0.1:4180/api/packages/ \
  --page 'web/edit.html?example=meeting-windows' \
  --script tools/browser-time-probe.mjs
```

The test driver serves the static site on a different ephemeral origin and
changes only its endpoint configuration. Archives still come from the actual
proxy service. No external HTTPS deployment is claimed by this local check.

## Verified browser results

After merging upstream main (`6819762`), the final ReleaseFast browser compiler
is 25,097,937 bytes, SHA-256
`cd92bdd279d304fecf80ed7cc6602923808a72fa5131df04fa521eb8fa1f2c7e`.
The local-endpoint test at 1280×960 and separate-origin proxy test at 390×960
both pass the complete roc-time probe: all six intermediate/final outputs,
booking edits, 90-minute and 120-minute requests, an off-hours booking,
readable offsets, exact fractional clocks, cross-midnight dates, reversed-date
errors, worker restart, and fresh-worker restoration with package
networking disabled. Both layouts have no page-level horizontal overflow, and
screenshots were inspected. Neither run records a failed network request.

The fresh worker restores the verified package archive and compiler artifacts
from IndexedDB and recomputes all six outputs. Cache counts depend on the bounded
cache and the preceding edits. The probe requires checked artifact hits and
recomputes all six outputs and both assertions using one frontend build and
one lowering (eight root executions). Missing compiler artifacts are rebuilt
without downloading the package again. Verified archives and compiler artifacts
have separate eviction budgets, each bounded to 32 MiB and 512 entries across
namespaces. Compiler-cache churn therefore cannot evict the source package.
This scenario exercises the actual IndexedDB cache after many notebook edits.

The header probe checks that a new notebook starts with the card collapsed,
then exercises expansion, source editing, a missing-module diagnostic, undo,
Ctrl+Enter, autosave, and source-view round trips while preserving every cell.
Run it with the same browser command and `--script tools/browser-header-probe.mjs`.
Both desktop and compact layouts pass. The existing Edit UI contracts also
pass all 46 contracts at both widths, alongside the lifecycle and rich-output
contracts. Document parity covers 226 complete native/WASM responses and 80
fresh-worker runs; all 146 native document contracts also pass.

Packaging verifies all 82 offline assets, including the demo and download
configuration. Result rendering uses reusable functions, avoiding Roc’s empirical
compile-time branch-coverage warning for a top-level match on the current value.
No diagnostics are suppressed. The probe verifies the warning is absent for both
valid and reversed dates, while still displaying the actual reversed-date error.

Upstream’s Edit menus, purple/light/dark themes, hummingbird branding, and pinned
Display package are retained. Existing `studio.html` bookmarks redirect to
`edit.html` with their query and fragment preserved. The exact pinned Display
package is provided by the embedded library during notebook execution, while
runnable Roc exports keep its content-addressed dependency. Other dependencies
continue through the normal package resolver.

## Compiler memory limit

The original 256 MiB retained-revision arena exhausted memory while lowering
roc-time and the larger typed CSV parser example. The adapter now reserves
512 MiB per retained revision. Both examples pass native ReleaseFast checks.
Earlier scheduling and typed CSV cases also passed Debug checks; the expanded
formatted notebook reports `OutOfMemory` with the Debug engine.
The current formatted notebook passes native and WASM ReleaseFast validation.
This is separate from the browser's package-download restriction.

```sh
./zig-out/bin/roclet run demos/04-meeting-windows.roc
./zig-out/bin/roclet run fixtures/documents/roc-parser-package.roc
```

The optional historical isolation probe remains available with
`?package-test=local-mirror`. It requires manually downloaded unchanged archives
in `artifacts/browser-packages/` and is not the production download path.
