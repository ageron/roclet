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
or manually installed archives. The actual Studio verifies number parsing,
invalid input, editing, and worker restart.

```sh
zig build -j1
./zig-out/bin/roclet-serve . 4179
```

In another terminal:

```sh
node tools/browser-check.mjs --base-url http://127.0.0.1:4179 \
  --page web/studio.html --script tools/browser-package-probe.mjs
```

The expected report is `result: "pass", passed: true`. This probe also attempts
a direct GitHub fetch to record the CORS restriction; its failure is expected.
A failed Studio run reports `result: "blocked"`, so inspect the report in addition
to the command's exit status.

## roc-time demonstration

[`demos/04-meeting-windows.roc`](../demos/04-meeting-windows.roc) imports the real
[roc-time 0.2.0 release](https://github.com/lukewilliamboswell/roc-time/releases/tag/0.2.0).
It normalizes offset-bearing bookings and subtracts their occupied coverage from
a working-day interval. The expected available UTC intervals are 09:00–10:00,
12:00–15:00, and 16:00–17:00. Editing the first booking's start removes the first
free slot and changes the count from `Ok(3)` to `Ok(2)`.

```sh
node tools/browser-check.mjs --base-url http://127.0.0.1:4179 \
  --page 'web/studio.html?example=meeting-windows' \
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
  --page 'web/studio.html?example=meeting-windows' \
  --script tools/browser-time-probe.mjs
```

The test driver serves the static site on a different ephemeral origin and
changes only its endpoint configuration. Archives still come from the actual
proxy service. No external HTTPS deployment is claimed by this local check.

## Compiler memory limit

The original 256 MiB retained-revision arena exhausted memory while lowering
roc-time and the larger typed CSV parser example. The adapter now reserves
512 MiB per retained revision. Both examples pass native Debug correctness
checks. This is separate from the browser's package-download restriction.

```sh
./zig-out/bin/roclet run demos/04-meeting-windows.roc
./zig-out/bin/roclet run fixtures/documents/roc-parser-package.roc
```

The optional historical isolation probe remains available with
`?package-test=local-mirror`. It requires manually downloaded unchanged archives
in `artifacts/browser-packages/` and is not the production download path.
