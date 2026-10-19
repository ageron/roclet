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
  prepared_hits?: number;
  [counter: string]: number;
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
  /** evaluate only: output belonging to this model-cell index; the whole module is still checked. */
  selectedCell?: number;
  /** Evaluate only invalidated/forced roots. Prior strings are never execution inputs. */
  /** Persistent browser engines may omit the confirmed baseline graphs. */
  reactivity?: {known: boolean; previous?: DependencyGraph; current?: DependencyGraph; roots: string[]; available: string[]; force: string[]};
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
export interface DependencyGraph {
  context: string;
  scope: 'definitions' | 'module';
  definitions: {name: string; fingerprint: string; dependencies: string[]}[];
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
  /** Browser transport byte counts; fileBytes includes changed source only. */
  transportMetrics?: {requestBytes: number; responseBytes: number; fileBytes: number};
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
  /** Source positions are body_start + normalized cell offsets; compose with source_map. */
  mappings: { generated_start: number; generated_end: number; source_start: number; source_end: number; cell: number }[];
  evaluation?: {
    status: string;
    events: { kind: string; message: string; root?: string; cell?: number | null; sequence?: number }[];
    /** evaluate returns separate designated values and root-attributed observations. */
    values?: { root: string; text: string; display?: DisplayValue }[];
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
