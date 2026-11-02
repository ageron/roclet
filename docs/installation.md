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

## Edit local files

In Chrome, choose **File → Open file** to edit a `.roc` or `.md` file directly.
**Save** (Cmd/Ctrl-S) writes back to that file after you grant write permission.
**Save as** (Shift-Cmd/Ctrl-S) chooses another file; new notebooks ask for a
location on their first save. Changing formats also asks for a new location.

Browser autosave still keeps a recovery draft. The status bar distinguishes
unsaved file changes from the browser draft's save status. If another editor
changes the file, Roclet refuses to overwrite it: reopen it or save your version
to another file. File connections last for the current page session; after a
reload, use **Open file** to reconnect. **Import a copy** and **Download a copy**
remain available, including in browsers without direct file access.

Roc files are saved as runnable apps, so resolve compilation errors before
saving them, or switch to Markdown to save unfinished work.

## Work with a local project

Build Roclet with `zig build`, then run:

```sh
./zig-out/bin/roclet serve                         # Current directory
./zig-out/bin/roclet serve ~/projects/my-project   # Another directory
./zig-out/bin/roclet serve ~/notes/example.roc     # Open a notebook
```

In a downloaded server distribution, use `./roclet` instead. Keep the
executable and web assets together. No Node.js or Python is needed.

The command opens your browser and listens on `127.0.0.1` by default. The home page
lists project notebooks; **File → Open file** selects another. **Save** writes
to the original file, and **Save as** chooses a relative path within the project.
New notebooks ask for a filename on their first save. Parent directories must
already exist. Starting with a file uses its parent directory as the project.

File associations survive reloads in local mode. Browser autosave remains a
recovery copy, including unsaved edits. Changes made by another editor are
checked when you return to Roclet; clean notebooks reload, while unsaved edits
are preserved and conflicting saves are refused. Files are replaced atomically.

Local modules and text imports are read from the notebook's directory and its
subdirectories before each compiler request. Edit those files with your usual
editor, then run the notebook again. Hidden files, symlinks, `node_modules`,
`zig-out`, and `zig-pkg` are excluded. The existing limit of 256 supporting text
files and 16 MiB applies; choose a focused project directory. The root
`Main.roc`/`main.roc` name remains reserved for the generated notebook module.

GitHub release packages download automatically through the local server and
are verified against their Roc hashes. With `HOME` set, they are cached in
`~/.cache/roclet/packages` for reuse across server restarts and offline sessions.
Compilation and execution still happen in browser WASM. The static website
continues to work independently without a server.

To allow access from another computer, use `--bind 0.0.0.0` (all IPv4 interfaces)
or bind a specific local IP address. For IPv6 use `--bind ::`. In the browser,
use the server's numeric IP and port, such as `http://192.168.1.10:4173/`.
Project access requires the private URL printed in the terminal, which includes
a fresh random token on each server start. The browser exchanges it for an HttpOnly
session cookie and removes the token from the address bar. Keep that URL private:
anyone with it can read and edit the project. After a restart, open the new URL.
HTTP does not encrypt the token or notebook traffic; use a trusted network or an
SSH tunnel when connecting remotely.
The default `127.0.0.1` keeps access on your computer.

`roclet serve-static /path/to/website --port 8080` serves website assets without
project file access. It also supports `--bind`; a bare `roclet demos` is no longer
a valid command. Run `roclet --help` for examples and options.

Use `--port 4174` to choose a different port or `--no-browser` to print the URL
without opening it. `--assets /path/to/roclet` selects a web distribution when
it is not next to the executable. Keep the same port to reuse browser recovery
storage. Stop the server with Ctrl-C.

## Attach data files

Choose **File → Attachments → Choose files…**, or drop files onto the attachment
dialog. Roclet copies each file into the notebook; it does not upload the data or
keep a live connection to the original file. Files initially use a path such as
`data/measurements.csv`. Select a file to preview it, download its original bytes,
or copy a Roc import:

```roc
import "data/measurements.csv" as csv_text : Str
```

`Str` imports require valid UTF-8. To read a binary file, or preserve any byte
sequence without text decoding, choose **Raw bytes · List(U8)**:

```roc
import "data/sample.bin" as sample_bytes : List(U8)
```

