// Panel layout for the notebook editor. Everything here is plain logic over
// the DOM it is given (or plain data), so Node tests can import it.

// Every panel element carries data-part. The primary panel keeps the legacy
// ids (prefix ''), which existing contracts and probes rely on; a second panel
// gets the same names behind its own prefix. Panel code never uses the ids.
export const partId = (prefix, name) => `${prefix}${name}`;
export function assignPanelIds(root, prefix) {
  for (const node of root.querySelectorAll('[data-part]')) node.id = partId(prefix, node.dataset.part);
  for (const node of root.querySelectorAll('[data-for]')) node.htmlFor = partId(prefix, node.dataset.for);
  return root;
}
export function clonePanel(template, prefix) {
  const root = template.content.firstElementChild.cloneNode(true);
  return assignPanelIds(root, prefix);
}

// The numbers the Dependencies & timing dialog and the status bar show for a
// panel's last completed response.
export function engineStats(result) {
  const values = result?.evaluation?.values ?? [];
  return {
    workerMs: result?.workerMs ?? null,
    evaluated: result?.evaluation?.evaluated_roots?.length ?? 0,
    reused: result?.plan?.reused?.length ?? values.filter(value => value.reused).length,
    memoryBytes: result?.transportMetrics?.memoryBytes ?? null,
  };
}
export function engineDetails(result) {
  if (result?.workerMs == null) return '—';
  const stats = engineStats(result);
  const parts = [`worker ${Math.round(stats.workerMs)} ms`, `${stats.evaluated} evaluated`, `${stats.reused} reused`];
  if (stats.memoryBytes) parts.push(`${Math.round(stats.memoryBytes / (1024 * 1024))} MiB`);
  return parts.join(' · ');
}
// Per-viewer preferences are stored like the theme; storage may be unavailable.
export const engineDetailsKey = 'roclet.engine-details';
export function readPreference(storage, key, fallback = false) {
  try { const value = storage?.getItem(key); return value == null ? fallback : value === 'true'; } catch { return fallback; }
}
export function writePreference(storage, key, value) {
  try { storage?.setItem(key, String(value)); } catch { /* The preference then applies to this page only. */ }
}
