const encoder = new TextEncoder();
export const PROTOCOL = 1;
export const CAPABILITIES = Object.freeze({
  protocol: PROTOCOL,
  compilerCommit: '7894793d1454103d47c4368c942b3fec1406e8fd',
  completeModule: true,
  forwardReferences: true,
  definitionTypesAndRegions: true,
  selectedRoots: true,
  debugEvents: 'buffered, attributed to evaluation root; originating region unavailable',
  resolvedDependencyGraph: true,
  dependencyPrecision: 'compiler name references; conservative module fallback for types/dispatch',
  resolvedReferences: true,
  independentRuntimeErrors: true,
  independentCompileErrors: false,
  retainedValues: false,
  richDisplay: 'Display v1: text, Markdown, bounded tables, embedded raster images',
  platformEffects: false,
  cancellation: 'terminate worker or native subprocess',
  sourceLimitBytes: 1024 * 1024,
});

export function tokenOf(snapshot) {
  return Object.fromEntries(['requestId', 'documentRevision', 'inputRevision', 'workerGeneration'].map(key => [key, snapshot[key]]));
}
export function sameToken(a, b) {
  return !!a && !!b && Object.keys(tokenOf(a)).every(key => a[key] === b[key]);
}
export function assemble(cells) {
  if (!Array.isArray(cells)) throw new TypeError('cells must be an array');
  const keys = new Set();
  let source = '', bytes = 0;
  const ranges = [];
  for (const cell of cells) {
    if (typeof cell.key !== 'string' || !cell.key || keys.has(cell.key) || typeof cell.source !== 'string') throw new TypeError('Cells require unique keys and source strings');
    keys.add(cell.key);
    if (ranges.length) { source += '\n\n'; bytes += 2; }
    const start = bytes;
    source += cell.source;
    bytes += encoder.encode(cell.source).length;
    ranges.push({ cell: cell.key, start, end: bytes });
  }
  return { source, bytes, ranges };
}
function validate(snapshot) {
  if (typeof snapshot.requestId !== 'string' || !snapshot.requestId) throw new TypeError('requestId is required');
  for (const key of ['documentRevision', 'inputRevision', 'workerGeneration']) {
    if (!Number.isSafeInteger(snapshot[key]) || snapshot[key] < 0) throw new TypeError(`${key} must be a nonnegative safe integer`);
  }
  if (!Array.isArray(snapshot.roots) || new Set(snapshot.roots).size !== snapshot.roots.length || snapshot.roots.some(root => typeof root !== 'string' || !/^[a-z][A-Za-z0-9_]*$/.test(root))) throw new TypeError('roots must be unique ordinary Roc value identifiers');
  const moduleNames = new Set();
  for (const module of snapshot.modules ?? []) {
    if (typeof module.name !== 'string' || !/^[A-Z][A-Za-z0-9_]*$/.test(module.name) || typeof module.content !== 'string' || moduleNames.has(module.name)) throw new TypeError('Invalid or duplicate module');
    moduleNames.add(module.name);
  }
}

/** The bridge is stateless: every call checks a complete source snapshot. */
export class CompilerAdapter {
  constructor(transport) { this.transport = transport; }
  async evaluate(snapshot) {
    validate(snapshot);
    // Own a copy before the first await; subsequent edits cannot change this request.
    snapshot = structuredClone(snapshot);
    // Validate cell identities before sending the owned snapshot across the host boundary.
    assemble(snapshot.cells);
    const result = await this.transport(snapshot);
    if (result.protocol !== PROTOCOL) throw new Error('Compiler bridge protocol mismatch');
    return result;
  }
}

/** Display state is cleared at submission, including after deleting a binding. */
export class RevisionGate {
  current = null;
  result = null;
  begin(token) { this.current = tokenOf(token); this.result = null; }
  accept(result) {
    if (!sameToken(this.current, result)) return false;
    this.result = result;
    return true;
  }
  invalidate() { this.current = null; this.result = null; }
}

/** UTF-8 byte offsets cannot be used directly as JS/editor string offsets. */
export function byteOffsetToUtf16(source, offset) {
  const bytes = encoder.encode(source);
  if (!Number.isInteger(offset) || offset < 0 || offset > bytes.length) throw new RangeError('Invalid byte offset');
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, offset)).length;
}
