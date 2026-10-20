# Plan 03: checked-data dependency fingerprints and type edges

## 1. Status

- **Temporary WIP document.** Delete it when the feature lands (see section 11).
- Branch: `integration/compiler-workspace`. Written 2026-10-20 against HEAD `35c3716`.
- Sequencing: independent of `wip/01-typed-engine-pipeline.md` in function, but
  both touch `bridge.zig:analyzeFallible` and `document.zig:dependencyGraph`.
  Coordinate so that one of them lands first and the other rebases; do not run
  them in parallel on the same files. `wip/02-engine-owned-baseline.md` keys its
  retained per-root results on the fingerprints this plan defines, so plan 02
  should consume the `closure fingerprint` defined in section 5.6.
- No change to `compiler-adapter/embedding.patch` is required. Everything this
  plan reads already exists in the pinned compiler (section 5.7).

All `path:line` references below were verified against the files at HEAD.
Compiler paths are relative to `.toolchain/roc` (the prepared pinned checkout).

## 2. Problem statement

Roclet's selective recomputation decides which notebook outputs to re-evaluate by
comparing a *dependency graph* from the previous successful check against the
current one. Today that graph's node fingerprints and its global "context" hash
are computed from **source text**, and several common language features switch
the whole graph into a conservative **module scope** in which any edit
re-evaluates every output. Both facts make the feature disappear exactly in the
notebooks that would benefit most.

### 2.1 Where the fingerprint comes from

`compiler-adapter/document.zig:432-452` (`dependencyGraph`):

- Each definition's fingerprint is `sha256(json([program[region], type]))`, where
  `region` is the byte span of the definition in the generated program (from the
  pattern's name to the end of the expression, see `bridge.zig:238`) and `type`
  is the rendered inferred type (`bridge.zig:232-237`).
- The context is `sha256(every program byte NOT covered by a definition region
  ++ json(modules) ++ workspaceFingerprint)` (`document.zig:448-451`).

`compiler-adapter/document_frontend.zig:740-768` (`plan`):

- Line 746: `global = !known or previous.context != current.context or
  previous.scope != current.scope or (current.scope == "module" and changed.len > 0)`.
- When `global` is true every root is evaluated with the reason
  "Document context changed or no checked baseline" (line 763).

### 2.2 Where the module-scope fallback comes from

`compiler-adapter/bridge.zig:159-270` (`analyzeFallible`) sets
`response.dependency_scope = "module"` (default `"definitions"`, `bridge.zig:73`) when:

| Line | Trigger |
| --- | --- |
| 170 | any user definition whose pattern is not a plain `.assign` (destructuring, `as`, etc.) |
| 179 | any CIR node in the user range tagged `statement_nominal_decl`, `statement_alias_decl`, `statement_where_alias_decl`, `expr_associated_lookup_local`, or `expr_associated_lookup_resolved` |
| 204 | any definition whose name contains `.` (associated items such as `Config.scale = 3`) |
| 211, 258 | any dependency that resolves to a non-`.assign` definition |

The reason for these fallbacks is that the analysis only builds edges from
`can.DependencyGraph.collectNameReferences` (`bridge.zig:206`), which deliberately
does **not** follow `e_lookup_associated_local`/`e_lookup_associated_resolved`
(see `src/canonicalize/DependencyGraph.zig:1700-1710`), and because the graph
has no nodes for types at all, so a type declaration change cannot be attributed
to the values that use it.

### 2.3 Concrete consequences

1. **A comment between two cells invalidates every output.** Cells are joined into
   one program; a line `# note` between `a = 2` and `out_left = a` lies outside
   every definition region, so it enters the context hash and `plan` goes global.
   Same for an added blank line, a trailing comment, or a `# =>` snapshot comment
   that survives into a code cell.
2. **One type declaration removes selectivity from the whole notebook.** Adding
   `Point := { x : F64, y : F64 }` anywhere sets scope to `module`
   (`bridge.zig:179`). From then on `plan` goes global whenever *anything*
   changes (`document_frontend.zig:746`, last clause). The UI tells the user so
   (`web/edit.mjs:324`), but the only remedy is to delete the type.
3. **An annotation edit invalidates unrelated roots.** `width : U64` is not inside
   `width`'s definition region (region starts at the pattern name on the next
   line), so changing it to `width : U32` changes the context hash, not
   `width`'s fingerprint. Every root re-evaluates, including ones that never
   mention `width`.
4. **Any supplied/imported module change invalidates everything.** `json(modules)`
   is in the context (`document.zig:450`), so `tests/m4-workloads.json`
   `import-change` expects `out_other` (which never touches the module) to be
   re-evaluated.
5. **Destructuring (`(a, b) = pair`) and associated items (`Config.scale`)** each
   flip the notebook to module scope for the lifetime of the document.

The adapter already admits this in its capability string:
the former M0 capability string `dependencyPrecision: 'compiler name references; conservative module fallback for types/dispatch'` (in the now-deleted `compiler-adapter/adapter.mjs`),
and `docs/m4.md:13-20` documents the textual fingerprint and the fallbacks.

## 3. Why it matters

- Selective evaluation is the product's core promise ("cells follow their
  dependencies"). A notebook with one nominal type, one destructuring binding, or
  one associated item silently loses it, and the user cannot tell why beyond a
  footnote in the dependency dialog.
