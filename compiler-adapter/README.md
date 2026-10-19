# Adapter protocol 1

The browser JavaScript API is `CompilerAdapter.evaluate(snapshot)`; the public shapes
are in `protocol.d.ts`. It receives a complete document snapshot, explicit root
identifiers, and explicit in-memory modules. It does not discover `out_*`
names: that convention belongs to the notebook layer.

The native CLI accepts the same snapshot JSON directly. `snapshot.zig` owns
protocol validation, source concatenation, root requests, and result mapping in
both compiled hosts. The JavaScript wrapper copies requests and checks obvious
input errors before crossing that boundary. It has no separate evaluation loop.
This is compiler-adapter plumbing; document formats and application policy remain
responsibilities of the Roc core.

The adapter concatenates cells without reordering definitions, adds a generated
entrypoint, and checks the entire top-level application through Roc's compiler.
For this milestone it then recompiles the complete snapshot once per selected
root. It declares the runtime consumer before compile-time evaluation and consumes
the same retained lowering session, so unused constants need not execute. Root evaluation uses the compiler's checked lowering and interpreter;
there is no expression evaluator or Roc parser written in JavaScript.

`bridge.zig` and `snapshot.zig` are built unchanged for native and WASM.
The Zig build tool applies `overlay.json`, which adds
small integration hooks to the pinned compiler: report checked definition
metadata, stop after checking, and observe both runtime and compile-time debug output. It also turns
interpreter crashes into returned failures. The overlay also fixes one serialized-offset conversion on the newly exercised
wasm32 path. The hooks do not change Roc syntax
or add notebook naming conventions to the compiler. Upstream's UPL license is
included in `ROC-LICENSE`.

## Ownership and revisions

- Requests are immutable snapshots, copied before the first asynchronous call.
- Request ID, document revision, input revision, and worker generation travel
  with the response. The shell accepts a response only if all four still match.
- Starting a request clears displayed values immediately. An error returns no
  designated values. Values are not retained in the compiler between requests.
- Native calls run in isolated subprocesses. Browser evaluations run in dedicated
  workers. Stop/edit/restart terminates the worker and invalidates its results.
  There is no promise that a synchronous compiler call can interrupt itself.
- `Revision.roc` demonstrates the portable revision policy in both hosts. It is
  not yet the production reducer for the browser shell; M1/M2 will wire the
  document core into the application.

## WASM memory contract

`roclet_alloc(n)` allocates request bytes; `roclet_free(ptr,n)` releases them.
`roclet_process(ptr,n)` returns a separately allocated response: four bytes of
little-endian payload length followed by UTF-8 JSON. Release it with
`roclet_free_response(ptr)`. Zero means allocation/processing failure, never a
valid empty response. The host copies/parses the response before freeing it.
Typed array views are recreated after every call that may grow linear memory.
Requests are processed synchronously and must not overlap within an instance.
Compiler scratch memory is released after each request. No opaque value handles
survive a response. A WASM trap invalidates the entire worker.

## Results and source regions

Definitions come from checked compiler IR, including inferred type strings and
half-open UTF-8 byte spans in the concatenated user source. Generated application
headers and entrypoints are excluded. Cell attribution is a range lookup; it
isn't name inference. `byteOffsetToUtf16` converts these spans for JS editors.
Only simple top-level assignment patterns have metadata in this prototype.

Diagnostics carry the compiler's title, severity, rendered Markdown message,
and optional compiler-provided **1-based display coordinates**. No terminal
text is parsed. Their message includes filenames; the prototype does not yet
normalize multi-file locations to byte spans. Do not treat diagnostic display
columns as UTF-8 byte offsets. Runtime failures may have no location.

Values are inspected text, not structured tables or expandable objects. User
`dbg`, `expect_failed`, and `crashed` observations are separate from designated
values. Events are buffered until execution finishes and tagged with the selected
root. **Originating debug source regions are unavailable in this compiler ABI.**
In a dependency shared by two roots, a debug observation may occur once per root,
because each root is evaluated from scratch.

## Capabilities and bounds

