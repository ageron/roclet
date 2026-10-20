# Roclet: design and implementation plan

Status: proposed design, with small compiler feasibility probes completed.  
Date: 2026-10-16.

Roclet is a reactive notebook environment for Roc. A **Roclet notebook** is a
readable document, an ordinary runnable Roc program, and an interactive browser
experience. Its source can be saved as Roc or Markdown, with seamless conversion
between them. Authoring and execution should work entirely offline in the browser.

This document records the decisions made in the initial design discussion,
proposes the remaining contracts, and sequences implementation. Names for APIs,
commands, metadata, and directories below are proposals, not existing features.

The agreed naming convention is:

| Name | Meaning |
| --- | --- |
| **Roclet** | The project and interactive notebook environment |
| **Roclet notebook** | A notebook document, saved as Roc or Markdown |
| **Roclet bundle** | A portable `.roclet.zip` containing a notebook and its supporting files |
| **Roclet report** | A static, readable export of a notebook |
| **`roclet`** | The CLI, including `roclet edit` and `roclet run` |

Use Roclet as the product name and descriptive nouns for its documents and
exports. For example: “Open this Roclet notebook in Roclet” or “Share a Roclet
bundle.” Within the app or when the context is clear, use the shorter “notebook”,
“bundle”, and “report”. “Runner” describes an execution component or headless mode.

## 1. Product principles

1. **Readable source first.** A typical code cell needs only `# %%`. No random
   IDs appear in source unless the user explicitly requests them.
2. **One document, two representations.** `.roc` and `.md` encode the same
   notebook. One source file is authoritative; conversion does not require
   keeping two files synchronized.
3. **Presentation order is independent of computation.** Moving a pure cell
   must not change its result. Definitions share one module-level scope.
4. **Current results come from current inputs.** Deleted definitions disappear;
   failures never silently reuse old values. Stale outputs are visibly stale.
5. **Local ownership.** No account, backend, or network is needed to use an
   installed Roclet with a fully downloaded Roclet notebook and its dependencies.
6. **Roc does the Roc work.** Reuse its parser, resolver, type checker, evaluator,
   and formatter. Do not approximate language semantics with regular expressions.
7. **Roclet itself should be substantially written in Roc.** Keep the document
   model, transformations, scheduling policy, and application state in Roc;
   use small host layers for compiler integration and browser facilities.
8. **Effects are explicit.** Automatic recomputation must not repeat arbitrary
   network requests, writes, or other external actions.

## 2. Scope and success criteria

The first useful release supports pure computation, Markdown prose, anonymous
expression cells, Roc/Markdown conversion, plain-text output, basic inspection,
reactive reevaluation, inline `dbg` messages, cancellation, local saving, offline
reopening, and CLI execution. A complete compiler/runtime dependency set is
downloaded with it.

It can initially reevaluate the complete pure notebook after a code edit.
Selective recomputation is the next execution milestone, not a reason to ship
incorrect dependency handling in the first prototype.

The first release does not require multiplayer editing, a package marketplace,
GPU execution, SQL, rich dashboards, arbitrary effects, or AI. The architecture
must leave room for them without embedding their state in every source file.

The acceptance journey is:

1. Open Roclet, create a notebook, and enter an expression before its definitions.
2. Edit an input; see updated outputs and useful diagnostics.
3. Move cells without changing computed values.
4. Switch between Roc and Markdown, preserving meaning and annotations.
5. Save Roc, run it using a compatible ordinary Roc compiler, and obtain the
   same values as the browser for the same effective inputs.
6. Prepare for offline use, disconnect, close and reopen Roclet, then edit and run.
7. Export a bundle, import it in another browser, and reproduce the notebook.

The native compiler and browser compiler must have a tested compatibility pair.
Matching language version labels alone are not enough.

### 2.1 User journey: access, create, save, open, and share

This is the proposed product experience, not functionality already implemented.
The default path requires no account: visit Roclet, create a notebook, edit it,
and keep a local copy. Saving and publishing are separate actions.

#### Access Roclet

The project website offers **Open Roclet**, which opens the browser application.
Choose the public domain before launch; no particular domain is assumed here.
The initial load downloads the editor and compatible compiler/runtime, showing
progress. Subsequent visits reuse the installed assets. Notebook code and data
are processed locally in the default mode; merely opening Roclet does not upload
documents to a service.

The home screen has **New notebook**, **Open**, recent documents, and optional example
templates. Users can install Roclet as a browser app where supported, gaining an
application icon. **Prepare for offline use** verifies that Roclet and the chosen
notebook's dependencies are present before displaying **Ready offline**. Installing
the app icon alone is not proof that every notebook dependency is available.

For developers, `roclet edit path/to/analysis.roc` can open the same Roclet app against
a local workspace through the CLI host. This is an optional path for ordinary
filesystem/Git workflows, not a prerequisite for using the public browser app.
Self-hosted Roclet and an offline distribution use the same application.

#### Create a Roclet notebook

**New notebook** opens an untitled document with an editable code cell. A user can
type `1 + 1`, see its result, add prose or code, and rename the document without
first choosing a directory, format, account, or runtime. Templates can offer
prewritten starting points without changing this flow.

The document immediately gets a recovery copy in this browser's local library.
Show **Saving in this browser...** until persistence succeeds, then **Saved in this
browser**. A draft is not published or synchronized to another device. Title and
save destination remain visible from the editor.

#### Save and choose a backing file

Browser recovery autosave is always available when storage is writable. File
saving is an explicit additional choice, with optional file autosave after the
user has selected a destination. Source-only saving remains the default.

| User action | Result and visible status |
| --- | --- |
| Keep editing a new browser document | Local library is authoritative; **Saved in this browser** |
| Save to a selected writable file | Choose `.roc` or `.md`; successful writes show **Saved to analysis.roc** or the actual filename |
| Edit a file-backed document without saving the file yet | Recovery copy is updated; **Changes not saved to file** remains visible |
| Download a source copy | A separate `.roc` or `.md` file is downloaded; the browser document remains the active copy |
| Download a portable bundle | Source, assets, modules, and chosen metadata/results are packaged together |

Use **Save As** to change a real backing destination or source representation.
Use **Download a copy** when the browser cannot write back to the selected file;
do not imply that a download updated the original. Direct save-to-file support
varies by browser, so file import/download is the baseline everywhere.
[Browser save-file API availability](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker).

The first file save offers Roc or Markdown, plus **Include output snapshots**.
Remember the selected representation. Source-view switching does not silently
change the backing file format. If attachments or relative modules are required,
offer to save a project folder where supported or download a bundle; a lone
source file must not be presented as containing missing dependencies.

Browser storage can be cleared or evicted and is specific to the browser profile
and Roclet origin. Make backup/export easy and describe the local library as
**In this browser**, not as a cloud drive. Moving to another origin, device, or
profile requires importing a copy or a future explicit synchronization feature.
[Browser persistence constraints](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria).

#### Open an existing Roclet notebook

Users can select a recent local document, choose **Open** for `.roc`, `.md`, or
`.roclet.zip`, or drag files into Roclet. A normal file upload opens a browser
copy; a supported writable-file connection opens a file-backed document. State
that distinction in the save status. A recent file whose permission has expired
can be reselected; recover unsaved local edits before replacing them.

Bundles restore their source, assets, and selected metadata. If a standalone
source references missing files, offer file/folder import or bundle import; do
not assume that choosing one file grants access to its neighboring files. Show
saved outputs promptly as unverified snapshots and load the compatible compiler
before recomputing. Unknown external actions never run just because a file opened.

Published links open a reader/app view. **Edit a copy** creates the recipient's
own local notebook with its source and available attachments, without modifying the
author's publication. Later URL import can support documented public sources;
do not promise that any arbitrary or private web URL can be fetched by the browser.

#### Share a Roclet notebook

Offer sharing choices by what the recipient should be able to do:

| Share choice | What the author sends | Recipient experience |
| --- | --- | --- |
| **Editable file** | `.roc` or `.md`, when source alone is sufficient | Open it in Roclet, or use ordinary source tools |
| **Editable bundle** | `.roclet.zip` with dependencies/assets and selected outputs/comments | Import into a compatible Roclet installation, edit, and run; works offline once Roclet/runtime and all required dependencies are prepared |
| **Report** | HTML or Markdown plus required images and saved outputs | Read without installing Roc or running code |
| **Interactive link** | A published version hosted at a public or access-controlled destination | Open in a browser, run supported interactions locally, optionally edit a copy |

The sharing dialog previews the included source, data attachments, outputs, and
annotations. Defaults match the chosen purpose; including debug transcripts and
discussions remains explicit. A bundle normally packages the notebook rather
than another full copy of Roclet. A full offline distribution is available when
the recipient has not already installed the needed application/compiler.

