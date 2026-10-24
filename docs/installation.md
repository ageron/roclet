# Getting started with Roclet

Roclet is an experimental alpha. Only Chrome has been tested so far.

## Use a hosted copy

Open **[ageron.github.io/roclet](https://ageron.github.io/roclet/)** in Chrome. Nothing needs to be
installed: the compiler and editor run in your browser. The first visit downloads
the compiler, so give it a moment to load.

Choose a demo from the home page, or select **New notebook** to start an empty
notebook. Recent notebooks reopen your saved drafts. In the editor, use
**File → Rich Outputs and Widgets example** to try a first calculation, or **File → New notebook**
to start another. Change `width` and see its results update. Use the insertion buttons between
cells to add code or Markdown. Press Cmd+Enter on macOS or Ctrl+Enter elsewhere
to run a cell. Auto-run updates results after edits.

## Work offline

1. While connected, choose **File → Offline & storage → Prepare for offline use**.
2. Wait for **Ready offline**, then bookmark the current address.
3. Close Roclet and reopen that same bookmark. You can now edit and run offline.

Use the same browser profile and address: a different port, domain, or profile
has separate drafts. Browser storage can be cleared or evicted, so keep downloaded
copies of important work. When an update is prepared, close all Roclet tabs and
reopen to activate it.

## Run a downloaded release locally

When a release provides `roclet.zip`, extract it and open a terminal in the
extracted directory. The included server must match your operating system and
architecture; native builds have been tested on Linux x86_64 and macOS Apple Silicon.

```sh
./roclet-serve . 4173
```

Open <http://127.0.0.1:4173/web/edit.html>. Leave the terminal running while
using the app, or prepare offline use before stopping it. Don't double-click
`edit.html`: the interactive app needs HTTPS or a localhost server.

The browser files can also be served by another static web server. The bundled
native executable is platform-specific; the browser app is WebAssembly.

## Build from source

Install **Zig 0.17.0**, Git, and tar. Clone this Roclet repository, then obtain a
Roc compiler checkout:

```sh
git clone https://github.com/roc-lang/roc.git ../roc-compiler
sh tools/prepare-compiler.sh ../roc-compiler
zig build
zig build serve
```

Run these commands from the Roclet directory. The preparation command reads the exact Roc
commit from `compiler.lock.json` and prepares its own copy with the versioned
embedding API additions. The Zig build imports its exported compiler modules as
a path dependency; it doesn't modify your
compiler checkout. If the required commit is missing, run `git -C ../roc-compiler fetch origin`.
The first build needs network access for compiler dependencies, several GiB of
RAM, and time to compile. No separately installed Roc, Node.js, npm, or Python is required.

Open <http://127.0.0.1:4173/web/edit.html>. To choose another port:

```sh
zig build serve -- 4174
```

After the first build, `zig build` reuses Zig's build cache. Repeat the preparation
command when the compiler pin or embedding API patch changes. The default compiler
build mode is ReleaseFast. Browser compiler artifacts are cached separately in
IndexedDB and reused after worker restarts.

To test and package a release:

```sh
zig build test
zig build package
```

`zig build test` also runs `zig build check`: `zig fmt --check`, the tidy rules in
`ci/tidy.zig` (banned patterns, dead private declarations, Markdown titles), the
lints in `ci/zig_lints.zig`, and a dead-file scan over tracked Zig sources. Run
`zig build check` alone for a fast pre-commit pass.

For faster local iteration, `-Dllvm=false` builds the native and WASM adapters
with Zig's self-hosted backend, which takes seconds instead of minutes. Prepare
the compiler as above, then use `zig build test -Dllvm=false` or
`zig build serve -Dllvm=false`. These builds retain the default `ReleaseFast`
optimization mode, but the resulting adapters run several times slower. Release
artifacts, CI and performance measurements use the default LLVM backend.
The versioned embedding patch includes the WASM assembly metadata needed by
the self-hosted linker; no manual compiler edits are required.

The in-process compiler tests (`test-unit`, `test-engine`) embed the whole
compiler. An LLVM build of each needs about 13 GiB, so on x86_64 hosts they use
the self-hosted backend even in release builds; pass `-Dtest-llvm=true` to
build them with LLVM. Native/WASM parity always tests the shipped LLVM engines.

Browser checks run separately: open `/web/edit-ui-conformance.html`,
`/web/dual-conformance.html` (side-by-side notebooks; add `?medium` or
`?compact` for the 1000px and 390px layouts),
`/web/document-conformance.html`, `/web/m5-conformance.html`, and
`/web/math-conformance.html` on your local server. With Node.js 22+ and Chrome,
`node tools/test-browser.mjs` runs the core browser suites, including startup
and desktop and compact UI checks. `zig build test` publishes the compiler pair and generates
parity fixtures but does not launch Chrome. Packages are written to `zig-out/roclet.zip` and `zig-out/roclet-headless.zip`.

With Node.js 22+ and Chrome installed, run the browser-side unit tests and
individual pages from the command line, for example the startup (loading state,
startup errors, favicon and tab title) and notebook UI checks. Self-hosted
(`-Dllvm=false`) artifacts are several times slower, so give them a longer
`--timeout`:

```sh
node --test tests/*.test.mjs
node tools/browser-check.mjs --page web/startup-conformance.html --timeout 180000
node tools/browser-check.mjs --page web/edit-ui-conformance.html --timeout 180000
node tools/browser-check.mjs --page 'web/edit-ui-conformance.html?compact' --timeout 180000
```

## Save, open, and share

- **Browser autosave** keeps a local draft; it does not write to a downloaded file.
- **File → Download a copy** saves a Roc or Markdown notebook. Open it later with **File → Open**.
- **File → Export & share** creates a portable bundle, a static HTML report, or an interactive site.
  Reports open directly and include math fonts. Interactive sites need a static server.
- Bundles can include results, but imported results remain unverified until you run them.
- **File → Project files** adds ordinary Roc modules and text file imports beside
  the notebook. These sources are autosaved, undoable, and included in Roclet
  bundles; downloading a single `.roc` or `.md` file keeps those files separate.
- Expand **App header** above the notebook cells to edit package declarations
  and imports as ordinary Roc source. Header edits auto-run, autosave, and undo
  like cell edits. The card starts collapsed and remembers whether you left it expanded.
- Put `expect` assertions directly in code cells. Run all executes them; Run cell
  executes the selected cell's tests. The notebook shows passed/failed tests
  beside their source, and dependency edits rerun affected tests. Failed tests
  keep independent results visible. Tests in imported packages do not run.
- Declare packages in the notebook's app header using normal Roc dependency
  syntax. Roclet tries downloading directly. If the host blocks browser access
  or the download fails, a **Load package bundle** dialog links to the original
  archive. Download the `.tar.zst`, click **Load bundle…**, and select the file.
  Roc verifies its content hash before using or caching it, then resumes the
  notebook. An incorrect file can be retried; Cancel leaves the notebook editable.
  Additional dependencies may request their own bundle. Verified packages are
  cached locally for reuse without a network connection.

For example, attach `Shapes/Wall.roc` and import it with `import Shapes/Wall`.
A text attachment can be imported with
`import "data/message.txt" as message : Str`. Editing or removing either kind of
file invalidates the results that depend on the workspace.

The [demos](../demos/README.md) have **Open demo** links for the hosted app.
For local use, download the source file and open it in Roclet. The
[meeting-window demo](../demos/04-meeting-windows.roc) uses the released roc-time
0.2.0 package. Download and load its bundle when prompted on first use. With the
bundled server running, open
<http://127.0.0.1:4173/web/edit.html?example=meeting-windows>.

Roclet's native runner accepts notebooks too:

```sh
./zig-out/bin/roclet run demos/01-reactivity.roc
```

Downloaded `.roc` notebooks are ordinary runnable Roc programs, including the demos:

```sh
roc demos/01-reactivity.roc
roc demos/02-coding-puzzle.roc
```

Final cell expressions become named outputs, and a generated `main!` prints them
in notebook order. Downloads are checked first; fix reported errors before
exporting. Browser autosave still keeps unfinished drafts.

Rich-output notebooks import the content-addressed [Display package](../package/README.md).
Ordinary Roc downloads and caches it on first use; no adjacent `Display.roc` is
needed. Roclet includes this exact package's implementation in its native and
browser runtimes, so running notebooks in Roclet still works offline.

## Hosting on GitHub Pages

The public app is **https://ageron.github.io/roclet/**. **Roclet CI** builds and
checks pull requests and pushes to `main`: native tests, JavaScript tests, browser
conformance, and packaging all run in the same workflow. Its **Build, test, and
package** check should be required by the repository's `main` branch rule, with
pull requests and up-to-date branches required before merging. These repository
settings must be enabled by a maintainer; workflow files alone do not protect a
branch.

After a successful CI run on `main`, **Deploy Roclet** downloads that run's
`roclet-site` artifact and publishes it. Deployment does not rebuild the compiler
or rerun tests. Failed CI and superseded commits cannot replace the live site;
PR artifacts are never deployed. No execution server is needed.

CI installs the Zig version in `compiler.lock.json` and prepares the pinned Roc
compiler. Native and WASM engines have a separate cache keyed by their source,
dependencies, compiler build tools and `ci/engine-build.env` settings. A UI or
demo edit reuses these binaries; an engine input change builds a new pair. Native CI builds use
an explicit baseline x86-64 target so binaries work across hosted runner CPUs.

Zig's build cache is also restored for test executables and other tools, with
snapshots keyed by build inputs rather than every commit. Partial build caches
are saved even when tests fail. Every run still checks the current notebooks,
runs browser tests, and regenerates manifests, parity reports and site packages.
The `-Dcached-engines=.engine-cache` build option is for CI's exact-input cache;
normal local builds let Zig manage compilation as before.

The run summary includes native build/cache timings and durations for every
browser suite. Browser suites run two at a time with independent Chrome profiles
and servers; set `ROCLET_BROWSER_JOBS=1` for serial local troubleshooting.

The first cold build still takes longer. CI declares a 14 GiB memory estimate
per compiler build so Zig can schedule the native and WASM compile steps within
the runner's 16 GiB. Other build jobs remain parallel; local builds keep their
default scheduling.

To redeploy the current verified site without rebuilding, use **Actions → Deploy
Roclet → Run workflow** and supply the successful `main` CI run ID. In **Settings →
Pages**, the publishing source must be **GitHub Actions**.

For manual hosting elsewhere, `zig build package` creates
`zig-out/roclet-pages.zip`. Extract the archive and serve its contents over HTTPS,
preserving relative paths. It contains the compiler, demos, and offline assets.

### Package downloads on a static host

No application backend is required. The default
[`web/package-config.json`](../web/package-config.json) has `"endpoint": null`,
so package downloads go directly to their original URLs. Hosts that permit CORS
work automatically. GitHub release downloads do not permit browser CORS requests;
Roclet then offers a link to download the archive through the browser and a
**Load bundle…** file picker. The file is read locally and verified by Roc against
the hash in its original package URL before use or caching. A file picker is an
explicit user permission to read a local file and does not require host CORS.

Load each missing dependency when prompted. Later runs and worker restarts reuse
verified archives from browser storage. This flow works on GitHub Pages and
other completely static hosts, including when no proxy has been deployed.

### Optional automatic package proxy

To download GitHub release packages automatically, configure a proxy endpoint.
The bundled server already exposes `/api/packages/`; for local use, set
`"endpoint": "../api/packages/"` in `web/package-config.json`. For an external
service, run the same server behind HTTPS:

```sh
./roclet-serve . 4173 --proxy-only --bind 0.0.0.0
```

Put an HTTPS reverse proxy in front of that port and set `endpoint` to its public
URL, for example `"https://packages.example.org/api/packages/"`. Keep the trailing
slash. Configure the endpoint **before** running `zig build package`; repackage
after configuration changes so the offline manifest matches the published bytes.
GitHub Pages cannot run the proxy itself. Deploying this optional service is
outside this repository; manual bundle loading remains available if it fails.

The service accepts only GitHub `.tar.zst` release archives with Roc content
hashes. It validates redirect destinations and archive hashes, limits archives
to 32 MiB, allows four simultaneous requests, and applies a 30-second download
deadline. Its memory cache holds at most eight archives and 64 MiB. Public CORS
responses allow the browser app to use a separately hosted endpoint. Notebook
sources and compilation stay in the browser; only archive downloads use the
service. Browser cache identities retain the original package URLs.

Existing offline users can prepare the updated version through
**File → Offline & storage**, then close all Roclet tabs and reopen.