- The textual context hash makes the most harmless edits (comments, whitespace,
  annotations) the most expensive ones. Those edits are frequent during
  explanation-writing, which is exactly when a notebook has many expensive roots.
- Since whole-module checking happens on every edit anyway, the compiler has
  already computed the exact facts needed: an exact strict-demand relation
  between top-level definitions (section 5.7), resolved type references inside
  annotations and constructions, and deep content identities for imported
  modules. Re-deriving a weaker version from text is both slower to maintain and
  wrong more often.
- `wip/02-engine-owned-baseline.md` wants to retain per-root results keyed on a
  fingerprint. A fingerprint that changes on whitespace edits would make that
  retention almost useless.

Nothing in this plan changes evaluation results. The `tests/m4.zig` harness
(`tests/m4.zig:49-63`) already enforces that selective presentation equals a
clean full run for every workload; that stays the hard gate.

## 4. Current design walkthrough

1. `document.zig:224-233` runs a check-only snapshot evaluation of the generated
   program. The bridge's `analyze` callback (`bridge.zig:154`) walks the checked
   app module (`analyzeFallible`, `bridge.zig:159-270`) and emits, per plain
   `.assign` definition in the user byte range: `name`, rendered `type`,
   `region` (pattern start → expression end, program-relative), `name_region`,
   `dependencies` (names of referenced `.assign` defs, from
   `collectNameReferences`), `references` (occurrence spans for rename) and
   `rename_safe`. Top-level `expect` roots are appended as definitions with
   `type: "Bool"` (`bridge.zig:247-270`). `dependency_scope` is set as in 2.2.
2. `snapshot.zig:151` copies `dependency_scope` through; `document.zig:236-238`
   turns definitions into the `graph` JSON (`document_frontend.zig:32-33`
   `Definition{name, fingerprint, dependencies}` and `Graph{context, scope,
   definitions}`).
3. `document.zig:239-250` builds a `Reactive` input (`document_frontend.zig:34`)
   with `previous` (sent by the client or injected from `bridge.previous_graph`)
   and `current`, then `plan` (`document_frontend.zig:740-768`) computes `changed`
   via `definitionEqual` (fingerprint + dependency list equality, lines 725-739),
   the transitive dependency closure per root (lines 751-761), and the decision
   per root (line 763).
4. The JS notebook, `tests/m4.zig`, `web/m4-conformance.mjs` and
   `tests/workspace-benchmark.mjs:18` all send `reactivity.previous` as the whole
   previous graph object; `web/edit-model.mjs:240-241` reads
   `graph.definitions[].name` for rename validation; `web/edit.mjs:318` reads
   `graph.definitions[].dependencies` for the dependency dialog; `web/edit.mjs:324`
   shows a note when `graph.scope === 'module'`.

What is checked data today: the dependency edges (name references) and the type
string. What is textual: the per-definition fingerprint and the entire context.
What is absent: types as nodes, annotations as part of a definition, associated
items and dispatch as edges, imported modules as nodes.

## 5. Target design

### 5.1 Graph version 2

```jsonc
{
  "version": 2,
  "context": "<sha256 hex>",                 // section 5.5
  "scope": "definitions" | "module",          // section 5.8; "module" becomes rare
  "definitions": [                            // value definitions + expect roots, as today
    { "name": "area", "binders": ["area"], "fingerprint": "<hex>",
      "dependencies": ["width", "height", "Point", "module:Geometry"] }
  ],
  "types": [                                  // NEW: local type declarations
    { "name": "Point", "fingerprint": "<hex>", "dependencies": ["Meters", "Point.origin"] }
  ],
  "modules": [                                // NEW: imported module identities
    { "name": "module:Geometry", "fingerprint": "<64 hex of deep content identity>" }
  ]
}
```

- `definitions` keeps its current shape so `web/edit-model.mjs:240` and
  `web/edit.mjs:318` keep working. `binders` is new: for destructuring
  definitions it lists every bound name; `name` is the first binder. Dependencies
  may name any binder; `plan` resolves a binder to its node.
- Node namespaces do not collide: value names start lowercase (or contain `.` for
  associated items), type names start uppercase, module nodes are prefixed
  `module:`. `plan`'s closure walk treats `definitions ∪ types ∪ modules` as one
  node set.
- `version` lets `plan` reject a mismatched baseline (`previous.version !=
  current.version` → global, reason "Graph format changed").

The Zig side extends `document_frontend.zig:32-33`:

```zig
pub const Node = struct { name: S, binders: []const S = &.{}, fingerprint: S, dependencies: []const S = &.{} };
pub const Graph = struct { version: u32 = 2, context: S = "", scope: S = "definitions",
    definitions: []const Node = &.{}, types: []const Node = &.{}, modules: []const Node = &.{} };
```

`definitionEqual` (`document_frontend.zig:725`) compares nodes across all three
lists by name; `plan`'s closure loop (`document_frontend.zig:757`) iterates all
three lists.

### 5.2 Edges