A local browser document has no shareable public URL merely because Roclet has
a URL. The initial release supports sending files/bundles and exporting static
or interactive sites for self-hosting. A later **Publish and copy link** integration
uploads a chosen version to a hosting destination or sharing service. Computation
can remain browser-local even though publication requires online file storage.
An integrated provider may require an account; local authoring does not.

Publishing creates a versioned snapshot. Later local edits do not change the
shared version until **Update publication**. Show published status independently
from save status, for example **Published version 3; unpublished changes**.
Private sharing requires access control at the hosting destination; hiding code
in an app view is only a presentation choice. Real-time coediting is a later,
separate **Invite collaborators** feature.

#### Example end to end

A user visits Roclet, clicks **New notebook**, names it *Wall area*, and writes the
three-cell example. It autosaves in their browser. They save `wall-area.md` with
output snapshots, then add a CSV attachment and use **Share -> Editable bundle**.
The recipient imports that bundle into Roclet and edits their own copy. Later,
the author publishes an interactive version for readers and explicitly updates
that publication when a new version is ready.

The editor should make four questions easy to answer at all times: where the
current work is saved, whether the backing file is current, whether it is ready
offline, and which version (if any) has been shared.

## 3. What has already been verified

These observations are from local artifacts, not promises about every Roc release.

| Probe | Result | Implication |
| --- | --- | --- |
| Runnable Roc file with forward references and `out_*` bindings | Local native compiler printed both values as `15.0`. | The simple source representation is viable. |
| Sequential WASM REPL input `a = b + 3`, then `b = 5` | First definition failed because `b` was not in scope. | Do not implement notebook semantics by submitting cells in display order. |
| Same WASM REPL with all definitions in one virtual module, then querying exports | Both outputs returned `15.0`, with type `Dec`. | Whole-module evaluation is a useful restricted prototype route. |
| Whole-program browser compiler with three cells in all six permutations | All permutations produced the same two values using `echo!`. | Whole-program browser evaluation supports this forward-reference example. |
| `dbg` in that whole-program browser artifact | Successful run, but neither output callback was invoked. The echo platform's WASM debug callback is a no-op in the inspected source. | Wire debug observations into the host; this is a host limitation, not a restriction on Roclet's support for `dbg`. |

The WASM REPL currently exposes structured diagnostic envelopes, inspected value
strings, type strings, and runtime events. This is not a recursive typed-value
inspection API. Its advertised capabilities exclude filesystem, network, and
platform effects. Its revision counter is scoped to a WASM instance.

The whole-program browser artifact captures output streams but does not itself
provide the per-cell result and dependency contract Roclet needs. The virtual
module experiment covers simple definitions only: moving arbitrary Roc source
inside a nominal module body is not established as semantics-preserving.

Milestone 0 must choose and version a supported compiler adapter rather than
implicitly depend on whichever local binary happens to exist. See section 19
for evidence and exact artifacts.

## 4. Roc source format

### 4.1 Complete example

```roc
app [main!] {}

# %%
# # Wall area
# Change the dimensions to update both results.

# %%
out_1 = area # => 15.0

# %%
width = 5
height = 3

# %%
area = width * height
out_dimensions = area # => 15.0

# %% generated
display! = |value| echo!("${Str.inspect(value)}\n")

main! = |_args| {
    display!(out_1)
    display!(out_dimensions)
    Ok({})
}
```

This has three editable code cells, one Markdown cell, and one generated entry
point. The application header is document configuration, not an ordinary cell.
The empty header keeps this example small; real new notebooks should record the
tested compiler selection and any necessary package/platform configuration.

`dbg` is a first-class notebook feature: its messages appear directly beneath
the cell being evaluated, without opening developer tools. The existing WASM
REPL already reports structured debug events; the whole-program echo host needs
its missing debug hookup implemented. See section 10.1 for the display contract.

The generated CLI entry point calls a shared `display!` helper, which uses `echo!`
with `Str.inspect` to print designated cell results. User-written debug
observations are a separate stream from those
results. This distinction prevents generated result printing from appearing twice
in notebook view. Rich output later uses an explicit renderer protocol. Exact
decimal formatting, debug prefixes, and terminal formatting are separate from
value equivalence.

### 4.2 Delimiters and optional attributes

- Read both `#%%` and `# %%`; emit `# %%` when creating new delimiters.
- A delimiter is a standalone, column-zero Roc comment at a top-level boundary.
  A similar string inside code, a literal, or Markdown content is not a boundary.
- With no explicit cell kind, infer Markdown if the body contains at least one
  comment line and otherwise only comments and blank lines. Any code token makes
  it a code cell, including incomplete or invalid code. A completely empty cell
  defaults to code.
- `code` and `markdown` explicitly select the kind when needed; `generated`
  identifies the entry point owned by Roclet. Kind inference also applies to
  delimiters carrying other attributes, such as `id=...`, without a kind.
- Optional attributes include `id=...` and later execution/presentation settings.
  Simple notebooks do not need them.
- Preserve unknown metadata during conversion. Unknown metadata that may affect
  execution requires a compatibility diagnostic, not silent omission.
- An optional document marker such as `# roclet:format=1` is available. Absence
  means the version-1 minimal syntax; incompatible extensions require a version.
- Imports, types, annotations, and definitions retain their order within cells.
  The importer identifies the required application preamble using Roc syntax.

Use compiler tokenization and parsed source spans to recognize boundaries and
trailing expressions. An incomplete draft must still be editable and recoverable;
never discard text just because it cannot currently be parsed.

Infer the kind from lexical content, not whether the text looks like prose or
valid Roc. Comments containing commented-out Roc are therefore Markdown unless
the author selects code explicitly:

```roc
# %% code
# width = 5
# height = 3
```

Comments alongside an actual definition stay ordinary code comments. Reserved
metadata and attached output-snapshot comments are recognized before inference;
an orphaned snapshot is preserved and diagnosed rather than silently becoming
prose. Documentation comments in a comment-only cell follow the same rule; use
`code` to preserve them as code documentation instead of rendered Markdown.

Infer kinds when importing or reparsing raw source, but keep the selected kind
stable while editing a cell in notebook view. Commenting out its last definition
must not unexpectedly switch editors. On save, emit `# %% code` if preserving
that code cell now requires an override. Emit an explicit `markdown` marker for
an empty Markdown cell if its kind would otherwise be lost. Normal prose cells
need only `# %%`; explicit existing overrides survive no-op saves and conversion.

### 4.3 Outputs and anonymous expressions

A code cell has zero or one top-level binding whose name begins with `out_`.
That binding is its displayed output. The prefix is reserved for this purpose in
Roclet notebooks; local bindings and record fields do not select outputs.
Output names must be unique in the notebook's module scope, like other bindings.
Bare `out` remains an ordinary definition.

The notebook editor can present:

```roc
# %% id=area
width = 5
height = 3
width * height
```

and save:

```roc
# %%
width = 5
height = 3
out_area = width * height
```

Only the final expression is lowered into a binding. Earlier definitions stay
at module scope. If the expression itself is a block, its local scope stays local.
Do not wrap a complete cell in a block, which would hide its definitions.

The convention is reversible: in notebook view, a canonical `out_* = expr`
definition may be displayed as `expr`, with its output name visible in cell
properties. Raw-source view always shows the real binding. This behavior applies
equally to hand-authored and generated `out_*` bindings, avoiding an invisible
distinction that would otherwise need extra provenance metadata.

For a new anonymous output, use the first available name in the sequence
`out_1`, `out_2`, `out_3`, and so on, skipping names already in use. An explicit `id=sum` instead prefers
`out_sum` when the ID contains only ASCII letters, digits, or underscores.
If that binding is already taken, append a numeric suffix and retain `id=sum`.
Other explicit IDs are reserved before choosing anonymous output names, so cell
order does not let an anonymous result take a later cell's requested name.
IDs containing other characters keep their attribute and use an anonymous name.
Canonical exports omit the ID attribute only when the selected output binding
implies exactly the same ID; preserve other attributes. Editing views retain
explicit IDs, and no-op saves preserve the original text.

Keep a materialized output name after edits and moves. Do not rename
it just because its expression changes. Renaming uses symbol-aware refactoring
because other cells may reference the binding.

Multiple `out_*` definitions, or an output binding plus a second trailing
expression, produce a clear format diagnostic. Users can combine results in a
record or split the cell. Non-final standalone value expressions are unsupported
in the initial pure format; offer an explicit binding or a separate cell.
Explicit `dbg` statements are supported independently of the one-output rule,
including in a cell with no designated result. Top-level tests, debug statements,
and function definitions are not anonymous display expressions.

### 4.4 Generated entry point

