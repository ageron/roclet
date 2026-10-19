import { DocumentDraft, DocumentSession } from './document-session.mjs';
const $ = id => document.getElementById(id);
const draft = new DocumentDraft($('source').value);
let session, revision = 0;
const clearResults = () => { $('output').textContent = ''; $('model').textContent = ''; $('generated').textContent = ''; };
const invalidate = () => { revision++; session?.invalidate(); clearResults(); };
const reflect = () => { $('source').value = draft.source; $('format').value = draft.format; };
const showResult = result => {
  $('model').textContent = JSON.stringify(result, null, 2);
  const diagnostics = result.model?.diagnostics ?? result.diagnostics ?? [];
  $('output').textContent = [
    ...(result.evaluation?.events ?? []).map(event => `${event.kind === 'dbg' ? 'dbg: ' : ''}${event.message}`),
    ...diagnostics.map(d => `${d.code ?? d.title}: ${d.message}`),
    ...(result.failure ? [result.failure] : []),
  ].join('\n');
};
const download = (source, format) => {
  const url = URL.createObjectURL(new Blob([source], { type: 'text/plain;charset=utf-8' }));
  const link = document.createElement('a'); link.href = url; link.download = format === 'roc' ? 'notebook.roc' : 'notebook.md'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
async function perform(action) {
  if (!session) return;
  invalidate();
  const current = revision;
  const target = action === 'convert' ? (draft.format === 'roc' ? 'markdown' : 'roc') : action === 'export' ? 'roc' : draft.format;
  if (action === 'convert' && draft.restore(target)) {
    reflect(); $('status').textContent = 'Format switched · original text restored.'; return;
  }
  const started = performance.now();
  $('status').textContent = `${action === 'convert' ? 'Converting' : action === 'download' ? 'Saving' : action === 'export' ? 'Preparing runnable Roc' : action === 'run' ? 'Running' : action === 'check' ? 'Checking' : 'Inspecting'}…`;
  try {
    const operation = action === 'convert' ? 'view' : action === 'download' || action === 'export' ? 'export' : action;
    const result = await session.request(draft.request(operation, target));
    if (current !== revision) return;
    showResult(result);
    $('status').textContent = `${result.status}${result.model ? ` · ${result.model.cells.filter(c => c.kind !== 'generated').length} cells` : ''} · ${Math.round(performance.now() - started)} ms`;
    if (action === 'convert' && draft.converted(target, result)) reflect();
    if (action === 'export') {
      $('generated').textContent = result.source ?? '';
      $('generated-details').open = true;
    }
    if (action === 'download' && result.model && typeof result.source === 'string') download(result.source, target);
  } catch (error) {
    if (current === revision && error.name !== 'AbortError') $('status').textContent = error.message;
  }
}
$('stop').onclick = () => { revision++; session?.stop(); clearResults(); $('status').textContent = 'Stopped.'; };
$('source').oninput = () => { invalidate(); draft.edit($('source').value); $('status').textContent = 'Source changed; previous results cleared.'; };
$('format').onchange = () => {
  invalidate(); draft.open($('source').value, $('format').value);
  $('status').textContent = 'Source interpretation changed.';
};
$('open').onchange = async event => {
  const file = event.target.files[0]; if (!file) return;
  invalidate(); const current = revision;
  const source = await file.text();
  if (current !== revision) return;
  draft.open(source, file.name.endsWith('.roc') ? 'roc' : 'markdown'); reflect();
  $('status').textContent = `Opened ${file.name}. Saved outputs have not been verified.`;
};
$('download').onclick = () => perform('download');
for (const button of document.querySelectorAll('[data-action]')) button.onclick = () => perform(button.dataset.action);
try {
  const response = await fetch('../artifacts/roclet.wasm');
  if (!response.ok) throw new Error('Build the compiler adapter first.');
  session = new DocumentSession(await response.arrayBuffer());
  const current = revision;
  $('status').textContent = 'Preparing the document engine…';
  // Compile only Roclet's own fixed application. Notebook code never runs here.
  const result = await session.request({ operation: 'document', action: 'parse', format: 'roc', source: '' });
  if (current === revision) $('status').textContent = result.status === 'ok' ? 'Ready. All operations run locally.' : (result.failure ?? 'Document engine could not start.');
} catch (error) { if (error.name !== 'AbortError') $('status').textContent = error.message; }