| From | To | Source of truth in the checked module |
| --- | --- | --- |
| value def → value def | `ModuleEnv.topLevelDemandDependencies()` (`src/canonicalize/ModuleEnv.zig:1617`): the exact strict-demand relation stored on the env, produced by canonicalization (`src/canonicalize/Can.zig:5137-5150`) and **replaced after checking** with resolved literal-dispatch targets (`src/check/Check.zig:12213`, `finalizeTopLevelDemandDependencies`). It includes associated items (they are ordinary members of `all_defs`, see `DependencyGraph.zig:7-12`) and local method targets (`collectNameReferences` resolves `e_type_method_call`/`e_type_dispatch_call` owners through `lookupMethodBindingForOwnerConst`, `DependencyGraph.zig:1536-1548`; the demand analyzer uses the same walk). This replaces Roclet's own `collectNameReferences` call at `bridge.zig:206`. Section 10 lists the verification required before relying on it. |
| value def → type | (a) the def's annotation: `Def.annotation` (`src/canonicalize/CIR.zig:385`) → `Annotation.anno` (`CIR.zig:594`) → walk the `TypeAnno` tree (`src/canonicalize/TypeAnnotation.zig:21-87`); every `.lookup`/`.apply` whose `base` is `.local { decl_idx }` (`TypeAnnotation.zig:318-322`) is an edge to that type declaration statement; (b) body constructions: `e_nominal.nominal_type_decl` (`src/canonicalize/Expression.zig:336-340`), `e_type_method_call.type_dispatch_stmt` (`Expression.zig:481-486`), pattern `.nominal.nominal_type_decl` (`src/canonicalize/Pattern.zig:73-77`); (c) `where` clauses on the annotation (`CIR.zig:504-520`) contribute whatever type lookups their method signatures contain. |
| type → type | the declaration's `anno` (`s_alias_decl`/`s_nominal_decl`, `src/canonicalize/Statement.zig:180-192`) walked the same way; `s_where_alias_decl` (`Statement.zig:202-206`) through its `where` span. |
| type → associated item defs | every def whose name is `TypeName.item` is listed as a dependency of the type node `TypeName`. This makes "the type and all its methods" one closure, which section 5.8's dispatch rule relies on. |
| value/type → module | every `.external`/`.external_identity` type base (`TypeAnnotation.zig:323-335`), `e_lookup_external.module_idx` (`Expression.zig:178-183`), `e_nominal_external.module_idx` (`Expression.zig:349-351`), `e_lookup_associated_resolved.module_identity` (`Expression.zig:216-221`) and pattern `.nominal_external` (`Pattern.zig:87-92`) becomes an edge to `module:<display name>`. Resolve a `CIR.Import.Idx` with `env.importIdentity(idx)` (`ModuleEnv.zig:5538`) and a `ModuleIdentity.Idx` with `env.moduleIdentityHash(idx)` (`ModuleEnv.zig:5568`) / `moduleIdentityDisplayText` (`ModuleEnv.zig:5582`). |

The `TypeAnno` walker is small and exhaustive over 12 variants (`apply`,
`rigid_var`, `rigid_var_lookup`, `underscore`, `lookup`, `tag_union`, `tag`,
`tuple`, `record`, `fn`, `parens`, `malformed`) using `store.getTypeAnno`
(`src/canonicalize/NodeStore.zig:2824`), `sliceTypeAnnos` (`NodeStore.zig:5370`),
`sliceAnnoRecordFields`/`getAnnoRecordField` (`NodeStore.zig:5404`, `2979`).
Record fields with `default_value` (`TypeAnnotation.zig:296-313`) also contribute
the default expression's references; walk it with the same demand walker, or
conservatively hash it into the type node fingerprint (recommended default: the
decl's token stream already includes the default expression text, so no extra
edge work is needed; its *references* to other defs are captured because the
demand relation follows omitted defaults, `DependencyGraph.zig:1646-1657`).

### 5.3 Node fingerprints

Two options were investigated. **Option A is the recommended default.**

**Option A: parser token stream + inferred type (recommended).**

```
def fingerprint  = sha256("roclet-def-v2" ‖ tokens(annotation stmt) ‖ tokens(def stmt) ‖ rendered inferred type)
type fingerprint = sha256("roclet-type-v2" ‖ tokens(type decl stmt))
```

- `tokens(span)` = for each token of `syntax.roc(a, program[span])`
  (`compiler-adapter/syntax.zig:15`), the token tag name and, for identifier,
  number, string-part and similar text-bearing tags, the token text. Each item is
  length-prefixed (`workspace.hashField`, `compiler-adapter/workspace.zig:490`).
  Token offsets are **not** hashed. The tokenizer drops comments and whitespace
  (`src/parse/tokenize.zig:791` "Chomps trivia"), so those edits leave the
  fingerprint unchanged by construction.
- The annotation span comes from the checked module: `Def.annotation` →
  `store.getAnnotationRegion` (`NodeStore.zig:1092`). The analysis exposes it as a
  new `annotation_region` field (section 7, step 1). For `s_type_anno`
  statements that were not merged into a def (`Statement.zig:217-221`, rare at
  top level) treat the statement as context.
- The inferred type stays the `.one_line` rendering already produced at
  `bridge.zig:232-234` with a fresh `TypeWriter` per definition
  (`engine.zig:752-757`); naming counters start at zero per writer
  (`src/types/TypeWriter.zig:291-292`), so the string is a function of the
  definition's type structure only. It is retained because the *type* of a
  definition can change without its own tokens changing (a dependency changed),
  and a root whose dependency closure includes that definition must re-run; the
  closure already covers that, but keeping the type makes `changed` explanations
  precise and protects against any edge the demand relation might omit.