Roclet owns only a section explicitly marked `generated`. It renders selected
outputs in presentation order; this does not impose computation order on their
pure dependencies. A notebook without outputs still gets a valid entry point.
When outputs exist, the generated section defines
`display! = |value| echo!("${Str.inspect(value)}\n")`; `main!` calls it once per
selected output. The helper works across output types and supplies the script's
plain-text representation. It is omitted when no outputs are selected. If user
definitions already use `display` or `display!`, choose the first free helper name
`display_2!`, `display_3!`, and so on, considering both cells and the preamble.
Generated definitions do not reserve names on reopening, so repeated saves keep
the helper name stable.

The entry point is protected and initially collapsed in notebook view, inspectable
in raw-source view, and available in Roc export. Its generated calls are not
included in the reactive dependency graph as user computations.

Before regenerating an imported entry point, validate that it has the supported
generated structure, including the helper body and calls. If it contains unexpected
external edits, retain the text and report a conflict. Never replace an arbitrary
user-written `main!`. Offer an
explicit conversion to a managed entry point, or preserve the document in source
mode until the conflict is resolved. Unrecognized code is never executed merely
because a comment says `generated`.

Normal `roc notebook.roc` execution runs the saved entry point using saved
defaults. `roclet run` may additionally select outputs and override declared
parameters. The notebook engine evaluates output roots through its adapter;
it does not execute a handwritten entry point automatically on each edit.

### 4.5 Optional output snapshots

`# =>` is reserved snapshot syntax. Ordinary comments are never rewritten as
outputs. A snapshot may follow the output definition or immediately follow it:

```roc
out_report = report
# => First line
# => Second line
```

Snapshots are opt-in on save, with per-notebook settings and size limits.
Default source stays free of computed results. Snapshots have no role in
evaluation, are unverified on import, and are cleared or visibly marked stale
after relevant edits. Full provenance belongs in optional output storage.
Avoid inserting an inline snapshot after an unfinished multiline expression.
Escape control characters and preserve newlines safely when generating comments.

Roc comments store the plain-text representation. Markdown uses visible output
blocks as proposed in section 5.1. Converting formats preserves saved snapshots;
it does not rerun code to manufacture new ones. Rich renderings and their assets
must survive through the optional output store and notebook metadata, alongside
the Roc file's readable text representation. Dropping those rich representations
requires an explicit text-only conversion choice, not an implicit downgrade.

### 4.6 Prose encoding

Markdown cells use one comment prefix per line: `# ` for content and `#` for an
empty line. Strip exactly one prefix when decoding. Thus a Markdown heading
`# Title` becomes `# # Title`, and a literal Markdown line `# %%` becomes
`# # %%`, avoiding accidental cell boundaries. Preserve indentation and fences.

## 5. Markdown representation and conversion

Use standard Markdown and fenced Roc code. Within a document explicitly opened
as a Roclet notebook, a plain `roc` fence is executable; `roc example` is a
documented non-executable fence. Other languages and nested example fences remain
prose. Opening ordinary Markdown for preview does not authorize execution.

Emit triple backticks for new code fences by default. Accept and preserve tilde
fences in imported documents. Use a longer fence when needed to contain literal
fence characters safely. The four-backtick outer fence below only lets this design
document show a Markdown example containing ordinary triple-backtick fences.

````markdown
# Wall area

Change the dimensions to update the result.

```roc
out_1 = area
```

```roc
width = 5
height = 3
area = width * height
```
````

Each executable Roc fence is one code cell. Contiguous prose outside executable
fences and inferred output snapshots is one Markdown cell unless an explicit
boundary splits it. Headings and paragraph breaks alone do not start new cells.
Blank separator lines around code fences do not create empty Markdown cells.

Consequently, two consecutive Roc fences need no `<!-- %% -->` marker,
and neither does a transition from Markdown to Roc. A transition from Roc to
ordinary prose also needs no marker. A Markdown cell beginning with a block
that could be inferred as output needs an explicit separator, as described in
section 5.1. Two consecutive Markdown cells also need an explicit separator:

```markdown
## First Markdown cell

Its explanation goes here.

<!-- %% -->

## Second Markdown cell

This remains a separate editable cell.
```

Cell attributes still require metadata, such as `<!-- %% id=intro -->`
before the cell they describe. An empty code cell is represented by an empty Roc
fence and needs no extra marker. An empty Markdown cell needs an explicit kind
marker, `<!-- %% markdown -->`, because whitespace alone cannot preserve
its existence. This marker starts a Markdown cell even if the next item is a Roc
fence, another cell marker, or the end of the document. Recognize a marker only
when it occupies its own line as a document-level HTML comment, outside code
spans, fenced/indented code, block quotes, lists, and other nested content. Keep
the structural parser and serializer consistent about attachment and boundaries.

The compact `%%` marker is proposed to match Roc's `# %%` convention. Bare empty
comments (`<!-- -->`) and ordinary attribute-like comments (`<!-- id=abcd -->`)
remain literal Markdown content. Using those as metadata would be possible only
by reserving them and requiring authors to escape otherwise ordinary comments;
the small `%%` prefix avoids that common ambiguity without a long product prefix.

Any reserved syntax still needs an escape. If a Markdown cell itself contains an
exact marker-shaped comment, encode it with one backslash before the percent signs:

```markdown
<!-- \%% -->
<!-- \%% id=abcd -->
```

These are literal hidden comments in the Markdown cell, not cell boundaries or
attributes. Roclet removes the escape in the cell's logical content and restores
it when serializing. For a literal comment whose prefix already contains one or
more backslashes before `%%`, add one extra backslash; decoding removes exactly
one and never reclassifies that literal as metadata. This makes escaping reversible.
No escape is needed in code spans, fenced examples, or other contexts where marker
recognition is disabled. To show the comment visibly to readers, use a code span
or code fence. Source serializers apply necessary escapes automatically; raw-source
authors can write them explicitly. Unchanged saves preserve original source text.

Malformed marker-shaped metadata gets a format diagnostic rather than being
guessed to be prose. Literal comments that happen to contain words such as `id`
or `markdown` are never used for metadata inference.

Ordinary GitHub rendering shows the document, code, and any included visible
output snapshots, without running Roc. A report export can additionally choose
layout and hide code; saving snapshots does not require exporting a separate report.

Preserve the application header, optional compiler settings, and generated-entry
point state in document metadata. A proposed versioned HTML comment stores JSON,
for example `<!-- roclet:document {"format":1,"rocPreamble":"app [main!] {}"} -->`.
Escape comment terminators in encoded metadata. Additional user metadata must
round-trip. Existing `# =>` snapshots inside Roc fences can be imported and
preserved on no-op saves; newly saved Markdown snapshots use section 5.1.

The normal generated entry point is reconstructed when saving Roc; exceptional
handwritten/generated-section conflicts must be retained in explicit metadata or
a preserved source block, never dropped during conversion.

Two round-trip guarantees are distinct:

1. **Semantic and document fidelity:** code, prose, cell boundaries, settings,
   names, explicit IDs, and unknown supported metadata survive either direction.
2. **Text fidelity:** no-op saves in the same format preserve untouched text.
   Changing representation may normalize delimiters, fences, or line endings;
   it does not claim byte-for-byte cross-format identity.

Retain concrete source slices and a source map alongside the parsed document.
Preserve author formatting unless they request formatting. Use the Roc formatter
only on code ranges, with tests that cell markers and snapshots survive.

Switching views is an in-memory operation and does not reevaluate unchanged
code. Save As changes the chosen backing file; export makes a separate copy.
External assets and relative imports retain their base path on format changes.
Moving to a different directory requires copying assets or explicit path repair.
Malformed code can be saved as a draft and preserved in either representation;
conversion that needs an ambiguous transformation must diagnose it rather than
invent code. Runnability applies to valid notebooks, not unfinished drafts.

### 5.1 Optional visible output snapshots

Infer common output snapshots by adjacency rather than surrounding them with
output markers. A `text` fence immediately after an executable Roc fence is that
cell's saved output, with ordinary blank separator lines allowed:

````markdown
```roc
out_area = width * height
```

```text
15.0
```

This paragraph starts the author's next Markdown cell.
````

If the next Markdown cell itself starts with a text fence, use the existing cell
boundary marker to end output inference:

````markdown
```roc
out_area = width * height
```

<!-- %% -->

```text
This is an example in the author's explanation, not a saved result.
```
````

Use a small, specified set of output-shaped Markdown blocks:

| Immediately adjacent block | Interpretation while accepting output |
| --- | --- |
| Fenced block with the exact info string `text` | Plain-text output snapshot |
| Paragraph containing only a single image, apart from whitespace | Image output snapshot |
| GitHub-flavored Markdown table | Table output snapshot |
| Another executable `roc` fence | A new code cell; never an output block |
| Heading, ordinary paragraph, list, quote, other fence, or ordinary comment | Start of a Markdown cell; output inference ends |

An image can use `![Area by width](analysis.assets/area.svg)`. The referenced asset
must accompany the notebook for online and offline viewing. Parse actual Markdown
blocks, including table and image structure, rather than guessing from line prefixes.
Do not classify an ordinary paragraph as output because its text resembles a
number or inspected Roc value.