The published `CAPABILITIES` object is the supported scope. There is no resolved
dependency graph, retained checked-revision handle, incremental compilation,
selective invalidation, arbitrary platform, package download, or value inspector.
Module dependencies must be supplied explicitly; the compiler uses an in-memory
filesystem in both hosts. The entrypoint and `echo!` names are reserved by this
prototype. Notebook inputs must be headerless top-level Roc definitions; the
adapter supplies the application header. Duplicate value bindings are rejected using checked definition metadata, even
when Roc classifies redeclaration as a warning. All supplied source is checked, so an
error in an unused definition fails the snapshot.

Output roots must be simple lowercase identifiers with a checked binding. Type
aliases, annotations, recursive functions, and module imports are covered by the
fixtures. Destructuring-root metadata, arbitrary app/platform conversion, foreign
functions, filesystem/network effects, external packages, and trailing-expression
lowering are outside M0. The anonymous-expression fixture contains the already
lowered binding; it does not claim a notebook parser exists.

The source limit is 1 MiB including the generated entrypoint; compiler scratch
space is 256 MiB. A trap, exhaustion, or compiler failure produces an operational
error and clears current values. The native conformance runner enforces a 60-second timeout per subprocess.
The standalone CLI runs until completion or interruption.
The browser offers explicit Stop; automatic CPU budgeting comes later. Pure
notebook roots are the supported input: user calls to the prototype's generated
`echo!` are not a supported output channel.


## M1 document operations

The raw transport also accepts `{ operation: "document", action, format, target,
source, modules?, context? }`. Actions are `parse`, `convert`, `normalize`, `view`,
`export`, `check`, and
`run`; formats are `roc` and `markdown`. `operation: "syntax"` exposes version-pinned
Roc/Markdown syntax facts for adapter tests. The document API uses
`core/Document.roc` in both hosts; it does not duplicate notebook policy in JS.
See [the M1 contract](../docs/m1.md) for the model, map composition, loss-preservation
rules, compiler integration, and larger core-compilation memory budget.

The notebook parsing hook accepts expression statements for analysis; normal Roc
compilation still requires the lowered declarations. The document host executes
one generated entry rather than M0's independent per-root snapshot requests.
Document byte spans are separate from the legacy snapshot diagnostic coordinates.
Compiler diagnostics now retain their source filename when available.

The document core uses a private compiled-program cache and runtime JSON arguments.
Only Roclet's immutable engine program is cached; each call gets a new interpreter,
and user notebook checking/evaluation still compiles its current source. `view`
produces editing text while `export` produces portable canonical source. Markdown
views retain preamble/metadata in the request's optional `context` object.


## M2 draft and reactive evaluation operations

The document API accepts an optional explicit `draft` (preamble, metadata and
ordered cells). Its `compose` action returns editing source while preserving
cell kinds. The returned `draft` avoids duplicating inline saved-output comments
in the output list. `program` contains lowered user definitions only.

`evaluate` checks this program through the existing snapshot adapter and evaluates
selected roots with per-root event attribution; `selectedCell` can restrict the
output selection while retaining module-wide checking. Events include their model
cell index and sequence. Unlike `run`, it does not execute the generated script
entry point. Draft diagnostics have cell-relative offsets and `scope: "cell"`.

`render: true` returns MD4C block/span/text events for Markdown cells. The separate
`{ operation: "markdown", source }` operation exposes the same rendering events.
These are syntax events, never HTML strings to insert into the page.

User observation retention is bounded to 1,000 events/256 KiB, and 64 KiB per
message/result, per root. `truncated` marks omitted content. Roclet's private
document-engine JSON transport is not subject to the user display limit.

## Rich presentation

Snapshot values retain `{ root, text }` and may additionally carry `display`, a
versioned structured value. The bundled nominal `Display` module opts in through
an unaliased import and compiler-checked type; inspected text is never parsed to
infer a renderer. Each root is bound once before obtaining text and wire data.
Text remains available if the bounded rich payload is truncated or rejected.
Notebook evaluation adds Markdown parser events. See [M5](../docs/m5.md) for the
API, limits, trust boundary, script behavior, and snapshot/export contract.

Markdown rendering events include MD4C math spans (inline kind 6, display kind 7,
math text kind 7). The same parser flags apply on native and WASM hosts; browser
rendering uses the locally pinned KaTeX assets. Source serialization is unchanged.