- Why not raw CIR: see Option B.

**Option B: structural hash of the checked CIR.** Hash the canonical checked form
of a definition: node kinds, resolved identifier texts, literal values, pattern
shapes and type-annotation shapes reachable from `Def.pattern`, `Def.expr` and
`Def.annotation`, with all regions/offsets/indices excluded. Two ways exist:

1. Reuse the compiler's S-expression printer (`CIR.Def.pushToSExprTree`,
   `src/canonicalize/CIR.zig:415`) into a `base.SExprTree` and hash its node list
   skipping `BytesRange` and `NodeIdx` entries (`src/base/SExprTree.zig:140-148`).
   Risk: some printers push raw store indices as plain unsigned integers (e.g.
   `type-dispatch-stmt` at `src/canonicalize/Expression.zig:1442`), which are
   indistinguishable from literal integers in the tree and change whenever an
   unrelated node is inserted earlier in the store. That produces false
   invalidations (safe, but defeats the purpose) unless every such site is
   audited per compiler pin.
2. Write a dedicated walker. It must be exhaustive over the ~80 `Expr` variants
   (compare `collectNameReferences`, `DependencyGraph.zig:1521-1718`, ~200 lines
   for references alone), plus patterns, statements and type annotations, and be
   re-audited on every compiler pin bump.

Option B is more "semantic" (it would notice a reference resolving to a
different target with identical spelling), but every such case is already
covered by the dependency edges and the context (an import or header change is
in the context; a local name cannot be shadowed at top level). Given the
maintenance cost and the index-leak risk, Option A is the default; Option B is
recorded here so the implementer can escalate if a measured false-invalidation
case appears that tokens cannot distinguish.

### 5.4 Node identity and multi-binder definitions

- A plain `.assign` def's node name is its identifier (unchanged).
- A destructuring def (`(a, b) = pair`, `{ x, y } = point`) gets one node named
  after its first binder with `binders: ["a", "b"]`; binders come from
  `can.DependencyGraph.appendPatternBinders` (`DependencyGraph.zig:1357`), which
  the analysis already calls (`bridge.zig:166`). References from other defs are
  edges to the def node, exactly as the compiler's own `pattern_to_def` mapping
  works (`DependencyGraph.zig:1398-1418`). `bridge.zig:170` and `211` fallbacks are
  removed.
- An associated item def `Config.scale = 3` is a node named `Config.scale`
  (`bridge.zig:204` fallback removed) and is also listed as a dependency of the
  type node `Config` (section 5.2).
- Defs with no binder (`_ = expr`, statement defs: `Def.Kind.stmt/.ignored`,
  `CIR.zig:388-394`) cannot be referenced and are not roots. Hash their token
  stream into the context so that editing them still re-runs everything (they
  may crash at compile time); they get no node.
- Expect roots keep their synthetic names (`roclet_expect_N`, from
  `document_frontend.zig:667`) and `type: "Bool"`; their edges switch to the
  demand relation of the `s_expect` body like values (today `bridge.zig:254`).
  The demand relation does not cover statement roots, so expect bodies keep
  using `collectNameReferences` plus the type/module walkers of 5.2.

### 5.5 Context

```
context = sha256("roclet-context-v2"
  ‖ compiler identity            (workspace.identity, compiler-adapter/workspace.zig:9)
  ‖ tokens(app header)           (program preamble up to facts.header_end)
  ‖ tokens(each import / file_import statement, program order)
  ‖ tokens(each unmerged s_type_anno and each binder-less def, program order)
  ‖ rich_support flag            (display_module, bridge.zig:365-375)
  ‖ workspaceFingerprint         (document.zig:236, covers /workspace files and /bundles))
```

Explicitly **not** in the context any more: uncovered program bytes (comments,
whitespace, blank lines), type declarations (now nodes), annotations (now part of
their def), supplied module contents (`json(modules)`; modules are now nodes
whose fingerprint is the deep content identity hash computed by
`ModuleEnv.ensureContentIdentity`, `src/canonicalize/ModuleEnv.zig:5616-5646`,
= H(module name, source, direct import identities), which is therefore
transitively sensitive).

Note on `workspaceFingerprint`: it still covers every `/workspace/*` and
`/bundles/*` file (`workspace.zig:23-47`), so a project-file edit remains a
global invalidation after this plan. Narrowing that to module nodes is a natural
follow-up (the module identity already exists for those files) but is out of
scope here; `import-change` with `modules` (in-memory supplied modules) is in
scope.

### 5.6 Closure fingerprint (for plan 02)

`closureFingerprint(root) = sha256(context ‖ sorted (name ‖ fingerprint) of every node in root's transitive dependency closure)`.
Plan 02 keys a retained result on this value; `plan` can compute it alongside
`explanations` so both consumers agree. It must be deterministic across
native and WASM (token tags and hashes are), which the parity suites verify.

### 5.7 What the compiler already provides (no patch change)