The parser has a simple state transition: an executable Roc fence starts a new
cell and enables output association. A following recognized output block attaches
to that cell and keeps association enabled; a contiguous sequence of such blocks
forms one ordered display snapshot. Whitespace does not interrupt the sequence.
An explicit cell boundary or any other Markdown block ends association. Once a
Markdown cell has started, later text fences, tables, and images remain part of
that cell until another executable Roc fence begins a new code cell.

Thus a plot followed by a text summary can be saved without metadata. A following
author-written table or image requires `<!-- %% -->` if it would otherwise extend
the output sequence. Explicit cell attributes also establish a boundary. An output
sequence at end of file requires no closing marker.

Only document-level blocks participate; nested content and anything inside a
fence are opaque to cell/output segmentation. A renderer showing generated Roc
source must serialize it as a `text` fence with a sufficiently long delimiter,
not as an executable `roc` fence. General rendered Markdown that cannot be encoded
unambiguously as supported output blocks uses a text/image representation while
its richer payload is preserved in optional output storage. Extending the set of
inferred output forms requires an explicit format contract; installing a renderer
must not silently reclassify existing prose.

The notebook editor retains each block's role during editing. It inserts a cell
boundary automatically when saving author content that would otherwise look like
output, including when removing a snapshot or a preceding paragraph. Raw-source
authors use the marker explicitly. No IDs, output wrappers, or separate output
escape syntax are needed. The ordinary `%%` literal-comment escape still applies.

Preservation rules:

- The inferred output sequence is a snapshot attached to the cell, not an editable
  Markdown cell or an extra computation. Moving the cell in notebook view moves
  its snapshot. Inference applies even when the notebook source is currently
  invalid; it does not depend on a successful type check or evaluation.
- If a cell has both inline `# =>` comments and inferred adjacent outputs, report
  duplicate snapshots rather than guessing which is authoritative. Multiple
  adjacent output blocks alone are one snapshot, not duplicates. Conversion moves
  the snapshot representation; it does not leave two copies behind.
- The format stores a display snapshot, not a serialized live Roc value. Imported
  snapshots cannot satisfy dependencies, serve as an execution cache, or prove
  currentness. They start unverified regardless of any asserted provenance.
- On edits, remove invalidated snapshots from source on the next save by default.
  If a user chooses to retain them, include a visible stale-output label inside
  a recognized output block, such as a `text` fence, so static readers can see
  that status too. A label must not accidentally become a Markdown-cell boundary.
- File save and format conversion never execute cells merely to refresh snapshots.
  Save the available verified results, or preserve previously loaded snapshots as
  unverified. Output provenance and rich payloads belong in optional metadata/output
  storage; carry referenced files when exporting a bundle or converting formats.
- Debug transcripts remain a separate optional inclusion with explicit metadata
  distinguishing them from the designated result; text content alone is not enough
  to infer a debug stream. Saving a cell result does not automatically save debug
  messages, diagnostics, or credentials.

The save UI offers source only (default) and source with output snapshots, plus
size limits and an explicit option to include debug transcripts. Static outputs
are sanitized with the same renderer rules as live results. Large binary data is
kept in referenced assets rather than embedded as opaque blocks in source.

## 6. Document state, identity, and annotations

Use an in-memory model separate from both source formats:

| Entity | Important fields |
| --- | --- |
| Notebook | format version, backing URI, preamble, ordered cells, dependencies, settings |
| Cell | internal key, optional explicit ID, kind, exact source, output name, attributes |
| Revision | source revision, effective input revision, compiler/environment identity |
| Evaluation | revision, worker generation, root, status, value/display handle, diagnostics |
| Annotation | thread ID, cell anchor, optional range anchor, messages, resolution state |

Internal keys may be random and remain stable while editing; they are not written
into the source by default. `out_1` gives a convenient inferred label
`1`, and `out_sum` gives `sum`. A definition-only cell may be labeled
`width_and_height`. Labels are
not durable identities and are not cache keys.

For a local notebook, optional neighboring files are:

```text
analysis.roc                         # or analysis.md: the authoritative source
analysis.roclet.json                 # portable annotation/layout sidecar
analysis.assets/                    # referenced input files and media
analysis.outputs/                   # optional persisted result snapshots
```

The shared basename lets `.roc`/`.md` conversion keep the same sidecar. Two
independent notebooks with the same basename in one directory require a different
sidecar name and an explicit association. Ephemeral undo state, credentials,
compiler caches, and personal settings belong in local storage, not this sidecar.

The sidecar contains a schema version, document identity, last source fingerprint,
internal cell keys, mapping clues, comments, and chosen portable layout settings.
Use internal keys for layout references; never put a random key into source just
because a user commented, moved, or collaborated on a cell.

While Roclet edits a document, it updates anchors directly. After external edits,
reconcile using explicit IDs where present, then unique output names, previous
text and source diffs, and neighboring cells. This matching is annotation UX only;
it must never determine execution dependencies. Ambiguous matches become
unattached annotations awaiting reattachment. Track exact-range comments with
additional text/range anchors. Preserve deleted-cell discussions as history.

Explicit `id=...` attributes are added only at the user's request. They improve
cross-tool anchoring but still do not prove an output is current. Duplicating a
cell gets a new internal key and unique output name; split/merge operations retain
one original key and record lineage for the new pieces.

Collaboration later synchronizes this document model and discussion store, with
an offline replica and optional sidecar export. A CRDT or equivalent operation
log needs internal IDs but not IDs in the exported Roc file. Source edits may be
shared while evaluation sessions and widget inputs remain private by default.
Shared exploration is a separate explicit mode. Collaborator edits do not
authorize privileged effects on another person's computer.

## 7. Execution semantics

### 7.1 The unit of meaning is a module, not a REPL transcript

All executable code cells contribute to one Roc module. Definitions, types,
imports, and annotations are resolved together, allowing forward references.
Names cannot be redefined by a later cell. Removing or renaming a definition
removes the old binding from subsequent runs.

Do not replay successful REPL history after an edit: that would preserve deleted
bindings and could expose partially committed state. Prepare evaluation from the
current complete document snapshot. Compiler diagnostics remain authoritative
about validity, types, recursion, and effects.

### 7.2 Depend on definitions, display cells

Obtain resolved definition-to-definition dependencies from compiler data, then
map them to cells for explanation. Include dependencies on type definitions,
imports, selected methods/static dispatch, and external input versions. Functions
and closures can depend on names inside their bodies even before being called.

Do not schedule whole cells as indivisible dependency nodes. For example:

```roc
# %%
a = b + 1
c = 1

# %%
b = c + 1
out_1 = a
```

The definition graph is `c -> b -> a -> out_1`, but grouping by cell would
produce an apparent cycle. This notebook must work. Cell graphs are a UI view of
the finer compiler dependency graph, not the source of execution semantics.

Use compiler-approved strongly connected groups for valid recursive functions
and types. Reject invalid cyclic value initialization with a readable diagnostic.
Never prohibit all cycles or accept all cycles based on cell-level analysis.

### 7.3 Revision-based evaluation

For a code/input/environment change:

1. Save the editable draft and increment the relevant revision.
2. Mark affected outputs stale immediately. In the first engine, conservatively
   mark all computational outputs stale; prose-only edits need no reevaluation.
3. Debounce edits and prepare one immutable effective notebook snapshot.
4. Parse and check the module; create a new evaluation generation.
5. Evaluate selected pure output roots and publish structured result events.
6. Accept each event only if its document/input revision and worker generation
   still match. Never splice old values into the current graph.

Statuses are `idle`, `dirty`, `checking`, `queued`, `running`, `current`, `stale`,
`error`, `blocked`, and `cancelled`. Keep the old successful display visible if
helpful, but label it stale and do not use it to compute current results.

A compile error may block the entire module in the first release. This is an
explicit limitation. Running independent valid branches requires compiler support
for checked roots and error isolation; do not suppress diagnostics or guess which
invalid definitions to remove. A runtime failure must identify its root and
invalidate dependents; evaluation of other roots can continue when the adapter
explicitly supports that isolation.

Manual mode marks results stale and waits for Run. Auto mode reruns pure roots
after a configurable short debounce. Both modes propagate changes through the
same definition graph. Run Cell evaluates that cell's output and refreshes dirty
dependent outputs, using the current definitions throughout the document. Cell
position never determines execution order. The initial engine marks every output
dirty after edits, so a manual run refreshes the complete snapshot; once current,
rerunning one cell only replaces its own output and debug transcript. M4 narrows
the dirty set using compiler-resolved dependencies. Run All evaluates all output
roots for one revision. A definition-only cell can be checked and cause dependent
outputs to update without producing its own output.

### 7.4 Incrementality and caching

