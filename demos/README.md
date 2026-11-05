# Little Roclet demos

Click **Open demo** to start an editable copy in [Roclet](https://ageron.github.io/roclet/).
Your changes stay in your browser; they don't modify the published example.

| Notebook | Try this | |
|---|---|---|
| [A result before its ingredients](01-reactivity.roc) | Change the number of guests, then move the cells around. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=reactivity) |
| [Coding puzzle: longest streak](02-coding-puzzle.roc) | Implement the stub and make every check pass; hints are included, but no solution. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=coding-puzzle) |
| [Rich Outputs and Widgets](03-rich-outputs.roc) | Explore Markdown, tables, images, and interactive widgets. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=rich-outputs) |
| [Plot a wave with Plume](04-plume-charts.roc) | Plot a sine wave, adjust its frequency with a slider, and hover or zoom. Uses Plume 0.5.0; load its release bundle when prompted on first use. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=plume-charts) |
| [A café sales report from CSV](05-csv-attachments.roc) | Decode typed rows with roc-parser and calculate revenue in exact cents. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=csv-attachments) |
| [Finding room for a design review](06-meeting-windows.roc) | Follow a calendar analysis: normalize offsets, merge overlaps, find gaps, and recommend a 45-minute meeting. Uses roc-time 0.2.0; download and load its bundle when prompted on first use. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=meeting-windows) |
| [A garden plan from a Gist](https://gist.github.com/lukewilliamboswell/ab17cb796239be901ec0436f919d39bb) | Keep the notebook small: use a relative Roc package, a private supporting module, and a text attachment from one Gist. Requires internet. | [Open demo](https://ageron.github.io/roclet/web/edit.html?example=gist-garden) |

For the bundled examples, you can also download any source file and open it
with **File → Open** in a local or offline Roclet installation, or run it directly with `roc notebook.roc`.
For the CSV example, keep `data/cafe-sales.csv` beside the notebook in its `data/`
directory, or open the web demo to get the notebook and attachment together.
Rich-output demos fetch the Display package automatically on the first ordinary
Roc run; Roclet already includes it for offline use.
The static website also mirrors all demo package dependencies, including
transitive packages, so the demos need no manual archive downloads. Preparing
Roclet for offline use includes these archives.

For Markdown, tables, HTML, images, and interactive widgets,
[open the Rich Outputs and Widgets demo](https://ageron.github.io/roclet/web/edit.html?example=rich-outputs).

The [CSV attachments demo](05-csv-attachments.roc) decodes typed rows with
roc-parser 3.0.0 and calculates revenue in exact cents.
[Open demo](https://ageron.github.io/roclet/web/edit.html?example=csv-attachments)
to get the notebook and its [sample data](data/cafe-sales.csv) together, then use
**File → Attachments** to replace the CSV.

These are small, editable examples, not screenshots. Keep experimenting, then
use **Download a copy** to save your version. [Installation and offline use](../docs/installation.md).

The **Gist garden** example opens a pinned revision of a public Gist and waits
for **Run**. Its notebook declares `garden: "./garden.roc"` and imports
`garden.Garden`. The package entry exposes `Garden`; its implementation uses
`Spacing` internally. This keeps the notebook focused on inputs and results.
The five [source files](https://gist.github.com/lukewilliamboswell/ab17cb796239be901ec0436f919d39bb/e18a658e1aab0e79a4467143ac714c5aedec3c55)
are loaded directly from GitHub; no copy is bundled with Roclet.
Gists have flat filenames, so the package entry is named `garden.roc` and its
modules live beside it. No archive download or package registry is needed.
