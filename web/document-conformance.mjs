import { assert, compilerSemantics } from '../tests/harness.mjs';
import { DocumentDraft, DocumentSession } from './document-session.mjs';
const status = document.getElementById('status');
const log = document.getElementById('log');
let worker, paritySession;
try {
  const [bytes, native, manifest] = await Promise.all([
    fetch('../artifacts/roclet.wasm').then(r => r.arrayBuffer()),
    fetch('../artifacts/document-conformance.json').then(r => r.json()),
    fetch('../artifacts/manifest.json').then(r => r.json()),
  ]);
  assert.deepEqual(native.manifest, manifest);
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(v => v.toString(16).padStart(2, '0')).join('');
  assert.equal(hash, manifest.artifacts['roclet.wasm'].sha256);
  paritySession = new DocumentSession(bytes);
  let count = 0;
  for (const fixture of native.cases) {
    status.textContent = `Checking ${fixture.name} · ${count}/${native.cases.length}`;
    // Each fixture owns its desired project files. Use the production session
    // transport so deletions remove prior files from the persistent workspace.
    const result = await paritySession.request(fixture.request);
    assert.deepEqual(compilerSemantics(result), compilerSemantics(fixture.result));
    count++;
    log.textContent += `PASS ${fixture.name}\n`;
  }
  paritySession.stop();
  let freshWorkerRuns = 0;
  // Stop/restart creates a fresh instance. Test both cold and warm core caches,
  // including possible linear-memory addresses above 2 GiB.
  for (const fixture of native.cases.filter(c => ['run', 'evaluate'].includes(c.request.action))) {
    status.textContent = `Checking fresh worker: ${fixture.name}`;
    worker = new Worker('./format-worker.mjs', { type: 'module' });
    const result = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`Fresh worker timeout: ${fixture.name}`)), 60000);
      worker.onmessage = ({ data }) => { clearTimeout(timeout); data.error ? reject(new Error(data.error)) : resolve(data.result); };
      worker.onerror = error => { clearTimeout(timeout); reject(error); };
      worker.postMessage({ bytes, request: fixture.request });
    });
    assert.deepEqual(compilerSemantics(result), compilerSemantics(fixture.result));
    worker.terminate();
    freshWorkerRuns++;
    log.textContent += `PASS fresh worker: ${fixture.name}\n`;
  }
  const session = new DocumentSession(bytes);
  const timings = {};
  const timed = async (name, request) => {
    const start = performance.now();
    const result = await session.request(request);
    timings[name] = Math.round(performance.now() - start);
    return result;
  };
  try {
    status.textContent = 'Checking editing workflow and cache invalidation';
    assert.equal((await timed('prepareMs', { operation: 'document', action: 'parse', format: 'roc', source: '' })).status, 'ok');
    const original = 'app [main!] {}\n\n# %%\narea\n\n# %%\nwidth = 5\nheight = 3\n\n# %%\narea = width * height\n';
    const draft = new DocumentDraft(original);
    assert.equal((await timed('checkMs', draft.request('check'))).status, 'ok');
    const initialRun = await timed('runMs', draft.request('run'));
    assert.deepEqual(initialRun.evaluation.events.map(e => e.message), ['15.0\n']);
    draft.converted('markdown', await timed('convertMs', draft.request('view', 'markdown')));
    assert.doesNotMatch(draft.source, /rocPreamble|roclet_observe|display!|main!|out_1/);
    assert.equal(draft.restore('roc'), true);
    assert.equal(draft.source, original);
    draft.restore('markdown');
    draft.edit(draft.source.replace('width = 5', 'width = 6'));
    assert.equal(draft.restore('roc'), false);
    draft.converted('roc', await timed('editedConvertMs', draft.request('view', 'roc')));
    assert.doesNotMatch(draft.source, /rocPreamble|roclet_observe|display!|main! =/);
    const edited = await timed('editedRunMs', draft.request('run'));
    assert.deepEqual(edited.evaluation.events.map(e => e.message), ['18.0\n']);
    const deleted = await session.request({ ...draft.request('run'), source: '# %%\nout_1 = area' });
    assert.notEqual(deleted.status, 'ok');
    assert.deepEqual(deleted.evaluation.events, []);
    const cancelled = session.request(draft.request('run'));
    const rejection = assert.rejects(cancelled, { name: 'AbortError' });
    session.stop();
    await rejection;
    const restarted = await session.request(draft.request('run'));
    assert.deepEqual(restarted.evaluation.events.map(e => e.message), ['18.0\n']);
    log.textContent += `PASS editing views, exact switch-back, edits, deletion, Stop, restart\nTIMINGS ${JSON.stringify(timings)}\n`;
  } finally { session.stop(); }
  status.textContent = `PASS — ${count} complete native/WASM document responses match; ${freshWorkerRuns} fresh worker runs; editing workflow`;

  document.documentElement.dataset.result = 'pass';
  document.documentElement.dataset.summary = JSON.stringify({ documentParityCases: count, freshWorkerRuns, editingWorkflow: 'pass', timings });
} catch (error) {
  status.textContent = 'FAIL'; log.textContent += error.stack ?? error.message;
  document.documentElement.dataset.result = 'fail';
} finally { worker?.terminate(); paritySession?.stop(); }