| Need | Available API (pinned compiler) |
| --- | --- |
| exact def→def edges incl. associated items and local dispatch | `ModuleEnv.topLevelDemandDependencies()` (`ModuleEnv.zig:1617`, asserts `top_level_demand_dependencies_ready`, `ModuleEnv.zig:1623`); entries are `DependencyGraph.Dependency{dependent, dependency}` (`DependencyGraph.zig:80-85`), sorted and de-duplicated (`DependencyGraph.zig:172-212`) |
| all local type declarations | `ModuleEnv.type_decls: CIR.Statement.Span` (`ModuleEnv.zig:959`); name via `store.getTypeHeader(header).relative_name` (`CIR.zig:466-475`) |
| type references inside annotations | `TypeAnno.LocalOrExternal` (`TypeAnnotation.zig:318-350`) |
| annotation span | `store.getAnnotationRegion` (`NodeStore.zig:1092`), `getTypeAnnoRegion` (`NodeStore.zig:1086`), `getStatementRegion` (`NodeStore.zig:1080`) |
| imported module identity | `importIdentity`, `moduleIdentityHash`, `moduleIdentityDisplayText` (`ModuleEnv.zig:5538-5587`) |
| binders of destructuring defs | `appendPatternBinders` (`DependencyGraph.zig:1357`) |

Therefore `compiler-adapter/embedding.patch` is untouched by this plan. If the
verification in section 10 (demand relation soundness for callbacks) fails, the
fallback is to keep `collectNameReferences` for value→value edges and add only
the type/module walkers; that still removes fallbacks 2.2/179 and the textual
context, and only leaves associated items conservative.

### 5.8 Remaining conservative behaviour

After this plan, `scope: "module"` is produced only when the analysis cannot
build a trustworthy graph:

1. `topLevelDemandDependenciesReady()` is false for the app module (should not
   happen after a successful check; defensive).
2. A def references a type whose `LocalOrExternal` is still `.pending`
   (`TypeAnnotation.zig:336-345`), i.e. import resolution did not settle it. A
   successful check should never leave this state; defensive.

Dynamic dispatch (`e_method_call`, `e_dispatch_call`, `e_type_dispatch_call` with
`.dispatcher` owner) does **not** fall back to module scope: a def containing
such a call gets edges to **every local type node** (whose closure includes all
associated-item defs via 5.2) and to **every module node** it references.
That is conservative but local to the dispatching def's dependents. Builtin
method targets are covered by the compiler identity in the context.

### 5.9 Expected invalidation behaviour

| Edit | Re-evaluated roots |
| --- | --- |
| comment, blank line or whitespace anywhere in a code cell | none |
| markdown cell edit | none (already true: not in program) |
| reorder two definitions or two cells | none |
| change a definition body | roots whose closure contains it |
| change a definition's annotation | roots whose closure contains that definition |
| add an unused type declaration | none |
| change a type declaration | roots whose closure contains the type (annotated with it, constructing it, matching it, calling its methods) |
| change an associated item (`Config.scale = 4`) | roots referencing `Config.scale`, plus roots dispatching dynamically (5.8) |
| change a destructuring def's RHS | roots using any of its binders |
| change a supplied/imported module | roots whose closure reaches `module:<name>` |
| app header (packages, platform), import list, compiler version, project files | all |
| definition added or removed | roots whose closure changes (removed dependency → that root; a new def nobody references → none). Note: today's `deleted-definition` workload yields `status: diagnostic` because a reference dangles; that stays a module-wide diagnostic. |

## 6. Constraints and non-goals

- **Correctness gate is unchanged**: for every workload, the selective run's
  presentation values must equal a clean full run (`tests/m4.zig:49-63`). Any
  precision gain that breaks this is a bug, not a trade-off.
- No cell-order inference. Cells remain editing boundaries only (`docs/m4.md:4-6`).
- No text scraping of diagnostics or rendered types to infer structure; the only
  textual input is the tokenizer output of definition spans (section 5.3).
- No new compiler fork and no addition to `embedding.patch` (section 5.7).
- Graph JSON shape changes (section 5.1) are allowed but must be versioned
  (`version: 2`) and documented in `compiler-adapter/protocol.d.ts` and
  `compiler-adapter/README.md`. A mismatched baseline degrades to global
  invalidation, never to a wrong reuse.
- `plan.explanations` must stay meaningful: `reason` strings may now name types
  and modules (`Changed: Point`, `Changed: module:Geometry`).
- The UI is out of scope beyond keeping `web/edit.mjs:318/324` and
  `web/edit-model.mjs:240-241` working with the new shape; UX for showing type
  dependencies is a separate change.
- Project-file (`/workspace/*`) changes remain global (section 5.5 note).
- Performance: the analysis must not get slower than today's O(defs × nodes)
  occurrence scan (`bridge.zig:215-231`, untouched by this plan but see
  `wip/01-typed-engine-pipeline.md`); the new walkers are linear in the number
  of nodes reachable from annotations and type declarations.

## 7. Step-by-step implementation plan

Each step leaves `zig build test` green (it runs unit, workspace, native,
document and M4 suites, `build.zig:118-123,137,153`).

