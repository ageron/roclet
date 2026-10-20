/** Versioned, bounded rich presentation. Decimal/integer cells remain strings. */
export interface DisplayValue {
  version: 1;
  kind: 'text' | 'markdown' | 'table' | 'image';
  text: string;
  content?: string;
  mime?: 'image/png' | 'image/jpeg' | 'image/webp';
  columns?: string[];
  rows?: string[][];
  row_count?: number;
  column_count?: number;
  events?: { event: 'block_start' | 'block_end' | 'span_start' | 'span_end' | 'text'; kind: number; text: string; detail: number }[];
}

/** Roclet adapter protocol 1. All ranges are half-open UTF-8 byte offsets. */
export interface Token {
  requestId: string;
  documentRevision: number;
  inputRevision: number;
  workerGeneration: number;
}
export interface Cell { key: string; source: string }
export interface Snapshot extends Token {
  cells: Cell[];
  roots: string[];
  modules?: { name: string; content: string }[];
  /** Parser-backed top-level notebook tests, identified without rewriting source. */
  expectations?: { root: string; start: number; end: number; cell?: number }[];
  /** Browser session desired module set; changed UTF-8 files are mounted once.
   * Main.roc is generated; ordinary modules live under /workspace/. */
  files?: {path: string; source: string}[];
  /** Opt in to independent runtime failures; compile errors remain module-wide. */
  isolate_errors?: boolean;
}
export interface Definition {
  name: string;
  type: string;
  cell: string | null;
  region: { start: number; end: number };
  name_region: ByteSpan | null;
  /** Resolved compiler name references, including lambda bodies and recursion. */
  dependencies: string[];
  references: ByteSpan[];
  rename_safe: boolean;
}
export interface Observation {
  kind: 'dbg' | 'expect_failed' | 'crashed' | 'truncated';
  root: string;
  message: string;
  /** This compiler ABI does not supply the originating dbg region. */
  region: null;
}
export interface Response extends Token {
  protocol: 1;
  status: 'ok' | 'partial' | 'diagnostic' | 'runtime_error' | 'protocol_error';
  definitions: Definition[];
  dependency_scope: 'definitions' | 'module';
  binders: string[];
  root_errors: {root: string; status: string; failure: string | null}[];
  evaluated_roots: string[];
  values: { root: string; text: string; display?: DisplayValue }[];
  tests: { root: string; passed: boolean; message: string; cell?: number; start?: number; end?: number; location?: {line:number; column:number}; scope?: 'cell' | 'source' }[];
  events: Observation[];
  diagnostics: {
    title: string;
    severity: string;
    message: string;
    /** Compiler-provided 1-based display coordinates; not byte offsets. */
    location: null | { start_line: number; start_column: number; end_line: number; end_column: number };
  }[];
  failure: string | null;
  workspaceCache?: CompilerCacheStats;
  /** Requests are emitted by Roc's own package resolver; browser fetches archives. */
  packagesRequired?: {url: string; destination: string}[];
}
export interface CompilerCacheStats {
  hits: number;
  misses: number;
  stores: number;
  bytes_read: number;
  bytes_written: number;
  /** One prepared notebook graph/image serves every selected output. */
  frontend_builds?: number;
  lowerings?: number;
  executions?: number;
  /** 1 when the request was served by the retained revision, else 0. */
  prepared_hits?: number;
  /** Dependency analyses computed: 1 for a new revision (cached for later
   *  requests and roots), 0 when reused, 1 per script run. */
  analyses?: number;
  /** Bytes of the flat LIR image built by this request (0 when a retained
   *  revision was reused) and the image buffer doublings it took. */
  image_bytes?: number;
  image_retries?: number;
  [counter: string]: number | undefined;
}

