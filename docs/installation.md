# Getting started with Roclet

Roclet is an experimental alpha. Only Chrome has been tested so far.

## Use a hosted copy

Open the Roclet address provided with the release in Chrome. Nothing needs to be
installed: the compiler and editor run in your browser. The first visit downloads
the compiler, so give it a moment to load.

There is no public demo URL configured in this repository yet.

Choose **File → Rich outputs example** for a first notebook. Change `width`, or
create your own with **File → New notebook**. Use the insertion buttons between
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
architecture; the current native build is tested on macOS Apple Silicon only.

```sh
./roclet-serve . 4173
```

Open <http://127.0.0.1:4173/web/studio.html>. Leave the terminal running while
using the app, or prepare offline use before stopping it. Don't double-click
`studio.html`: the interactive app needs HTTPS or a localhost server.

The browser files can also be served by another static web server. The bundled
native executable is platform-specific; the browser app is WebAssembly.

## Build from source

Install **Zig 0.17.0**, Git, and tar. Clone this Roclet repository, then obtain a
Roc compiler checkout:

```sh
git clone https://github.com/roc-lang/roc.git ../roc-compiler
zig build -Droc-source=../roc-compiler -Dcompiler-jobs=1
zig build serve
```

Run these commands from the Roclet directory. Its build reads the exact Roc
commit from `compiler.lock.json` and prepares its own copy; it doesn't modify your
compiler checkout. If the required commit is missing, run `git -C ../roc-compiler fetch origin`.
The first build needs network access for compiler dependencies, several GiB of
RAM, and time to compile. No separately installed Roc, Node.js, npm, or Python is required.

Open <http://127.0.0.1:4173/web/studio.html>. To choose another port:

```sh
zig build serve -- 4174
```

After the first build, `zig build` reuses verified compiler artifacts. Repeat the
command with `-Droc-source` when compiler-adapter inputs change.

To test and package a release:

```sh
zig build test
zig build package
```

Browser checks run separately: open `/web/studio-ui-conformance.html`,
`/web/document-conformance.html`, `/web/m5-conformance.html`, and
`/web/math-conformance.html` on your local server. `zig build test` does not launch Chrome.
Packages are written to `zig-out/roclet.zip` and `zig-out/roclet-headless.zip`.

## Save, open, and share

- **Browser autosave** keeps a local draft; it does not write to a downloaded file.
- **File → Download a copy** saves a Roc or Markdown notebook. Open it later with **File → Open**.
- **File → Export & share** creates a portable bundle, a static HTML report, or an interactive site.
  Reports open directly and include math fonts. Interactive sites need a static server.
- Bundles can include results, but imported results remain unverified until you run them.

The [demos](../demos/README.md) are ordinary notebook files. Download one using
GitHub's **Download raw file** button, then open it in Roclet.

Roclet's native runner accepts notebooks too:

```sh
./zig-out/bin/roclet run demos/01-reactivity.roc
```

To run an exported rich-output notebook with ordinary Roc, put
[`Display.roc`](../library/Display.roc) beside it. Roclet supplies this module
itself; Roclet bundles include it automatically.

## Hosting on GitHub Pages

Yes—Roclet is a static app, so GitHub Pages can host it. No execution server is
needed. A project site normally lives at `https://<owner>.github.io/<repository>/`.

Build with `zig build package`, then extract `zig-out/roclet.zip` into a clean
publishing directory. Publish the extracted contents, not the ZIP or the source
checkout: the compiled WASM is deliberately excluded from source control.
Keep the `web/`, `artifacts/`, `compiler-adapter/`, and other bundled directories
in their original relative positions. The native `roclet-serve` file can be
omitted from a hosted site.

Add an empty `.nojekyll` file to the publishing root. In the repository's
**Settings → Pages**, choose your publishing branch/folder, or upload that directory
with a Pages deployment workflow. Use HTTPS. The app address is
`https://<owner>.github.io/<repository>/web/studio.html`.

See GitHub's [Pages documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages).
Before announcing, test that address in a fresh Chrome profile: open a demo,
edit it, download it, and prepare/reopen offline. Deployment is a separate step;
these instructions do not publish anything.