**Step 1 — Expose the extra checked facts (bridge.zig, protocol.d.ts).**
Extend `Definition` (`bridge.zig:32-41`) with `annotation_region: ?Region`,
`binders: []const []const u8`, `type_dependencies: []const []const u8`,
`module_dependencies: []const []const u8`, `dynamic_dispatch: bool`. Add
`types: []const TypeDecl{name, region, dependencies, associated}` and
`modules: []const Module{name, identity}` to `Response` (`bridge.zig:65-75`) and
`serialize` (`bridge.zig:275-291`). Add the `TypeAnno` walker and the
expression/pattern scans for nominal constructions and external lookups.
Keep `dependency_scope` computed exactly as today. Thread the new fields through
`snapshot.zig` `RawResponse`/`Result` (`snapshot.zig:35-41`, `64-81`) as opaque
JSON values (`std.json.Value`) so the snapshot layer stays shape-agnostic.
Tests: existing suites (parity compares native vs WASM, both produce the new
fields); add a Zig test in `bridge.zig` or a `tests/documents.json` case that
asserts `types`/`module_dependencies` for a small notebook.
Doc: add the fields to `protocol.d.ts` `Definition` (line 44-55) and `Response`.

**Step 2 — Graph v2 nodes with today's fingerprints (document.zig, document_frontend.zig).**
Introduce `Node`/`Graph v2` (section 5.1). Build `types` and `modules` lists and
the new edges. Keep the def fingerprint textual for this step but extend the
region to start at `annotation_region.start` when present. Keep the context as
today. Update `plan` and `definitionEqual` to walk all node lists and binders;
add the `version` check. Update `reactivity.previous` consumers only where they
construct a placeholder graph: `web/edit-model.mjs:167-168`,
`tests/workspace-benchmark.mjs:18`, `web/m4-conformance.mjs` (grep
`scope:'module',definitions:[]`) to include `version:2, types:[], modules:[]`
(or make `plan` tolerate missing arrays; recommended: tolerate, with `known:false`
semantics when `version` is absent).
Tests: existing M4 expectations unchanged (context still textual, scope still
set); add frontend unit tests next to `document_frontend.zig:813-841` for
type→value closure and binder resolution.

**Step 3 — Token-stream fingerprints and structured context.**
Replace `digest(json([slice, type]))` with Option A (section 5.3) for definitions
and types; replace the uncovered-bytes context with section 5.5. Remove
`json(modules)` from the context only in step 5. Add the new M4 workloads
`comment-between-defs`, `blank-line-edit`, `reorder-unrelated-defs`,
`annotation-change-leaf`, `alias-change` (section 8.2). Gate: `zig build test-m4`
green including selective == full for all.

**Step 4 — Value edges from the demand relation; multi-binder and associated nodes.**
Replace the `collectNameReferences` call at `bridge.zig:206` with a lookup into
`env.topLevelDemandDependencies()` filtered to user-range defs. Keep
`collectNameReferences` behind a `std.debug` cross-check during this step: assert
`nameRefs(def) ⊆ demandDeps(def) ∪ (defs only reachable through uncalled
lambdas)`; simpler and recommended: run both, and if `nameRefs(def)` contains a
def that `demandDeps(def)` does not, take the union and count it in a new
`workspaceCache.demand_union_fallbacks` counter so the discrepancy is visible in
tests (expected to stay 0 for the workloads; see section 10). Emit nodes for
destructuring defs and associated items; delete the fallbacks at
`bridge.zig:170`, `204`, `211`, `258`. Add workloads `destructuring-change`,
`associated-item-change`, `higher-order-callback`, `recursive-function` (exists).
Gate: all M4 workloads selective == full; `demand_union_fallbacks == 0`.

**Step 5 — Module nodes.**
Emit `modules` nodes with deep identity fingerprints, drop `json(modules)` from
context, change the `import-change` workload expectation to
`evaluate: ["out_import"], reused: ["out_other"]`, add `import-unrelated-module`.
Gate: M4 green; `web/m4-conformance.html` parity.

**Step 6 — Retire the type/dispatch scope fallback.**
Delete the `statement_*_decl`/`expr_associated_lookup_*` triggers at
`bridge.zig:179`; implement the dynamic-dispatch rule (5.8). `scope` stays in the
JSON; it is `"definitions"` unless 5.8 (1)/(2) applies. Add workloads
`nominal-type-added-unrelated`, `nominal-type-changed-dependents-only`,
`dynamic-dispatch-conservative`. Update `web/edit.mjs:324` text to say the graph
could not be fully resolved (it now only shows in defensive cases).

**Step 7 — Docs and cleanup** (section 11).

Steps 1-2 and 3-6 can be two PRs. Do not merge step 4 without the section 10
verification evidence recorded in `docs/m4.md`.

## 8. Validation

### 8.1 Commands

```sh
zig build test                     # unit + workspace + fixture + native + documents + m4
zig build test-m4                  # selective-vs-full workloads only (fast loop while iterating)
zig build test-documents
node --test tests/workspace.test.mjs
node tools/browser-check.mjs --page web/m4-conformance.html
node tools/browser-check.mjs --page web/document-conformance.html
node tools/browser-check.mjs --page web/workspace-conformance.html
node tools/browser-check.mjs --page web/edit-ui-conformance.html   # rename/dependency dialog still work
node tools/browser-check.mjs --page web/workspace-benchmark.html --timeout 180000   # record before/after worker ms
```

`tests/m4.zig` compares `plan.evaluate`/`plan.reused` with the workload's
expected lists **as JSON strings**, so order matters: `plan` iterates
`input.roots` in document order (outputs first, in cell order, then expect roots;
`document.zig:205-208`). Write expectations in that order.