The attachment store preserves every byte, including line endings and byte-order
marks. CSV/JSON decoding is a separate Roc operation. The
[CSV demo](https://ageron.github.io/roclet/web/edit.html?example=csv-attachments)
uses roc-parser to decode column names and numeric types, handle quoted fields,
and report invalid data. Its first run may need the existing package-download
fallback; verified packages are cached for offline use.

**Replace file…** changes the saved copy while keeping its path, even when the
replacement has another filename. With Auto-run on, dependent calculations
update. **Remove** deletes the attachment and imports of it then report a missing
file. **Undo** restores replaced or removed files. **Update path** changes the
relative path; update the corresponding import in your code as well. Paths may
contain folders, spaces, and Unicode; absolute paths, `..`, duplicate paths,
and paths already used by project sources are rejected.

Undo history retains at most 64 MiB of distinct attachment contents, including
the current files; older undo entries are discarded when necessary. Reimporting
identical data shares its saved contents rather than retaining another copy.
Closing the attachment dialog cancels a pending disk read without changing the
notebook. The dialog can be reopened immediately, even if that read
has not finished.

Browser drafts retain attachments, including after reload. Each notebook supports
up to 128 attachments totaling 16 MiB. These are Roclet's current limits, not
general browser file-size limits. Previews show only the first 4 KiB of text or
256 binary bytes; truncation never changes the saved file.

Download a **Roclet bundle** to preserve the source and attachments together.
Bundles store original file bytes, relative paths, media types, and checked
content hashes. Import verifies them before opening an independent copy with
Auto-run off. Bundles are limited to 40 MiB, including project sources and any
selected result snapshots. Interactive sites also carry their notebook bundle.

A `.roc` or `.md` source save/download does **not** include attachment bytes.
To run source with ordinary Roc, provide the same files at the same relative
paths. Static reports show captured outputs; use a bundle for editable data.
Browser storage belongs to one origin/profile and can be cleared, so keep a
downloaded bundle for work you want to preserve.

## Work offline

1. While connected, choose **File → Offline & storage → Prepare for offline use**.
2. Wait for **Ready offline**, then bookmark the current address.
3. Close Roclet and reopen that same bookmark. You can now edit and run offline.

Use the same browser profile and address: a different port, domain, or profile
has separate drafts. Browser storage can be cleared or evicted, so keep downloaded
copies of important work. When an update is prepared, close all Roclet tabs and
reopen to activate it.

## Run a downloaded release locally

See the [server installation page](https://ageron.github.io/roclet/web/install.html)
for macOS, Windows, and Linux downloads and PATH setup. Extract the archive for
your computer, keep its files together, and run `./roclet serve` (`.\roclet.exe serve` in
PowerShell). Open the private token URL printed in the terminal; press Ctrl+C to stop the server.
No Roc or Zig installation is needed. This server distribution is separate from
the source-built headless runner described below.

## HTTPS with Caddy

Roclet supports HTTPS through a reverse proxy on the same computer:

```sh
roclet serve demos --public-url https://localhost:8443 --no-browser
```

In a second terminal, after installing [Caddy](https://caddyserver.com/docs/install):

```sh
caddy reverse-proxy --from localhost:8443 --to 127.0.0.1:4173
```

Open the HTTPS token URL printed by Roclet. Caddy may request administrator
permission to trust its local certificate. Keep both processes running.
`--public-url` accepts only an HTTPS origin, without a path, query, or fragment,
and requires Roclet to bind to `127.0.0.1` or `::1`. Caddy terminates TLS;
Roclet uses HTTP on loopback and secure cookies for browser authentication.
See the [installation page](https://ageron.github.io/roclet/web/install.html)
for public-domain and private-network setup, including certificate trust.

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

Display modules and their release URL are runtime assets, so updating them does
not rebuild either engine. `zig build adapter` regenerates `artifacts/display.json`
and its manifest using the cached engines. For a quick source-checkout preview,
`zig build display-assets` regenerates only that JSON file; run `zig build` before
packaging to refresh the manifest and offline assets as well.

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
[meeting-window demo](../demos/06-meeting-windows.roc) uses the released roc-time
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

Rich-output notebooks import the content-addressed [Display package](../vendor/roclet-display/README.md).
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
demo edit, Display release URL update, or Display module change reuses these binaries; an engine input change builds a new pair. Native CI builds use
an explicit baseline x86-64 target so binaries work across hosted runner CPUs.

Downloaded Zig dependency sources (`zig-pkg/`) have a separate exact-key cache,
limited to 1 GiB uncompressed before saving. Intermediate build outputs, the
prepared compiler checkout, and Zig's global cache are not persisted: restoring
an accumulated build cache can exhaust the runner's disk during extraction.
Tests and tools rebuild as needed and reuse Zig's cache within the job. Every
run still checks the current notebooks, runs browser tests, and regenerates
manifests, parity reports and site packages. Disk usage is logged at the start
and end of the job.
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
./roclet-serve serve-static . 4173 --proxy-only --bind 0.0.0.0
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

## Publish a server release

Run **Release Roclet server** from GitHub Actions on `main`, specifying a version
such as `0.1.0` and the run ID of a successful **Roclet CI** run for that exact
commit. The workflow reuses that run's tested browser site, builds and smoke-tests
the server on macOS (Apple Silicon and Intel), Linux (ARM64 and x64), and Windows
(x64), then publishes all archives and `SHA256SUMS` together under `server-vVERSION`.
It refuses a site from another commit or an unsuccessful CI run.
