# Roclet Display package

`Display.text`, `Display.markdown`, `Display.table`, and `Display.image` produce
rich output in Roclet and readable text when printed by ordinary Roc.

```roc
app [main!] { roclet: "https://github.com/ageron/roclet/releases/download/0.1.0/DgxFw9gRQuHiBsKhkuG4RxHPAyjMXLK6sujcMfnHijc7.tar.zst" }

import roclet.Display

main! = |_args| {
    value = Display.markdown("# Hello")
    echo!("${Str.inspect(value)}\n")
    Ok({})
}
```

Roc fetches and caches the package on first use. Roclet embeds the matching
implementation, so browser and native notebook execution work offline.
The initial `0.1.0` URL becomes available when the first release is published.

## Build and test locally

```sh
roc bundle package/main.roc --output-dir artifacts/display-package-test
zig build test-demos
```

The test builds the bundle, extracts it, compares the extracted sources, and runs
all five example notebooks against that extracted package with ordinary Roc.
No published release or network access is needed. Use `-Droc=/path/to/roc` to
choose the compiler. Generated archives stay in ignored build directories.

## Publish

1. Merge the package changes into `main`.
2. In GitHub Actions, choose **Release package → Run workflow**, select `main`,
   and enter a version such as `0.1.0`.
3. The workflow uses pinned Roc and Zig versions, tests the archive, then creates
   a versioned GitHub Release containing the content-addressed `.tar.zst`.
4. Merge the follow-up PR to update the package URL in Roclet and its demos.
   That push rebuilds the embedded runtime and deploys the website.

Pushes and pull requests only validate; they never publish. Package versions
use plain semver tags, independently of website deployments. Existing releases
are never overwritten. The first release may need no follow-up PR because its
URL is already prepared here.

Enable **Settings → Actions → General → Allow GitHub Actions to create and
approve pull requests** for automatic pin-update PRs. If PR creation fails after
publication, the release remains published: download the `display-release`
workflow artifact and apply `package-pin.patch` on the release commit, or run:

```sh
python3 tools/update-package-pin.py --version VERSION --archive HASH.tar.zst
```

Python is only used for release automation; running Roclet does not require it.
Do not commit generated archives or use a mutable `latest` URL in notebooks.
