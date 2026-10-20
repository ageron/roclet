import { makeCell } from './edit-model.mjs';

// Ephemeral UI selection: keys never become notebook identifiers.
export class CellSelection {
  constructor() { this.keys = []; this.anchor = null; this.focus = null; this.mode = 'cells'; }
  reconcile(keys) {
    const position = Math.max(0, this.keys.indexOf(this.focus));
    this.keys = keys;
    if (!keys.includes(this.focus)) this.focus = keys[Math.min(position, keys.length - 1)] ?? null;
    if (!keys.includes(this.anchor)) this.anchor = this.focus;
  }
  select(key, extend = false) {
    if (!this.keys.includes(key)) return;
    if (!extend || !this.anchor) this.anchor = key;
    this.focus = key; this.mode = 'cells';
  }
  move(delta, extend = false) {
    const index = Math.max(0, Math.min(this.keys.length - 1, this.keys.indexOf(this.focus) + delta));
    this.select(this.keys[index], extend);
  }
  get selected() {
    const a = this.keys.indexOf(this.anchor), b = this.keys.indexOf(this.focus);
    return a < 0 || b < 0 ? [] : this.keys.slice(Math.min(a, b), Math.max(a, b) + 1);
  }
  all() { this.anchor = this.keys[0] ?? null; this.focus = this.keys.at(-1) ?? null; this.mode = 'cells'; }
}

export function insertionIndex(cells, visiblePosition) {
  const visible = cells.filter(c => c.kind !== 'generated');
  if (visible[visiblePosition]) return cells.indexOf(visible[visiblePosition]);
  if (visible.length) return cells.indexOf(visible.at(-1)) + 1;
  const generated = cells.findIndex(c => c.kind === 'generated');
  return generated < 0 ? cells.length : generated;
}

export function commentFinalExpression(source, facts) {
  const last = facts.statements.at(-1);
  // Preserve definitions and incomplete source; do not guess at parser recovery.
  if (facts.errors.length || last?.kind !== 'expr') return source;
  const bytes = new TextEncoder().encode(source), decoder = new TextDecoder('utf-8', {ignoreBOM:true});
  const before = decoder.decode(bytes.subarray(0, last.start));
  const expression = decoder.decode(bytes.subarray(last.start, last.end));
  const after = decoder.decode(bytes.subarray(last.end));
  return before + expression.split('\n').map(line => `# ${line}`).join('\n') + after;
}

export const cellMime = 'application/x-roclet-cells+json';
const prefix = 'Roclet cells v1\n';
const maxBytes = 256 * 1024;
const byteLength = value => new TextEncoder().encode(value).length;
export function encodeCells(cells) {
  // Only editable source is copied. Computed results and browser identity are not.
  return prefix + JSON.stringify(cells.map(({kind, source, attributes}) => ({kind, source, attributes: attributes ?? ''})), null, 2);
}
export function decodeCells(text, structured = false) {
  if (byteLength(text) > maxBytes) throw new Error('The pasted cells exceed the 256 KiB notebook limit.');
  if (!text.startsWith(prefix)) {
    if (structured) throw new Error('The clipboard contains an unsupported cell format.');
    return text ? [makeCell('code', text)] : [];
  }
  let cells;
  try { cells = JSON.parse(text.slice(prefix.length)); } catch { throw new Error('The clipboard contains malformed Roclet cells.'); }
  if (!Array.isArray(cells) || !cells.length || cells.length > 500 || !cells.every(c => c && ['code','markdown'].includes(c.kind) && typeof c.source === 'string' && typeof c.attributes === 'string')) throw new Error('The clipboard contains invalid Roclet cells.');
  return cells.map(c => ({...makeCell(c.kind, c.source), attributes: c.attributes}));
}
export function checkInsertion(existing, additions) {
  if (existing.length + additions.length > 500 || byteLength(JSON.stringify([...existing, ...additions])) > maxBytes) throw new Error('This prototype supports up to 500 cells and 256 KiB per notebook.');
}
