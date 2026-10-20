# Roclet

**A reactive notebook for Roc, right in your browser.**

Change a value and watch the rest of your notebook update. Put the explanation
next to the code, add an equation, and share the result as a readable HTML report.
Roclet runs Roc locally through WebAssembly—and keeps working offline.

- **Reactive by default.** Cells follow their dependencies, not their position on the page.
- **Files you can read.** Save notebooks as Roc or Markdown. Export runnable Roc scripts.
- **Room to think.** A quiet editor with keyboard navigation, multiple cursors, and collapsible source.
- **More than plain text.** Markdown, math, tables, images, and inline `dbg` output.
- **Take your work with you.** Download a notebook, share a portable bundle, or export a self-contained report.

## Try it

**[Open Roclet](https://ageron.github.io/roclet/)** — no installation needed.

[Try the rich outputs demo](https://ageron.github.io/roclet/web/edit.html?example=rich-outputs),
change `width`, and see what happens. The [installation guide](docs/installation.md)
covers offline use and running locally.

Or explore the [little demos](demos/README.md): a reactive calculation, a tiny
weather dataset, and a mathematical notebook. Each takes just a few minutes.

In a code cell, definitions are shared across the notebook. The last expression
is the result to display:

```roc
radius = 3
pi = 3.141592653589793
pi * radius * radius
```

Press **Cmd/Ctrl+Enter** to run a cell. **Esc** selects the cell; **Enter** edits it.
With Auto-run enabled, changes update dependent results as you type.

Drafts are saved in your browser. **Download copies of work you want to keep**:
browser storage is separate from files on your computer.

## Early days

Roclet is an experimental alpha. **Only Chrome has been tested.** Other browsers
may work, but haven't been verified yet. Native builds have been tested on Linux x86_64 and macOS
with Apple Silicon.

Roclet uses a pinned development version of Roc. Widgets and plots are still
ahead of us. If something breaks, please open an issue
with a small notebook that reproduces it, your browser version, and what you expected.

## Build it yourself

You'll need Zig 0.17.0, Git, tar, and a checkout of the Roc compiler. There is no
Node.js or npm requirement.

```sh
sh tools/prepare-compiler.sh /path/to/roc
zig build
zig build serve
```

Open <http://127.0.0.1:4173/web/edit.html>.
The [installation guide](docs/installation.md) covers the compiler checkout,
offline use, downloads, and sharing. The [design](design.md) describes where
Roclet is heading.

Add supporting modules through **File → Project files**. Roc package declarations
use the notebook's normal app header. Browser builds cache compiler artifacts and
verified packages locally; warm edits reuse them without downloading dependencies
again. Portable Roclet bundles include your attached project sources.

## License

[Universal Permissive License 1.0](LICENSE), the same license as Roc.
Vendored dependencies retain their own [licenses](THIRD_PARTY_NOTICES.md).
