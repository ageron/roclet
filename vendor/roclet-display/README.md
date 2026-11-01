# Vendored Display package

The standalone package now lives in [ageron/roclet-display](https://github.com/ageron/roclet-display).
Its API documentation, source development, license, and release workflow belong
there. This directory retains a vendored copy of its four Roc modules because
Roclet packages the runtime modules as offline assets loaded by its native and
browser engines. Updating them does not require recompiling those engines. Building
Roclet does not require a sibling checkout or a package download.

The release pin is maintained separately in
[`dependencies/roclet-display-url.txt`](../../dependencies/roclet-display-url.txt):

https://github.com/ageron/roclet-display/releases/download/0.4.0/Gv78dUSQfYRU2yvV9HuS5oHYdMfik84S4sgsej6mbjLd.tar.zst

The vendored sources match the published Display 0.4.0 archive, including
`Display.plotly`.
Do not delete older release assets from `ageron/roclet`.

## Updating the embedded package

After publishing a Display release, download and extract its content-addressed
archive. In the Roclet checkout, run:

```sh
python3 tools/sync-display-package.py /path/to/extracted-package
python3 tools/update-package-pin.py --version 0.3.0 --archive HASH.tar.zst
zig build test-demos
zig build
```

The sync command copies only `main.roc`, `Display.roc`, `Input.roc`, and
`InputValues.roc`. Review the source and pin changes together before committing.
The pin updater targets the new `ageron/roclet-display` release repository.
Roclet CI checks the integrated package and notebook behavior; Display's own
repository tests and publishes the standalone package. Cross-repository pin
updates are explicit, rather than requiring a token with access to both repos.

For unreleased package development, the sync command also accepts the local
`../roclet-display` checkout (using its `package/` directory). Keep the published pin unchanged until release.

## Automatic update PRs

The **Update Display package** workflow checks the latest stable release daily.
Run it manually to update immediately, optionally specifying a version. It
imports the released modules and updates the runtime, demo, and test pins in a
reviewable PR; it never merges automatically. No cross-repository token is needed.

Enable **Settings → Actions → General → Allow GitHub Actions to create and
approve pull requests**. Bot-created PRs may require a maintainer to approve
workflow runs. The workflow and migration scripts must be on `main` before the
scheduled check can run. GitHub may disable scheduled workflows in inactive repos.
