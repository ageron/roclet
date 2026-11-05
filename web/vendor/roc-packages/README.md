# Static Roc package mirror

Unchanged, pinned release archives served from the same site as Roclet. The
manifest maps **exact original URLs** to local files; notebooks, exports, Roc's
content-hash checks, and browser cache identities keep using the original URLs.
Archives load on demand during normal use. Preparing Roclet for offline use also
caches the entire small collection through the verified offline release manifest.

## Selection

This is a curated collection, not a package registry or a popularity ranking.
Selected on 5 November 2026 from the [official Roc examples](https://www.roc-lang.org/examples/)
and the new-compiler section of [Awesome Roc](https://github.com/lukewilliamboswell/roc-awesome).
Pure libraries useful in notebooks take priority over native platforms and
services requiring filesystem, network, or operating-system effects.

| Package | Mirrored releases | Reason |
| --- | --- | --- |
| [roc-ascii](https://github.com/ageron/roc-ascii) | v0.5.1 | User-selected compatible fork; ASCII text processing |
| [roc-isodate](https://github.com/ageron/roc-isodate) | v0.8.4 | ISO 8601 dates, times, durations and date arithmetic |
| [Roclet Display](https://github.com/ageron/roclet-display) | 0.4.0 | All rich-output demos; also embedded in the notebook runtime |
| [Plume](https://github.com/lukewilliamboswell/plume) | 0.5.0 | Interactive chart demo |
| [roc-parser](https://github.com/lukewilliamboswell/roc-parser) | 2.0.0, 3.0.0, 4.0.0 | Official parser example, CSV demo, and current release; CSV, JSON, Markdown, YAML, XML and other text parsing |
| [roc-time](https://github.com/lukewilliamboswell/roc-time) | 0.2.0, 0.3.2 | Meeting scheduler demo and current release; date and time calculations |
| [Unicode](https://github.com/roc-lang/unicode) | 4.2.0, 4.3.0, 4.3.1 | Official examples, parser's transitive dependencies, and current release |
| [roc-random](https://github.com/kili-ilo/roc-random) | 0.9.2, 0.9.3 | Official example and current release; reproducible simulations |
| [path](https://github.com/roc-lang/path) | 4.0.0 | Official example; pure path manipulation |
| [roc-base64](https://github.com/niclas-ahden/roc-base64) | 1.0.2 | Byte and text conversions for attached data |
| [roc-graph-layout](https://github.com/lukewilliamboswell/roc-graph-layout) | 0.2.0 | Pure layout algorithms for graph visualization |

The collection contains 17 pinned archives (2,196,166 compressed bytes). Exact sizes, SHA-256
checksums, upstream release URLs, transitive dependencies, and license filenames
are recorded in `manifest.json`. Licenses are retained separately because some
release bundles contain only Roc source. Each license comes from its release tag.

Regular expressions are another useful candidate, but grayrest/roc-regex has no
published release archive at the time of selection.
Hasnep/roc-ascii v0.5.0 was also considered because it appears in the official
examples, but the pinned compiler rejects its `import Char exposing [Char]` as a
redundant exposure. The collection instead includes ageron/roc-ascii v0.5.1.
Native platforms such as
basic-cli and roc-ray are intentionally excluded: mirroring them would not make
their native capabilities available to browser notebooks.

## Maintenance

The **Check mirrored package releases** GitHub Actions workflow runs weekly and
can also be started manually. It compares each mirrored repository's latest
stable release with the existing pins and publishes a review report in the run
summary and artifact. It never changes imports or installs new archives. Run
`python3 tools/check-mirror-releases.py` for the same read-only report locally.
The 0.3.2 roc-time release was added after this check while the meeting demo
continues to use 0.2.0.

From the repository root:

```sh
python3 tools/mirror-packages.py --add https://github.com/OWNER/REPO/releases/download/VERSION/HASH.tar.zst
python3 tools/mirror-packages.py --check
zig build package
```

Importing recursively discovers package URLs in bundled Roc sources and imports
their archives too. Review the selection, licenses and source changes before
adding or updating pins. Existing URLs are never silently upgraded. The script
needs curl and tar with zstd support; regular builds need no network access to
package hosts and use the checked-in archives.

CI checks archive bytes and complete coverage of demo/transitive dependencies.
The Zig packager additionally verifies every archive against the BLAKE3 hash in
its original Roc URL before adding it to the site ZIP and offline release. The
browser's compiler independently verifies the package before installation and
persistent caching. WASM conformance exercises each additional library through
the production downloader while rejecting external package requests.

An absent mirror entry uses the configured proxy or original host as before. A
missing mirror manifest or failed archive request also falls through to that
transport, then to the existing manual file picker if necessary.