### 8.2 New workloads for `tests/m4-workloads.json`

Each entry: `{name, before, after, evaluate, reused}` (+ `modules`/`afterModules`).
All `before` documents must evaluate with `status: "ok"`.

| name | before | after | evaluate | reused |
| --- | --- | --- | --- | --- |
| comment-between-defs | `# %%\na = 2\nout_left = a\n# %%\nb = 7\nout_right = b\n` | insert `# note\n` after `a = 2\n` | `[]` | `["out_left","out_right"]` |
| blank-line-edit | same before | insert an empty line after `b = 7\n` | `[]` | `["out_left","out_right"]` |
| reorder-unrelated-defs | `# %%\na = 2\nb = 7\nout_left = a\nout_right = b\n` | swap the `a = 2` and `b = 7` lines | `[]` | `["out_left","out_right"]` |
| annotation-change-leaf | `# %%\nwidth : U64\nwidth = 5\nout_w = width\n# %%\nout_other = 7\n` | `width : U32` | `["out_w"]` | `["out_other"]` |
| alias-change | `# %%\nMeters : F64\nd : Meters\nd = 5\nout_d = d\n# %%\nout_other = 7\n` | `Meters : Dec` | `["out_d"]` | `["out_other"]` |
| nominal-type-added-unrelated | `# %%\nout_a = 1\n# %%\nout_b = 2\n` | prepend `Point := { x : F64, y : F64 }\n` to cell 1 | `[]` | `["out_a","out_b"]` |
| nominal-type-changed-dependents-only | `# %%\nPoint := { x : F64, y : F64 }\np = Point.{ x: 1, y: 2 }\nout_p = p\n# %%\nout_other = 7\n` | `Point := { x : Dec, y : F64 }` | `["out_p"]` | `["out_other"]` |
| destructuring-change | `# %%\npair = (1, 2)\n(a, b) = pair\nout_sum = a + b\n# %%\nout_other = 7\n` | `pair = (1, 3)` | `["out_sum"]` | `["out_other"]` |
| associated-item-change | `# %%\nConfig := [].{ scale = 3 }\nout_scaled = 2 * Config.scale\n# %%\nout_other = 7\n` | `scale = 4` | `["out_scaled"]` | `["out_other"]` |
| higher-order-callback | `# %%\na = 2\nf = \|x\| x + a\nout_mapped = List.map([1, 2], f)\n# %%\nout_other = 7\n` | `a = 3` | `["out_mapped"]` | `["out_other"]` |
| dynamic-dispatch-conservative | `# %%\nShape := [Circle(F64)].{ area = \|s\| match s { Circle(r) => r * r } }\ns = Shape.Circle(2)\nout_area = s.area()\n# %%\nout_other = 7\n` | change the method body to `r * r * 3` | `["out_area"]` | `["out_other"]` |
| import-change (update existing) | as today | as today | `["out_import"]` | `["out_other"]` |
| import-unrelated-module | `# %%\nimport Fresh\nimport Other\nout_import = Fresh.value\n# %%\nout_other = Other.value\n` with two modules | change `Other` only | `["out_other"]` | `["out_import"]` |

If a workload's `before` does not type-check with the pinned compiler (syntax
for destructuring or associated items may differ), adjust the source but keep
the intent; record the final source in `docs/m4.md`. The existing
`lambda-dependency`, `no-change`, `rewire`, `type-change`, `deleted-definition`,
`added-definition`, `apparent-cell-cycle`, `isolated-runtime-error`,
`recursive-function` workloads keep their expectations.

### 8.3 Unit tests

- `document_frontend.zig`: `plan` with `types` and `modules` nodes; binder
  resolution (`dependencies: ["b"]` reaches node `a` with `binders ["a","b"]`);
  version mismatch → global.
- `document.zig` (or a new `fingerprint.zig`): token fingerprint equality for
  `a = 1 # c` vs `a=1`, inequality for `a = 1` vs `a = 2`, and for
  `x : U64\nx = 1` vs `x : U32\nx = 1`.
- `bridge.zig`: for a fixture with a nominal type, an annotation and an external
  lookup, assert `types[].name`, `definitions[].type_dependencies`,
  `definitions[].module_dependencies`, `annotation_region`, `binders`.

### 8.4 Parity and benchmark

Browser parity pages replay the native responses in WASM and compare with
`compilerSemantics` (`tests/harness.mjs:13-18`), which keeps `graph` and `plan`,
so any native/WASM hash divergence fails there. Record `workspace-benchmark`
worker ms before and after; the Wall Area and module-edit workloads must show
`frontend_builds: 1, lowerings: 1` as today and no measurable regression.

## 9. Acceptance gates

- [ ] `zig build test` green; every M4 workload (existing + section 8.2) passes
      selective == full value equality and exact `evaluate`/`reused` lists.
- [ ] A notebook containing a nominal type declaration and one unrelated edit
      evaluates only the changed root's dependents (`nominal-type-added-unrelated`,
      `nominal-type-changed-dependents-only`).