/** M1 formats. Conversion and parsing never execute notebook expressions. */
export interface DocumentRequest {
  operation: 'document';
  /** Markdown editing views carry hidden Roc configuration separately. */
  context?: { preamble: string; metadata: string };
  action: 'parse' | 'convert' | 'normalize' | 'view' | 'compose' | 'export' | 'check' | 'run' | 'evaluate' | 'analyze';
  format: 'roc' | 'markdown';
  target?: 'roc' | 'markdown';
  source: string;
  modules?: { name: string; content: string }[];
  /** Desired ordinary module files, sent as raw byte changes by DocumentSession. */
  files?: {path: string; source: string}[];
  /** M2 notebook editing retains explicit cell kinds without parsing an incomplete aggregate. */
  draft?: DocumentDraft;
  /** evaluate only: force the output and top-level expects in this cell; the whole module is checked. */
  selectedCell?: number;
  /** analyze/evaluate: participate in the engine-owned reactive baseline.
   *  Present (even `{}`): plan against the graph of the engine's last
   *  participating request, evaluate only invalidated or forced roots, return
   *  every root's value, test and events with `reused`, then commit. Absent:
   *  stateless, every root evaluated, the baseline neither read nor written.
   *  `reset` forgets the baseline first. Retained presentations are never
   *  execution inputs. The removed members `known`, `previous`, `current`,
   *  `available` and `roots` are rejected with `protocol_error`. */
  reactivity?: {force?: string[]; reset?: boolean};
  forceAll?: boolean;
  isolateErrors?: boolean;
  /** Return typed MD4C rendering events for prose; never executable HTML. */
  render?: boolean;
  /** analyze/evaluate only: omit duplicate sources and internal parser payloads. */
  compact?: boolean;
}
export interface DocumentDraft {
  preamble: string;
  metadata: string;
  cells: { kind: 'code' | 'markdown' | 'generated'; source: string; attributes: string; outputs: { kind: string; source: string }[] }[];
}
export interface ByteSpan { start: number; end: number }
export interface DocumentDiagnostic extends ByteSpan {
  code: string;
  severity: 'error' | 'warning';
  message: string;
  cell: number;
  /** One-based line and UTF-8 byte column in the original document. */
  location: { line: number; column: number };
  /** Draft requests use offsets and locations within the named cell. */
  scope?: 'cell';
}
export interface DocumentCell extends ByteSpan {
  kind: 'code' | 'markdown' | 'generated';
  source: string;
  attributes: string;
  /** Explicit or inferred; may be empty. Inferred IDs are not persistent IDs. */
  id: string;
  output: string;
  /** Top-level expect execution roots associated with this code cell. */
  expectations: string[];
  /** Saved, unverified data, never evaluation input. */
  outputs: { kind: string; source: string }[];
  body_start: number;
  source_map?: (ByteSpan & { original_start: number; original_end: number })[];
  /** Version-pinned compiler/Markdown facts; recompute when source changes. */
  facts?: unknown;
  blocks?: unknown[];
  first_block?: unknown;
  marker_lines?: number[];
}
/** One dependency graph node. `dependencies` name other nodes (or a binder
 *  of one): value definitions, local types, and `module:<name>` nodes. */
export interface DependencyNode {
  name: string;
  /** Every name the definition binds (`[name]` for a plain binding); empty
   *  for type and module nodes. */
  binders: string[];
  fingerprint: string;
  dependencies: string[];
}
/** Graph version 2: checked value, type and module nodes. A baseline of
 *  another version invalidates every root ("Graph format changed"). */
export interface DependencyGraph {
  version: 2;
  /** Everything outside the nodes that can change a result. */
  context: string;
  /** `module`: the graph could not be fully resolved; any change re-evaluates every root. */
  scope: 'definitions' | 'module';
  /** Value definitions (associated items as `Type.item`) and expectation roots. */
  definitions: DependencyNode[];
  /** Local type declarations; each depends on its associated items. */
  types: DependencyNode[];
  /** Imported modules a node refers to; the fingerprint is the module's deep
   *  content identity. */
  modules: DependencyNode[];
}
export interface RecomputePlan {
  changed: string[];
  evaluate: string[];
  reused: string[];
  explanations: {root: string; reason: string; dependencies: string[]}[];
}
export interface DocumentResponse {
  workspaceCache?: CompilerCacheStats;
  packagesRequired?: {url: string; destination: string}[];
  /** Browser transport byte counts; fileBytes includes changed source only;
   *  memoryBytes is the worker's WASM linear memory size after the request. */
  transportMetrics?: {requestBytes: number; responseBytes: number; fileBytes: number; memoryBytes?: number};
  graph?: DependencyGraph;
  plan: RecomputePlan;
  protocol: 1;
  status: 'ok' | 'partial' | 'diagnostic' | 'runtime_error' | 'protocol_error';
  source?: string;
  model: {
    format: 'roc' | 'markdown';
    original?: string;
    preamble: string;
    metadata: string;
    cells: DocumentCell[];
    diagnostics: DocumentDiagnostic[];
  };
  execution?: string;
  /** Lowered user module, excluding all generated script helpers and main!. */
  program?: string;
  /** Safe editable representation; inline snapshot comments are not repeated in outputs. */
  draft?: DocumentDraft;
  roots: string[];
  /** Checked test roots map to unchanged generated program spans. */
  expectations: {root: string; start: number; end: number; cell: number}[];
  /** Source positions are body_start + normalized cell offsets; compose with source_map. */
  mappings: { generated_start: number; generated_end: number; source_start: number; source_end: number; cell: number }[];
  evaluation?: {
    status: string;
    /** analyze/evaluate entries carry `reused`: the presentation was retained
     *  from an earlier participating request (root in `plan.reused`). With
     *  `reactivity`, values, tests and events cover every current root, in
     *  root order; `evaluated_roots` and `root_errors` cover this request only. */
    events: { kind: string; message: string; root?: string; cell?: number | null; sequence?: number; reused?: boolean }[];
    /** evaluate returns separate designated values and root-attributed observations. */
    values?: { root: string; text: string; display?: DisplayValue; reused?: boolean }[];
    tests?: (Response['tests'][number] & {cell?: number; start?: number; end?: number; location?: {line: number; column: number}; scope?: 'cell' | 'source'; reused?: boolean})[];
    diagnostics: unknown[];
    definitions: unknown[];
    dependency_scope?: 'definitions' | 'module';
    binders?: string[];
    root_errors?: {root: string; status: string; failure: string | null}[];
    evaluated_roots?: string[];
    failure: string | null;
  };
  rendering?: { cell: number; events: { event: 'block_start' | 'block_end' | 'span_start' | 'span_end' | 'text'; kind: number; text: string; detail: number }[] }[];
}