Start with complete module evaluation as a correctness reference. Next, use the
resolved graph to invalidate transitive dependents and request only affected
roots. The compiler may still recheck or recompute shared internals; only claim
work was avoided when measurements or explicit compiler cache contracts prove it.

True value reuse requires compiler-owned handles tied to a checked environment.
Never reconstruct Roc values by parsing inspected strings, and never deserialize
arbitrary closures into a different compiler instance. Cross-session caching is
limited to values with an explicit stable serialization contract.

A cache key includes semantic source, resolved dependencies, concrete inputs,
compiler/build identity, adapter version, packages, platform, and renderer version
where relevant. Cell IDs, names, and positions alone are insufficient. Native
and WASM numerical equivalence needs tests and documented float tolerances;
bitwise identical floating-point output is not assumed.

## 8. Effects, parameters, and widgets

The first engine automatically evaluates pure roots only. It can retain definitions
of effectful functions without invoking them. Classify operations using checked
Roc semantics and explicit host capabilities, not just a `!` in a name.
User `dbg` observations are captured separately from designated outputs and are
not cached as values; their frequency may change with reevaluation. They are
allowed during automatic evaluation and do not require an action button or
capability prompt. The compiler still checks the expression being inspected;
wrapping an external effect in `dbg` does not authorize that effect.

Later, effectful cells become explicit actions with Run buttons. Action requests
carry the current input revision, declared capabilities, and cancellation state.
Dependent calculations consume a recorded action result. If inputs change, mark
that result stale until rerun; never silently submit an external write again.
Independent effects have no implicit ordering from cell position. Dependent
actions require explicit ordering. A Stop cannot undo a completed external effect.
Do not promise exactly-once behavior for arbitrary external services.

Introduce simple widgets first as typed parameter editors over designated
top-level defaults. For example, proposed optional metadata could be:

```roc
# %% input=slider min=1 max=20 step=1
width = 5
```

The widget changes a session input overlay, not the saved default on every drag.
An explicit Save Current Inputs as Defaults persists it. Before checking, a
parser-backed transformation substitutes validated values at declared parameter
bindings, preserving their Roc types and source mapping. CLI `--set width=8`
uses exactly the same overlay. Do not interpolate arbitrary text into source.
Ordinary `roc notebook.roc` uses saved defaults; parity requires equal effective
inputs, not hidden browser state.

This parameter design avoids requiring a hidden global widget runtime in ordinary
Roc scripts. General custom widgets and callbacks may later justify a notebook
platform API, but must demonstrate script/browser semantics before adoption.

Add sliders, toggles, text fields, dropdowns, file inputs, and forms. Numeric
controls must round-trip large integers and decimals without JavaScript number
precision loss. Debounce expensive updates; offer submit-once forms. Input files
become versioned data attachments with typed decoding, not implicit filesystem
access. Time, randomness, and external data become explicit seeded/snapshotted
inputs when reproducibility is requested.

## 9. Architecture and compiler boundary

```text
Roc / Markdown files <-> Roclet core <-> browser UI / CLI host
                             |
                    versioned compiler adapter
                             |
               Roc parser / checker / evaluator in WASM

Browser host: DOM, editor, storage, downloads, worker lifecycle
Compiler worker: compilation, evaluation, handles, structured events
Service worker: application and dependency caching for offline startup
```

Keep the pure core independent of browser APIs. Compile it for browser and native
hosts; first verify that a small Roc core can exchange model/update messages with
both. If this host interface needs work, make it an explicit milestone dependency
rather than permanently moving the product's semantics into JavaScript.

Use TypeScript for a thin browser shell and editor integration, and Zig where
necessary to expose compiler internals through a stable adapter. A mature editor
component such as CodeMirror is a candidate, to be selected in a small integration
spike. Do not build a new general code editor as part of Roclet. Host-side Markdown
parsing is acceptable if it returns a versioned syntax tree with exact source spans
and leaves notebook transformation rules in the Roc core.

### 9.1 Required adapter contract

These are proposed operations; the current REPL does not expose all of them:

| Operation | Required result |
| --- | --- |
| `capabilities` | compiler identity, protocol version, supported syntax/effects, limits |
| `parseDocument` | declaration/expression spans, lexical scope information, diagnostics |
| `checkModule` | checked revision, resolved definitions, dependency edges, types, regions |
| `evaluateRoots` | values/display payloads, ordered debug/runtime events attributed to evaluation roots, per-root completion/failure |
| `inspectValue` | bounded structured inspection or opaque instance-scoped handles |
| `formatRange` | edits or formatted text with source mapping |
| `disposeRevision` | release environments and result handles |

Define ownership, allocation/free rules, error taxonomy, maximum message sizes,
and UTF-8 byte offsets. Translate browser UTF-16 positions at one tested boundary.
Include request ID, document revision, input revision, and worker generation on
messages. The adapter must return resolved semantic facts, not HTML dumps or text
that the host has to scrape. Negotiate optional features explicitly.

Debug events include an evaluation/run ID, sequence number, inspected text, and
the originating source region when available. Compiler-generated observations
must remain distinguishable from user `dbg` statements. Root attribution and
source-region reporting require adapter work beyond the current REPL's plain
`{kind: "dbg", message: ...}` events. Compile-time observations must carry the
same revision identity; do not drop them just because they precede runtime calls.

The existing pure WASM REPL provides useful scaffolding, allocation rules, and
structured envelopes. The whole-program browser compiler demonstrates execution.
Neither yet satisfies this contract. Prefer a thin upstreamable API over a
permanent compiler fork or a second Roc parser in the application.

Do not add notebook-specific `out_` recognition to the compiler. Roclet selects
bindings and passes ordinary root identifiers to the adapter. Keep language
semantics, notebook conventions, and display policies in their respective layers.

### 9.2 Workers, interruption, and memory