- [ ] Comment, blank-line and reorder edits evaluate zero roots.
- [ ] Annotation and alias changes evaluate only dependents.
- [ ] Destructuring and associated-item notebooks never produce `scope: "module"`.
- [ ] `import-change` evaluates only `out_import`.
- [ ] `workspaceCache.demand_union_fallbacks` (step 4) is 0 for all workloads, or
      the discrepancy is documented and the union kept.
- [ ] Browser parity pages (`m4`, `document`, `workspace`, `edit-ui`) green;
      rename (F2) and the dependency dialog still work.
- [ ] No change to `compiler-adapter/embedding.patch`.
- [ ] `grep -n "module" compiler-adapter/bridge.zig` shows `dependency_scope =
      "module"` only for the two defensive conditions in 5.8.
- [ ] `protocol.d.ts`, `compiler-adapter/README.md`, `docs/m4.md`,
      `docs/compiler-workspace.md` updated.
- [ ] Benchmark worker time not slower than the recorded baseline.

## 10. Risks, open questions, deferred decisions

1. **Is the strict-demand relation sufficient for reactivity?** It is the
   compiler's own ordering relation for compile-time evaluation
   (`ModuleEnv.zig:1035-1041`: "exact strict-demand edges... durable producer
   output consumed by checked-root scheduling and CTFE"), so anything evaluated
   while evaluating a root must be in the root's transitive demand, otherwise
   CTFE itself would be wrong. Roclet needs exactly "what a root evaluates". The
   one place to verify is lambdas passed to builtins or to other functions
   (`higher-order-callback`) and defaults materialized by nominal construction
   (`DependencyGraph.zig:1646-1657`). The step 4 union counter makes any gap
   visible. Default decision: switch to the demand relation; if the counter is
   non-zero for a legitimate case, keep the union permanently and document it.
2. **Token-stream fingerprint blind spots.** Same tokens resolving differently
   can only come from a changed import/exposing list, header, compiler, or
   project file; all are in the context. If the implementer finds a case where
   two different programs produce identical def tokens, identical context and a
   different value, escalate to Option B (5.3). Decision deferred, default A.
3. **Type string stability.** Rendering uses a fresh `TypeWriter` per def
   (`engine.zig:752-757`), so flex-variable names depend only on the def's type
   structure. If a compiler pin changes rendering, every fingerprint changes once
   (global re-evaluation on first edit) — acceptable; the compiler identity is in
   the context anyway.
4. **Unmerged `s_type_anno` and binder-less defs** are hashed into the context
   (5.4, 5.5). Rare at top level; revisit if users write standalone annotations.
5. **Record field defaults in nominal declarations** (`TypeAnnotation.zig:306-313`)
   contain expressions. Their tokens are in the type node's fingerprint and their
   references are in the demand relation of constructing defs; no separate edge
   from the type node to the default's references is planned. If a default
   references a def that changes, constructing defs re-run through the demand
   relation (`collectNameReferences` follows omitted defaults; verify the demand
   analyzer does too by a workload: `Point := { x : F64, y : F64 ?? base }`,
   change `base`).
6. **Where-alias declarations** (`s_where_alias_decl`) are rare; they become type
   nodes with edges from the signatures' type lookups. If walking `WhereClause`
   proves awkward (`CIR.zig:504-520`), hash the statement tokens and treat any
   def whose annotation has a `where` span as depending on all where-alias nodes.
7. **Interaction with the compiler artifact cache.** None: cache keys are
   compiler-authored (`src/compile/cache_key.zig:27-58`) and unrelated to this
   graph. The graph is recomputed from the checked env on every request.
8. **Interaction with plan 01.** If plan 01 lands first, the analysis moves to a
   typed `Analysis` struct; implement step 1's fields there instead of in
   `bridge.Response`. If this plan lands first, plan 01 carries the fields over.
9. **Interaction with plan 02.** Expose `closureFingerprint` (5.6) from `plan`
   so plan 02 does not re-derive it.
10. **Associated-item node naming.** `Config.scale` contains a dot; `plan`'s
    closure walk is name-based and `rename` (`web/edit-model.mjs:240`) compares
    sorted names, so dotted names are safe. The frontend's own `out_*` output
    name allocation (`document_frontend.zig:646-654`) never produces dots.

## 11. Cleanup

When complete:

- Remove: uncovered-bytes context and `digest(json([slice, type]))` in
  `document.zig:424-452`; the `dependency_scope` triggers at `bridge.zig:170`,
  `179`, `204`, `211`, `258`; the `collectNameReferences` call for value defs
  (`bridge.zig:206`) if the step 4 counter stayed 0; the placeholder-graph
  literals `{context:'',scope:'module',definitions:[]}` in
  `web/edit-model.mjs:167-168` and `tests/workspace-benchmark.mjs:18` (plan 02
  removes `reactivity.previous/current` altogether; until then they carry
  `version: 2`).
- Update docs: `compiler-adapter/README.md` (reactivity paragraph, add graph v2),
  `docs/m4.md:13-20` (fingerprint description and the conservative-invalidation
  sentence), `docs/compiler-workspace.md` (one sentence under "What changed"),
  `compiler-adapter/protocol.d.ts:151-155` (`DependencyGraph` v2) and
  `Definition` (lines 44-55), 
  `web/edit.mjs:324` note text.
- Record the final workload sources and the step 4 verification result in
  `docs/m4.md`.
- Delete `wip/03-checked-dependency-graph.md`.
