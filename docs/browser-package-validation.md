# Real browser package validation

## Static production mirror

The current website includes `web/vendor/roc-packages/manifest.json`, pinned
unchanged archives, and their licenses. The production downloader tries exact
mirror matches before the configured proxy or original host; a failed mirror
request falls through to the existing transport and manual-loading fallback.
All bundled demos and their transitive dependencies are mirrored. See the
[collection and maintenance instructions](../web/vendor/roc-packages/README.md).

`python3 tools/mirror-packages.py --check` verifies archive checksums, dependency
closure, and demo coverage without network access. Packaging additionally checks
the original Roc BLAKE3 hashes and includes the files in both the site ZIP and
verified offline manifest. `web/package-mirror-conformance.html` exercises the
additional libraries in fresh WASM workers through the production downloader,
rejecting external package requests. The standard Chrome suites also exercise
the CSV, Plume and meeting-scheduler demos without a proxy or manual uploads.

The following sections record the earlier direct-download and proxy validation;
their manually supplied test archives predate the production mirror.
Use `--without-package-mirror` with `tools/browser-check.mjs` when specifically
testing the proxy or manual-upload fallback; otherwise mirrored packages succeed
before those transports are reached.
For the manual fallback, also pass `--package-endpoint none` to disable the
default public service without editing the checked-in configuration.

## Public automatic fetcher

The default endpoint is
`https://roclet-packages.roclet-package-fetcher.workers.dev/api/packages/`.
`tools/browser-public-fetcher-probe.mjs` uses roc-crc32 2.0.0, deliberately absent
from the mirror, through the production document worker and downloader. On
5 November 2026, the deployed HTTPS service passes the actual checksum, an edit,
worker restart, offline reuse from verified package storage, and reading a
validation error through CORS. No file upload is used. The downloader's progress
messages pause the execution timeout and leave Stop available.

```sh
node tools/browser-check.mjs --page 'web/edit.html?new=1' \
  --script tools/browser-public-fetcher-probe.mjs
```

This live-network check is intentionally separate from the network-free CI
browser suites. The Worker has its own unit and deployment-bundle checks in CI.

Tested on 2026-10-20 (Australia/Melbourne) with Chrome 153.0.8010.52. The Roc
compiler pin is `7894793d1454103d47c4368c942b3fec1406e8fd`.

Direct GitHub release downloads fail browser CORS (`MissingAllowOriginHeader`).
Downloads are direct by default. If downloading fails, Roclet offers the original
archive URL and a file picker for a user-downloaded `.tar.zst`. Roc verifies the
content hash and archive before using or caching those bytes, then resumes the
notebook. This supports GitHub Pages and other completely static hosts without
a backend. Notebook compilation and evaluation stay in the browser.

## Static file-picker fallback

Chrome at 1280×960 and 390×960 passes the actual file-picker flow with no proxy
configured and real released roc-time, roc-parser, and transitive Unicode bundles.
A malformed archive and a valid archive for the wrong package are both rejected
without entering IndexedDB. Loading the matching file resumes evaluation; missing
transitive dependencies prompt in turn. Cancel leaves the notebook editable and
Run retries. Fresh workers restore all three verified archives without another
file selection, including a worker with package networking explicitly disabled.
The desktop test waits 16 seconds before selecting a file,
confirming that the notebook execution timeout pauses during user interaction.

For manual QA, serve the site statically and open
`web/edit.html?example=meeting-windows`. Follow **Download bundle**, then
**Load bundle…**. Try an incorrect file before loading the released roc-time
bundle. The six outputs and two assertions should appear automatically.

`tools/browser-package-load-probe.mjs` automates this using Chrome's native file
picker through `tools/browser-check.mjs --upload-plan <plan.json>`. The plan is a
JSON array of five arrays of absolute file paths: a malformed archive, roc-time,
roc-time again (wrong package for the parser prompt), roc-parser 2.0.0, and Unicode
4.2.0. Run with `--page 'web/edit.html?example=meeting-windows'` and the probe as
`--script`; add `--viewport 390x960` for compact layout.

## Optional download service