Compilation and evaluation run in a dedicated worker so typing remains responsive.
Stop terminates the worker when cooperative cancellation is unavailable, invalidates
all its handles, and rebuilds only the current pure snapshot on demand. Worker
generations prevent old responses from being accepted after restart.
[Worker termination is immediate and does not run cleanup](https://developer.mozilla.org/en-US/docs/Web/API/Worker/terminate).

Apply explicit output, execution-time, and memory budgets. Worker isolation does
not by itself prevent a large WASM allocation from exhausting browser resources;
set supported module memory limits and test allocation failures. Release old
compiler environments and render handles. Read memory views afresh after calls
that may grow WASM memory, because growth can invalidate existing views.
[WebAssembly memory behavior](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Memory).

Initial execution uses one worker per active notebook, with a cap on simultaneous
workers. Parallel roots and shared compilation caches are later optimizations.
Avoid requiring shared memory or threads for basic use; they complicate deployment
and are not necessary to keep the UI responsive.

## 10. Rendering and editor experience

### 10.1 Debug messages belong in the notebook

Users can write ordinary Roc debug statements and see their messages immediately
below the relevant cell, in an expanded debug area alongside its designated result.
The browser console is never required. For example, the editor can show:

```roc
out_1 = {
    area = width * height
    dbg area
    area + 1
}
```

For `width = 5` and `height = 3`, the cell shows a debug message `15.0` and a
separate result `16.0`. Multiple `dbg` statements inside ordinary Roc blocks or
functions produce messages while the cell has at most one `out_*` result.

Code cells use ordinary top-level Roc syntax. The sole exception is a final
expression, which is assigned to a collision-free `out_*` constant and printed
by the generated `main!` in cell presentation order. A top-level `dbg area` is
invalid; Roclet reports it without rewriting or dropping it. There are no
observation helper functions or special debug-lowering annotations. Debug calls
inside functions and expression blocks retain ordinary Roc evaluation semantics.

Display and lifecycle rules:

- Attach a message to the evaluation root's cell. If a called function or imported
  module emitted it, also offer a source-location link when available. Do not copy
  a shared observation into every dependent cell or infer origin from print text.
  A compile-time observation without a root uses its mapped source cell, or a
  visible notebook-level debug area when no cell can be identified reliably.
- Preserve event order within a run. Distinct root evaluations have distinct run
  identities; do not imply a global ordering when roots eventually run in parallel.
- Show events as the adapter delivers them. Support incremental delivery, but
  document an adapter that initially buffers until a root finishes. Do not claim
  live streaming for the current synchronous REPL response protocol.
- On rerun, start a new debug transcript for the affected evaluation. Previous
  messages can remain as labeled history, but are never mixed into the new run.
  Unchanged cells retain their existing, correctly labeled transcripts.
- A failure or cancellation preserves messages already received for that run,
  marked failed or cancelled. Reject late events from superseded revisions or
  terminated workers just as for result values.
- Bound message count and byte size, showing a visible truncation notice and a
  copy/export option for retained messages. Render inspected text as text, not HTML.
- Debug transcripts are transient by default. They are not written into source
  snapshots or portable bundles unless the user explicitly includes them.
- Cached results do not manufacture fresh debug events. If an old transcript is
  shown, identify it as belonging to the earlier execution. Any compiler replay
  of recorded compile-time events must be labeled as replay rather than a new run.

The generated `main!` only supplies script execution behavior. In notebook mode,
the adapter delivers designated results and user debug events separately, so the
generated output calls do not duplicate the displayed results.

### 10.2 Rich results and editing

Start with plain text, type labels, and diagnostics. Then introduce a bounded
display protocol with a mandatory plain-text alternative and optional Markdown,
images, tables, and declarative plots. iRoc's structural-tag display work is useful
prior art, but its native formatter capabilities must not be assumed present in
the WASM REPL. Do not detect a rich value by parsing its inspected text.

Preserve integer/decimal precision using typed strings or binary encoding at the
JavaScript boundary. Limit depth and collection size in previews. Virtualize large
tables, paginate inspection, and offer explicit downloads for complete values.
Renderer errors should leave the underlying plain-text result available.

Sanitize Markdown, HTML, SVG, and links; no arbitrary scripts or event handlers in
outputs. Built-in renderers get a narrow API. Active third-party renderers require
an isolated context and explicit permissions. WASM does not sandbox unsafe DOM
rendering or overpowered host imports.

The first editor includes:

- Add, delete, duplicate, split, merge, move, and collapse cells, with full undo.
- Notebook view and complete raw-source view, with source mapping and selection
  retained when switching. Neither view hides irrecoverable source transformations.
- Keyboard navigation, IME-safe input, accessible labels, visible focus, and a
  screen-reader-friendly relationship between code, status, diagnostics, and output.
- Auto/manual execution, Run Cell, Run All, Stop, and a visible save destination.
- Syntax highlighting, compiler diagnostics, type hover, and completion within the
  adapter's advertised scope. Expand refactoring and completion later.
- Optional outline and dependency inspector, including “why did this rerun?”
- Notebook/article presentation and a clean read-only view, while always retaining
  a route to edit source when the bundle includes it.

Typed graph edits and editor navigation do not require rich animation. Respect
reduced-motion settings and keep keyboard workflows available for every action.

## 11. Persistence, offline operation, and reproducibility

### 11.1 Saving and recovery

Use transactional browser storage for document drafts, annotations, and revision
history; use a suitable blob/file store for large attachments. Keep the abstraction
independent of IndexedDB versus OPFS so the UI is not tied to one browser API.
Browser storage is origin-scoped, may be quota-limited, and may be evicted.
Request persistent storage when appropriate, expose storage usage, and make
downloadable backup a first-class feature.
[Browser storage constraints](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria).

Autosave locally before scheduling evaluation. Do not claim a file is saved until
the chosen destination acknowledges the write. Provide ordinary upload/download
everywhere; direct file handles are a feature-detected enhancement. Reopening
must make clear whether the active copy is a browser draft or a filesystem file.
Use atomic file replacement for native saves. Detect concurrent external changes
and offer a three-way merge instead of last-writer-wins replacement.

Two tabs editing the same document need a write lease, coordinated revision
checks, or the collaboration engine. Do not let them silently overwrite each
other. Source and sidecar writes use a shared saved revision so interrupted saves
can be reconciled, even when the filesystem cannot commit both atomically.

### 11.2 Offline distribution

Distribute Roclet as a static application/PWA with an explicit offline preparation
step. Cache a versioned manifest of the shell, compiler, core runtime, editor,
renderers, fonts, and bundled documentation. A notebook's offline manifest also
covers modules, packages, attachments, and any requested external-data snapshots.

The application must verify every required resource before displaying “Ready
offline.” Do not rely on assets being incidentally cached by previous visits.
Network-disabled tests must cover reopening, editing new code, imports, diagnostics,
rendering, saving, and export, not merely viewing an old output.

Service workers support offline application loading, but normally require HTTPS
or a supported localhost origin. A file opened through `file://` is a separate
distribution problem. First release promises an installed/cached app and a static
bundle served from a supported origin. A double-clickable, self-contained HTML
export is a later compatibility spike, not an untested promise.
[Offline application model](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Offline_and_background_operation),
[service worker deployment requirements](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API).

Ship a ZIP-based portable bundle containing source, assets, manifests, compiler
selection, and optionally annotations/results. An installed Roclet can import it
offline. A full editor distribution must also be available for users setting up
an air-gapped machine through a local static server. Distinguish this from a small
notebook bundle that assumes the compatible editor/runtime is already installed.

Install upgrades into a new versioned cache, verify completion, then switch at a
safe restart. Never mix old core code with a new compiler protocol. Failed or
interrupted updates leave the existing offline installation usable.

### 11.3 Dependency and data identity

Record compiler artifact hashes, adapter/core versions, package hashes, target,
input file hashes, and saved parameter defaults. Use Roc's package/platform
conventions where possible; do not invent another package manager. Vendor the
complete resolved set for offline execution and record licenses for redistribution.

Native-only platforms or unavailable browser imports produce explicit portability
diagnostics. An optional native backend can eventually support them, but switching
to remote/native execution must be visible and never an automatic fallback.

Keep credentials outside source, comments, result snapshots, bundles, and portable
sidecars. Cache only explicitly selected external responses. A reproducible run
must identify whether data came from a snapshot or a refreshed source.

## 12. CLI, exports, and interoperability

Proposed commands, sharing the same core and compiler contracts as the browser:

```sh
roclet edit analysis.roc
roclet run analysis.md
roclet run analysis.roc --set width=8
roclet check analysis.roc
roclet test analysis.roc
roclet convert analysis.roc --to markdown --output analysis.md
roclet convert analysis.md --to roc --output analysis.roc
roclet export analysis.roc --format html --output dist/
roclet export analysis.roc --format markdown --output report.md
roclet bundle analysis.roc --offline --output analysis.roclet.zip
```

Conversion changes representation; export produces a presentation artifact.
Neither overwrites an existing destination silently. `check` checks source and
format without executing external actions; checking may still run Roc's normal
compile-time evaluation. `test` executes declared `expect` tests using the tested
compiler's test semantics. `run` emits values or versioned machine-readable result
records, diagnostics on a separate channel, and documented nonzero exit codes
for format, compile, evaluation, or missing-dependency failures.

The browser app can optionally be served by a tiny local CLI server, but the server
is not required for computation in the default browser mode. The CLI is a native
executable using the shared compiler adapter; the intended release CLI adds the
Roc native core through a deliberately packaged compatible host interface.
Do not create a permanently separate execution implementation just for CLI use.

Use Zig for the outer build: compiler bootstrap, adapter compilation, artifact
verification, tests, and installation. This reuses the toolchain already required
by the pinned Roc compiler and avoids requiring a working Roc compiler before
bootstrap. Application logic and substantial document-processing tools belong in
Roc and can be invoked by the Zig build once their compiler is available. Build
orchestration does not determine the implementation language of the application
CLI or server. Do not require Node.js or Python for normal development or use.

Static exports include provenance and show results as snapshots. Interactive
exports include everything needed for declared interactions. Editable exports
also include the compiler and source dependencies. Distinguish these sizes and
capabilities in the export dialog. Precompiled viewer-only apps may omit the
compiler once a stable parameter ABI is proven.

Keep normal Roc modules the primary reuse mechanism. Add “Extract to module” and
explicit notebook exports later; importing a notebook must not execute arbitrary
actions or drag presentation/annotation state into an ordinary library. Jupyter
import/export can preserve supported Roc cells and MIME outputs later, with
diagnostics for semantics that cannot be translated. Do not claim automatic
translation of Python notebooks into Roc.

## 13. Proposed repository layout

```text
design.md
README.md
core/                 # Roc document model, conversions, state, scheduling policy
formats/              # versioned format specification and conformance examples
compiler-adapter/     # Zig/compiler bridge and versioned protocol
platform/             # host boundary for Roclet core and optional render helpers
web/                  # browser shell, editor adapter, worker, service worker
cli/                  # command host using the shared core
renderers/            # text first; tables, plots, and media later
tests/
  fixtures/           # Roc/Markdown pairs, malformed drafts, tricky dependencies
  integration/        # native/WASM parity and protocol ownership
  browser/            # offline, cancellation, recovery, accessibility
  performance/        # measured startup/edit/memory workloads
examples/             # executable documentation and sample notebooks
scripts/              # fetch verified compiler artifacts, build, package, checks
```

Pin toolchains and artifact checksums. Keep fetched compiler binaries and build
outputs out of source control. Establish a clear license before redistributing
the app and bundled dependencies. This plan does not initialize a repository,
choose a license on the user's behalf, or implement these directories yet.

## 14. Implementation milestones

Each milestone ends with a demonstrable result and a release gate. Do not attach
calendar estimates until the compiler-adapter spikes establish the largest risks.

### M0 — Prove and pin the execution foundation

Tasks:

1. Check in small conformance fixtures for forward references, anonymous outputs,
   per-definition dependencies, recursion, types, imports, and errors.
2. Repeat the initial probes against a freshly identified native/WASM artifact
   pair. Record hashes, build instructions, size, and supported capabilities.
3. Prototype complete-module analysis and root evaluation with source regions.
   Decide whether to extend the pure REPL, whole-program interface, or expose a
   shared lower-level API. No text scraping or sequential cell replay.
4. Prove a tiny Roc core can run with browser and CLI hosts.
5. Define adapter ownership, revision, error, debug-event attribution, and
   cancellation contracts. Verify the WASM host delivers user `dbg` observations.

Gate: the same supported fixture produces equivalent native/browser results
under every valid cell permutation; errors, deleted names, and worker restarts
cannot expose old values. List unsupported syntax explicitly. A virtual-module
wrapper alone is insufficient evidence for arbitrary module conversion.

### M1 — Freeze the minimal format and implement conversion

Implemented. See [M1 implementation notes](docs/m1.md) for the pinned format,
commands, execution limits, and validation results. The format playground is
available at `/web/formats.html`; the reactive cell editor is at `/web/edit.html`.

Tasks:

1. Implement loss-preserving cell segmentation and comment-only Markdown inference
   using compiler lexical/source data, with explicit kind overrides and stable
   cell kinds during notebook editing.
2. Implement output detection, trailing-expression lowering and ordinary nested `dbg` support, and
   generated entry point validation. Cover strings, multiline literals, comments,
   rejection of top-level `dbg`, round-trip reconstruction, and local scope.
3. Implement Markdown parsing/encoding, preamble preservation, and source maps.
4. Add conversion/check commands and exact diagnostic locations.
5. Support optional IDs and reserved output comments without requiring a sidecar.

Gate: round-trip fixtures preserve semantics and document structure; no-op saves
retain source text; valid Roc exports run; malformed drafts lose no text; source
never receives a random ID without an explicit request.

### M2 — Ship a local reactive browser prototype

Implemented at `/web/edit.html`. See [M2 implementation notes](docs/m2.md) for
the evaluation, recovery, editor, and rendering limits.

Tasks:

1. Build cell editing, movement, raw-source view, Markdown rendering, and undo.
2. Evaluate complete pure snapshots in a dedicated worker after edits.
3. Add result/status rendering, inline ordered `dbg` messages, structured
   diagnostics, and cancellation.
4. Add browser autosave, recovery, upload/download, and visible save status.
5. Handle stale generations, incomplete code, and generated-section conflicts.

Gate: the wall-area notebook works in arbitrary order, changing width updates both
outputs, deleting a definition fails visibly, Stop works during nontermination,
and reopening restores the draft. `dbg` messages appear beneath their cells;
nested debug calls, reruns, and failures preserve the debug display contract.
No stale result is labeled current. Whole-module recomputation and module-wide
checking failures remain documented limitations.

### M3 — Offline use and sharing

Implemented for the current self-contained notebook runtime. See [M3 notes](docs/m3.md)
for the offline installation, portable exports, recovery protection, headless
package, validation, and remaining browser release checks.

Tasks:

1. Add versioned service-worker caches and an offline readiness manifest.
2. Bundle compiler/modules/assets, verify hashes, and implement portable import.
3. Add static report and editable interactive exports.
4. Test storage exhaustion, interrupted updates, failed saves, and recovery.
5. Package a headless runner using the same core and evaluation contract.

Gate: after explicit preparation, disable all networking, close the app, reopen,
edit, execute, save, and export. Import the bundle in a separate prepared browser
profile and reproduce the results. Basic operation needs neither accounts nor
external CDNs. This is the first useful release candidate.

### M4 — Selective recomputation and developer tooling

Implementation and compiler-boundary limitations: [M4 notes](docs/m4.md).

Tasks:

1. Expose resolved definition dependencies and checked-root APIs in the adapter.
2. Implement transitive invalidation, precise source/type/import tracking, and
   per-root evaluation. Add compiler-owned reuse only with an ownership contract.
3. Add dependency explanations, timing, type hover, rename, and richer completion.
4. Isolate independent errors where supported by the compiler.
5. Benchmark against the full-recompute reference and pin regression workloads.

Gate: changing one branch leaves an independent branch's output current and avoids
its evaluation where supported; adding/removing definitions updates edges; valid
recursive groups and cell-level apparent cycles work; results equal a clean run.

### M5 — Typed inputs, tables, and plots

Rich output foundation implemented: [M5 notes](docs/m5.md). Markdown, images,
bounded paged tables, and portable rich snapshots are available. Typed parameters,
widgets, data attachments, and plots remain to be implemented.

Tasks:

1. Implement declared parameters, typed session overlays, CLI overrides, and
   explicit default persistence.
2. Add initial widgets, structured display values, tables, and declarative plots.
3. Support file attachments and basic CSV/JSON decoding with useful errors.
4. Add inspection budgets, large-result virtualization, and plain-text alternatives.

Gate: widget inputs and identical CLI overrides produce equivalent results;
defaults survive format conversion; large numbers retain precision; display
failures do not invalidate computation; all initial widgets work offline.

### M6 — Actions, history, and app presentation

Tasks:

1. Introduce explicit action execution and capability-scoped host effects.
2. Add portable annotation sidecars, cell history, and conservative anchor repair.
3. Add app layouts, parameter presets, experiment comparison, and richer publishing.
4. Add tests/CI execution and module extraction workflows.

Gate: reactive edits do not repeat external writes; cancelled/late action results
cannot become current; external edits do not misattach discussions; app/notebook
views use the same computation and source.

### M7 — Collaboration and broader ecosystem

Add optional synchronization, collaborative editing/review, shared exploration,
renderer extensions, data/SQL integrations, larger scientific libraries, optional
native/remote backends, and optional AI. Prioritize based on actual notebook use.

Gate: offline edits merge without source loss; concurrent cell changes retain
annotations or surface ambiguity; collaborators cannot trigger privileged local
actions; solo/offline use remains fully supported.

### Feature backlog beyond the initial release

These retain the broader product ambition without making every feature a prerequisite
for a usable notebook. Each should reuse the same document and execution contracts.

| Feature family | Planned capabilities | Earliest sensible foundation |
| --- | --- | --- |
| Scientific work | numerical/statistical libraries, units, mathematical notation, large arrays; optional accelerated kernels | M5, backed by useful Roc/WASM libraries |
| Visual exploration | linked chart selections, maps, animation, SVG/PNG export, accessible alternatives | M5 display values and typed inputs |
| Data analysis | Arrow/Parquet, SQL, profiling, joins, streaming tables, code-visible visual transformations | M5 data protocol, later library integrations |
| Experiments | parameter sweeps, named configurations, comparison views, seeded replay, execution provenance | M5 inputs and M6 history |
| Writing and teaching | equations, citations, computed prose, slides, books, hints, exercises, resettable examples | M3 publishing and M6 presentation |
| Reusable UI | forms derived from types, reusable widgets, smart cells exposing generated code | M5 typed inputs and stable extension API |
| Software engineering | module extraction, CI, property tests, benchmarks, richer debugging and profiling | M4 compiler data and M6 workflows |
| Team work | comments, review, forks/merges, offline synchronization, private versus shared runtime state | M6 annotations and M7 synchronization |
| Optional AI | explanations, dependency-aware cell edits, test/plot suggestions, reviewable diffs and undo | Stable model/edit API; explicit data-sharing controls |

Keep local use and all basic features independent of any paid service. Optional
online integrations should declare their offline behavior and permissions. An
extension should not need to understand Roclet's private serialized state to add a
renderer or widget; expose a documented versioned API after built-in use validates it.

## 15. Verification strategy

Maintain a simple full-recompute engine as the semantic reference for optimized
execution. Prefer tests of contracts and failure modes over tests that merely
repeat an implementation's structure.

| Area | Required cases |
| --- | --- |
| Source format | bare markers, comment-only Markdown inference, explicit kind overrides, stable kind while commenting out code, spacing, comment/string lookalikes, orphan snapshots, multiline expressions, annotations, imports, empty cells, malformed drafts |
| Output selection | zero/one/multiple `out_*` bindings, local names, duplicate names, anonymous naming, external references to outputs |
| Round trips | Roc -> Markdown -> Roc; reverse conversion; unchanged save; unknown metadata; nested/longer fences; consecutive Roc fences and prose/code transitions without markers; explicit adjacent prose boundaries; empty code and prose cells; literal empty/attribute-like comments; escaped marker comments and repeated backslashes; Unicode |
| Saved outputs | adjacent text/image/table inference, multiple-block output sequences, whitespace, explicit boundaries before output-shaped prose, ordinary prose ending association, later text blocks staying prose, executable Roc fences always starting new cells, generated Roc snippets safely fenced as text, duplicate snapshot representations, automatic boundary insertion on save, stale labels, no execution on save, rich asset preservation through conversion, debug transcripts opt-in |
| Generated code | compatible header, zero outputs, changed generated body, handwritten `main!`, display order, user effects never auto-invoked |
| Dependencies | all permutations of small fixtures, forward references, shadowing, methods, closures, type edits, imports, valid recursion, invalid value cycles |
| Reactivity | delete/rename/split/merge, type changes, removed imports, stale outputs, no ghosts from REPL history |
| Concurrency | rapid edits, late results, Stop, worker restart, simultaneous tabs, failed compile after prior success |
| Debug observations | rejection of top-level `dbg`, ordinary function/block `dbg`, multiple messages, root/source attribution, compile-time events, reruns, failure/cancellation, cache replay labels, output limits, no duplicate generated output |
| CLI/browser | matched effective inputs, exact integer/decimal values, documented float comparison, errors, tests, missing dependencies |
| Persistence | crash before save, incomplete drafts, interrupted paired save, quota failures, external edits, backup/import |
| Offline | cold restart after preparation, network disabled, missing asset, no CDN, failed upgrade, compiler mismatch |
| Rendering | hostile HTML/SVG, huge values, precision, renderer failure, keyboard and screen-reader access |
| Annotations | move/rename, duplicate cells, ambiguous external rewrite, orphan thread, source stays ID-free by default |

Use typed property-based generation for valid Roc fragments and random
presentation permutations. Compare optimized evaluation with clean evaluation.
Fuzz the format and protocol boundaries with bounded inputs; exercise allocator
ownership and Unicode offset conversion explicitly. Avoid broad language fuzzing
inside Roclet when that belongs to the compiler's own suite.

Run browser integration tests on supported Chromium, Firefox, and WebKit versions.
Release support should be tied to observed capability/test results. Mobile editing
can follow, but layouts, touch interaction, and accessibility should not assume a
large desktop display.

## 16. Performance and operational targets

Measure rather than advertise unverified speed or tiny downloads. The local REPL
WASM probe artifact was about 49 MB uncompressed; the whole-program artifact was
about 33 MB. These are observations of local builds, not optimized release budgets.

Record cold download/compile/startup separately from warm editing latency. Use
fixed browser versions and named desktop/mobile hardware for benchmarks.

Initial engineering targets, subject to M0 measurements:

- Typing and navigation remain responsive while compilation runs; avoid main-thread
  tasks above roughly one frame during ordinary edits.
- On the reference desktop, aim for a warm simple 100-cell edit-to-result p95 below
  300 ms after selective recomputation; publish actual measured results.
- A Stop updates the UI immediately and prevents any old generation from changing
  current state, even if physical resource reclamation takes longer.
- Memory use reaches a bounded steady state across hundreds of edits/restarts.
- Large outputs preview within explicit limits instead of creating unbounded DOM.

Track checking time, evaluation time, renderer time, WASM memory, host memory,
artifact size, cache hit rate, and worker startup. If whole-module checking dominates,
improve the compiler boundary before adding many workers or complicated app caches.
Basic correctness, save reliability, and cancellation are release requirements;
latency targets should not encourage stale or approximate execution.

## 17. Main risks and design decisions to revisit

| Risk or question | Current decision | Evidence needed to change it |
| --- | --- | --- |
| Compiler APIs are evolving | Pin artifacts and hide internals behind one versioned adapter. | Stable upstream analysis/root-evaluation API. |
| Top-level source and REPL semantics differ | Compile/check the complete module, not a cell transcript. | Conformance suite across all supported syntax. |
| Arbitrary module wrapping changes semantics | Treat virtual-module prototype as restricted. | Compiler-supported application roots or proven AST transformation. |
| Generic display changes polymorphic inference | Test rendering roots with generics, custom inspection, and nominal types. | A display API that preserves intended types and has precise errors. |
| Same-format cleanliness versus cross-format fidelity | Preserve source slices; normalize only necessary representation details. | Round-trip corpus showing where optional metadata is needed. |
| No source IDs weakens external annotation repair | Keep source clean; surface uncertain matches. | User explicitly opts into source anchors. |
| Source input defaults versus interactive state | Typed overlays, explicit save-as-defaults, same CLI transformation. | Custom widget requirements that justify a platform API. |
| Browser/compiler memory and package limits | Explicit budgets and portability checks. | Measured workloads and expanded browser support. |
| Native/remote execution complicates portability | Optional, visible, later. | Workloads that cannot be served well in-browser. |
| Building all wishlist features at once | Finish a trustworthy offline notebook first. | Real usage that identifies the next bottleneck. |

The M1 format decisions are recorded in [the implementation notes](docs/m1.md).
Both canonical formats persist lowered output bindings; untouched same-format
saves preserve the original bytes. Markdown uses `<!-- %% -->` boundaries and
reserved document/output metadata only where needed. The managed entry uses a
shared `display!` helper with string interpolation, collision-free naming, a
validated grammar, and round-trip fixtures; no observation wrappers are generated.

## 18. First implementation tasks

The next work should produce a narrow end-to-end proof, in this order:

1. Create repository/build scaffolding and record the chosen compatible toolchain.
2. Add the exact minimal notebook example and its Markdown counterpart as fixtures.
3. Build the compiler-adapter spike for complete-module checking and selected roots.
4. Implement the Roc document model, `out_*` recognition, lowering, and source maps.
5. Add `convert`, `check`, and a small headless evaluator with round-trip tests.
6. Put the same evaluator behind a worker and a basic cell editor.
7. Add autosave and Stop before adding rich output or visual styling.
8. Package the first offline bundle and test with network access disabled.

Do not begin collaboration infrastructure before this path works. The first
demonstration should be small enough to inspect completely and strong enough to
establish the source, execution, and offline contracts used by later features.

## 19. Evidence and references

### Local Roc evidence inspected on 2026-10-16

- Compiler checkout HEAD: `38a3029aa71b239c79b380adab7e90d4a848df96`.
  This is distinct from the already-built artifacts below; their build lineage
  must not be inferred from the checkout's current HEAD.
- [REPL WASM contract](/Users/ageron/dev/software/roc/src/repl_wasm/README.md)
  and [protocol types](/Users/ageron/dev/software/roc/src/repl_wasm/protocol.d.ts).
- [Whole-program browser test](/Users/ageron/dev/roc/www.roc-lang.org/ci_scripts/test_compiler_wasm.mjs).
- [Echo platform debug callback](/Users/ageron/dev/software/roc/src/echo_platform/mod.zig:315):
  the inspected WASM branch discards debug messages; the native branch writes to
  stderr. Roclet must supply an inline debug event path rather than inherit this
  host omission.
- [Current Roc syntax examples](/Users/ageron/dev/roc/roc-examples/examples/AllSyntax/main.roc).
- [iRoc architecture and display conventions](/Users/ageron/dev/roc/iroc/README.md)
  and [Roc formatter](/Users/ageron/dev/roc/iroc/iroc/json-repl-formatter.roc).

| Tested artifact | Identity |
| --- | --- |
| Native `/Users/ageron/dev/software/roc/zig-out/bin/roc` | Reports `release-fast-f8143fbb`; SHA-256 `5b6040dae5e592cb560890062d2acebdde20db8da85e6c85798dceacd177eb59` |
| REPL `/Users/ageron/dev/software/roc/zig-out/lib/repl/repl.wasm` | 49,219,593 bytes; SHA-256 `c9632c31b6fa8c0048499bdb68b4ea22a9e4c2e202d7d006d699e5d5672d131b` |
| Whole-program `/Users/ageron/dev/roc/www.roc-lang.org/website/public/echo.wasm` | 33,195,608 bytes; SHA-256 `8cda67068cbefc132dd3cbc0ee0ec0048014b3449435befcc4c5ba9fc1bcf0e1` |

The probes ran on the local native compiler and WASM instantiated under Node
v25.0.0. They verified language/ABI behavior, not browser rendering, service-worker
operation, complete language compatibility, or performance targets. No compiler,
website, or iRoc source changes were made for these probes.

### Product inspiration

- [marimo](https://docs.marimo.io/): reactive execution, script storage, app export.
- [Pluto reactivity](https://plutojl.org/en/docs/reactivity/): current bindings and
  dependency-aware execution.
- [Observable notebooks](https://observablehq.github.io/documentation/notebooks/):
  interactive exploration and collaborative documents.
- [Livebook](https://livebook.dev/): literate storage and approachable code tools.
- [JupyterLite offline packaging](https://jupyterlite.readthedocs.io/en/stable/howto/configure/advanced/offline.html):
  complete browser dependency distribution.
- [Jupytext](https://jupytext.readthedocs.io/): complementary script and Markdown
  representations.
- [Quarto](https://quarto.org/docs/faq/): publishing computational documents.

These systems inform product choices. Roclet's execution contract comes from Roc
and its own conformance tests, not from copying another language's notebook model.
