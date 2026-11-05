# Public package fetcher

A small Cloudflare Worker for automatic downloads of Roc packages that are not
in Roclet's static mirror. Notebook sources, compilation and execution stay in
the browser. This service receives only public package coordinates.

The default deployment is
`https://roclet-packages.roclet-package-fetcher.workers.dev/api/packages/`.
Its [health endpoint](https://roclet-packages.roclet-package-fetcher.workers.dev/health)
is public. It is configured in Roclet's checked-in download configuration.

## Behavior

`GET /api/packages/OWNER/REPO/TAG/ARCHIVE.tar.zst` downloads the corresponding
GitHub release asset. `HEAD` and CORS preflight are supported. `GET /health`
returns readiness without contacting GitHub.

The service checks the BLAKE3 hash encoded in the archive filename before
returning or caching any bytes. The browser independently checks that same hash
and validates/unpacks the archive. Arbitrary destinations, encoded path
separators, credentials, query parameters and redirects outside the approved
GitHub asset hosts are rejected. Browser authentication is never sent upstream.

Downloads have a 30-second deadline and a 32 MiB compressed-size limit,
enforced while reading even without a Content-Length header. A rate-limit
binding allows 60 uncached handler requests per client IP per minute per
Cloudflare location. Requests for the same content hash share an in-flight
download within an isolate; one cold download per isolate bounds memory.
Busy responses are retryable. These are resource/abuse limits, not global
billing caps or a guarantee against distributed abuse.

Verified archives use immutable HTTP caching, Workers Caching, and a Cache API
entry keyed by their content hash. Failed downloads are never cached. These
caches are disposable and may be evicted; there is no R2 bucket, KV namespace,
database, or durable package mirror in this step. Workers Caching still counts
requests toward the account's request allowance, including cache hits.

Roclet tries its static mirror first, then the configured service. If the public
service times out, has no remaining quota, or fails, Roclet tries the original
host and retains its manual file-loading fallback. Short busy responses, selected
temporary HTTP errors and network failures are retried up to twice with bounded
backoff and jitter, within the existing timeout. Short Retry-After delays are
honored; long quota waits fall through without repeated attempts. A one-minute
cooldown avoids repeating a slow failed service request for every transitive
dependency. A short busy response does not disable the service for the next
package. Missing packages and hash/encoding errors are not blindly retried.
Downloading packages pauses the notebook's execution timeout; stopping a run
still terminates its worker. The browser bounds each archive transport at 45
seconds, including fallback and response reading, so a stalled original host
cannot wait indefinitely while execution time is paused.

The editor reports the package name and version, bytes received, verification,
and retry delays. When Web Locks and shared browser storage are available,
workers in the same origin and compiler namespace coordinate downloads. A
waiting worker re-reads the verified archive after the owner finishes, then its
own compiler verifies and installs it. Closing/stopping an owner releases its
lock; stopping a waiter leaves the owner running. Restricted storage or missing
lock support retains ordinary verified downloads. No server storage is needed.

## Development and validation

Requires Node 22+ and npm, only for this service's tooling. The static Roclet
website still has no npm/runtime installation requirement.

```sh
cd services/package-fetcher
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run check
npm run dev
```

The unit tests use unchanged real package bytes and cover hashes, redirect
restrictions, CORS, cache behavior, deduplication, deadlines, size limits,
rate limits and failures. `npm run check` bundles the actual deployment without
publishing. `npm run dev` runs the Worker locally on port 8787.
The tests also boot the deployed entrypoint in workerd and check its health,
validation and preflight responses without making upstream requests.

From the repository root, exercise real GitHub downloads and the editor with
the static mirror explicitly disabled:

```sh
node tools/browser-check.mjs --without-package-mirror \
  --package-endpoint http://127.0.0.1:8787/api/packages/ \
  --page web/edit.html --script tools/browser-package-probe.mjs
```

The probe's direct GitHub fetch should fail CORS; the notebook must report
`result: "pass"` through the service. It exercises a transitive Unicode
dependency, parsed values, edits and a worker restart. Pass `--chrome PATH`
if Chrome is not named `google-chrome` on your system.

`tools/browser-public-fetcher-probe.mjs` separately tests a real package absent
from the mirror (roc-crc32 2.0.0), edits, worker restart, offline package reuse,
and readable CORS errors against the configured public endpoint. Run it with
`--page 'web/edit.html?new=1' --script tools/browser-public-fetcher-probe.mjs`.

## Deployment

```sh
cd services/package-fetcher
npx wrangler login --scopes account:read user:read workers:write workers_scripts:write workers_routes:write
npm test
npm run check
npm run deploy
```

Complete Cloudflare's browser authorization yourself. OAuth credentials are
stored by Wrangler outside the repository; never put tokens in package-config
or notebook source. On a fresh account, deployment may also require choosing a
workers.dev subdomain. The CLI prints the public HTTPS URL on success.

Use the Workers Free plan for a quota-limited deployment. This repository does
not upgrade the account, attach paid storage, or configure automatic top-ups.
The free plan's CPU limit also applies to cold-download hash verification;
large packages may exceed it and fall back to the existing manual flow.

After validating the deployed endpoint, put its full `/api/packages/` URL in
`web/package-config.json`, then run `zig build package` from the repository root.
Commit and publish the updated site through the normal verified Pages pipeline.
Changing the config on an already packaged site invalidates the offline
manifest, so always repackage. An endpoint of `null` disables the service.

Public responses permit uncredentialed CORS from any origin, so self-hosted
static Roclet copies may use the endpoint. There is no access token or account
requirement for notebook readers.

## Dependencies and references

Runtime hashing uses pinned `@noble/hashes` under MIT; its full notice is in
`NOBLE-HASHES-LICENSE.txt` and retained in the Worker bundle. Wrangler is a
development/deployment dependency. Both are pinned in `package-lock.json`.

- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Workers caching and request accounting](https://developers.cloudflare.com/workers/cache/)
- [Rate-limit bindings and their per-location accuracy](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Wrangler deployment](https://developers.cloudflare.com/workers/wrangler/commands/workers/#deploy)