The bundled `roclet-serve` exposes `/api/packages/`. It accepts GitHub release
`.tar.zst` archives containing Roc content hashes, verifies BLAKE3 before caching,
limits redirects to GitHub asset hosts, bounds archive size and cache memory,
and applies a download deadline. The browser's compiler independently verifies
and unbundles the archive before persisting it under its original URL identity.

`web/package-config.json` defaults to `"endpoint": null`. Set an endpoint to
opt into proxy downloads: `"../api/packages/"` with the bundled server, or an
external HTTPS URL. See [deployment instructions](installation.md#optional-automatic-package-proxy).
The configuration is loaded only when an uncached package needs downloading.

The real released roc-parser 2.0.0 archive and its transitive Unicode 4.2.0
archive passed Chrome tests through both the local endpoint and a separate
proxy origin. These tests use real GitHub downloads, without browser interception
or manually installed archives. The actual notebook verifies number parsing,
invalid input, editing, and worker restart.

```sh
zig build
./zig-out/bin/roclet-serve serve-static . 4179
```

In another terminal:

```sh
node tools/browser-check.mjs --package-endpoint http://127.0.0.1:4179/api/packages/ \
  --page web/edit.html --script tools/browser-package-probe.mjs
```

The expected report is `result: "pass", passed: true`. This probe also attempts
a direct GitHub fetch to record the CORS restriction; its failure is expected.
A failed notebook run reports `result: "blocked"`, so inspect the report in addition
to the command's exit status.

## roc-time demonstration

[`demos/06-meeting-windows.roc`](../demos/06-meeting-windows.roc) imports the real
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
node tools/browser-check.mjs --package-endpoint http://127.0.0.1:4179/api/packages/ \
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
./zig-out/bin/roclet-serve serve-static . 4180 --proxy-only
node tools/browser-check.mjs \
  --package-endpoint http://127.0.0.1:4180/api/packages/ \
  --page 'web/edit.html?example=meeting-windows' \
  --script tools/browser-time-probe.mjs
```

The test driver serves the static site on a different ephemeral origin and
changes only its endpoint configuration. Archives still come from the actual
proxy service. No external HTTPS deployment is claimed by this local check.

## Verified browser results

After merging upstream main (`6dab68c`), the final ReleaseFast browser compiler
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

Packaging verifies all 87 offline assets, including the demo and download
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
This record predates the change that keeps only the LIR image in a flat,
adaptively sized buffer and the rest of a revision in growable arenas; the
formatted notebook now also passes with the native Debug engine (see
`compiler-adapter/README.md`).

```sh
./zig-out/bin/roclet run demos/06-meeting-windows.roc
./zig-out/bin/roclet run fixtures/documents/roc-parser-package.roc
```

The optional historical isolation probe remains available with
`?package-test=local-mirror`. It requires manually downloaded unchanged archives
in `artifacts/browser-packages/` and is not the production download path.

## CSV attachments in the editor

The attachment probe runs the file-picker/drop handlers, previews, text/byte
imports, automatic replacement updates, duplicate protection, removal diagnostics,
path changes, undo, IndexedDB persistence, bundle import, and compiler restart.
Both desktop and compact versions are part of `node tools/test-browser.mjs` and
use local data without external packages.

For the café report with the real roc-parser release, place the unchanged
`7CLzCK6qUz7zmj6nvBxMEFu11HPwQTnCovKiyWzDSLTW.tar.zst` parser archive and
`4W8SHzvwet9hH9qZewJ1J1CVQoH7YKA6zyijWFTB3y1w.tar.zst` Unicode archive in
`artifacts/browser-packages/`, then run:

```sh
node tools/browser-check.mjs \
  --page 'web/edit.html?new=1&parser-demo=1' \
  --script tools/browser-attachments-probe.mjs \
  --viewport 390x960 --timeout 180000
```

The probe verifies the release archives through Roc's normal package path,
opens the published CSV demo with its attachment, checks typed rows and the
15420-cent total, and replaces the CSV through the editor to produce a
1000-cent total. This isolates compiler, attachment and package behavior using
local mirrors; it does not claim that public GitHub downloads pass browser CORS.
