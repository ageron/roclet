import { test, assert } from './harness.mjs';
import { assemble, byteOffsetToUtf16, CompilerAdapter, RevisionGate } from '../compiler-adapter/adapter.mjs';
import { snapshot } from './fixtures.mjs';
import { projectFiles } from '../web/project-files.mjs';

test('project modules preserve raw source editing and undo as one notebook change', async () => {
  const { Notebook, newDraft, requestFor, validDraft } = await import('../web/edit-model.mjs');
  const session = { invalidate() {}, stop() {} };
  const notebook = new Notebook(null, {save:async()=>{}}, {session,debounce:60000});
  notebook.state = newDraft(); notebook.state.autoRun=false; notebook.state.sourceCurrent=true; notebook.state.source='out_1 = Geometry.area';
  notebook.result = {status:'ok'};
  notebook.setProjectFile('Geometry.roc','module [area]\narea = 15');
  assert.equal(notebook.result,null);
  assert.equal(notebook.state.sourceCurrent,true);
  assert.equal(requestFor(notebook.state,'evaluate').source,'out_1 = Geometry.area');
  assert.deepEqual(requestFor(notebook.state,'evaluate').files,[{path:'/workspace/Geometry.roc',source:'module [area]\narea = 15'}]);
  notebook.setProjectFile('Geometry.roc','module [area]\narea = 24');
  notebook.undo();assert.equal(notebook.state.files[0].source,'module [area]\narea = 15');
  notebook.removeProjectFile('Geometry.roc');assert.deepEqual(notebook.state.files,[]);
  assert.equal(validDraft({...notebook.state,files:[{path:'../outside.roc',source:''}]}),false);
  notebook.dispose();
});

test('project paths cannot replace the notebook or escape a portable project', () => {
  for(const path of ['Main.roc','main.roc','../secret.roc','/absolute.roc','nested/../secret.roc','nested//File.roc','C:File.roc','bad\\File.roc']) {
    assert.throws(()=>projectFiles([{path,source:'module []'}]));
  }
  assert.throws(()=>projectFiles([{path:'File.roc',source:''},{path:'File.roc',source:''}]));
  assert.deepEqual(projectFiles([{path:'Shapes/Wall.roc',source:'module [area]\narea = 15'}]),[{path:'Shapes/Wall.roc',source:'module [area]\narea = 15'}]);
});

test('portable bundles retain project sources once and reject modified members', async () => {
  const { bundleFiles, importBundle } = await import('../web/sharing.mjs');
  const { zip, utf8, text } = await import('../web/archive.mjs');
  const { sha256 } = await import('../web/offline-cache.mjs');
  const display=utf8('module []'),displayHash=await sha256(display),originalFetch=globalThis.fetch;
  globalThis.fetch=async()=>new Response(display);
  try {
    const compiler={compilerCommit:'test-compiler',artifacts:{'roclet.wasm':{sha256:'test-wasm'}},inputs:{'package/Display.roc':displayHash}};
    const capture={document:{schema:1,title:'Project',format:'roc',preamble:'app [main!] {}',metadata:'',source:'',sourceCurrent:false,mode:'notebook',cells:[{kind:'code',source:'Geometry.area',attributes:'',outputs:[]}],files:[{path:'Geometry.roc',source:'module [area]\narea = 15'}]},source:'Geometry.area',snapshots:[],events:[],compiler:{commit:'test-compiler',wasmSha256:'test-wasm',displaySha256:displayHash},createdAt:'test'};
    const files=await bundleFiles(capture);
    assert.equal(text(files.get('project/Geometry.roc')),'module [area]\narea = 15');
    assert.deepEqual(JSON.parse(text(files.get('document.json'))).files,[{path:'Geometry.roc'}]);
    const imported=await importBundle(await zip(files).arrayBuffer(),compiler);
    assert.deepEqual(imported.record.files,capture.document.files);
    assert.equal(imported.record.autoRun,false);
    files.set('project/Geometry.roc',utf8('module [area]\narea = 24'));
    await assert.rejects(importBundle(await zip(files).arrayBuffer(),compiler),/integrity/i);
  } finally {globalThis.fetch=originalFetch;}
});
test('stale results after edit, input change, restart, failure, and stop are hidden', () => {
  const gate = new RevisionGate();
  const original = snapshot({ cells: [], roots: [] });
  gate.begin(original);
  assert.equal(gate.accept({ ...original, status: 'ok', values: [15] }), true);
  for (const key of ['documentRevision', 'inputRevision', 'workerGeneration']) {
    gate.begin({ ...original, [key]: 2 });
    assert.equal(gate.result, null);
    assert.equal(gate.accept(original), false);
  }
  gate.begin({ ...original, requestId: 'second-request' });
  assert.equal(gate.accept(original), false);
  const failure = { ...original, requestId: 'second-request', status: 'diagnostic', values: [] };
  assert.equal(gate.accept(failure), true);
  assert.deepEqual(gate.result.values, []);
  gate.invalidate();
  assert.equal(gate.accept(failure), false);
  assert.equal(gate.result, null);
});
test('UTF-8 source ranges map to UTF-16 only at character boundaries', () => {
  const source = '# 🪨 café\nx = 1';
  const prefix = new TextEncoder().encode('# 🪨 café\n').length;
  assert.equal(byteOffsetToUtf16(source, prefix), '# 🪨 café\n'.length);
  assert.throws(() => byteOffsetToUtf16(source, 3));
  const assembled = assemble([{ key: 'one', source: '# 🪨' }, { key: 'two', source: 'x = 1' }]);
  assert.equal(assembled.ranges[1].start, 8);
});
test('invalid root injection and duplicate keys fail before invoking compiler', async () => {
  const adapter = new CompilerAdapter(() => { throw new Error('must not invoke compiler'); });
  await assert.rejects(adapter.evaluate(snapshot({ cells: [], roots: ['x)\ncrash "bad"'] })), /identifiers/);
  await assert.rejects(adapter.evaluate(snapshot({ cells: [{ key: 'x', source: '' }, { key: 'x', source: '' }], roots: [] })), /unique keys/);
});
test('request sources are owned before asynchronous compilation', async () => {
  let submitted, finish;
  const adapter = new CompilerAdapter(request => {
    submitted = request;
    return new Promise(resolve => { finish = resolve; });
  });
  const input = snapshot({ cells: [{ key: 'x', source: 'x = 1' }], roots: ['x'] });
  const pending = adapter.evaluate(input);
  input.cells[0].source = 'x = 999';
  input.roots[0] = 'other';
  assert.equal(submitted.cells[0].source, 'x = 1');
  assert.deepEqual(submitted.roots, ['x']);
  finish({ protocol: 1, status: 'ok', values: [{ root: 'x', text: '1.0' }] });
  assert.equal((await pending).values[0].root, 'x');
});

test('browser worker lifecycle drops late messages from terminated generations', async () => {
  const { BrowserSession } = await import('../web/session.mjs');
  const workers = [];
  class FakeWorker {
    sent = [];
    terminated = false;
    constructor() { workers.push(this); }
    postMessage(message) { this.sent.push(message); }
    terminate() { this.terminated = true; }
    emit(data) { this.onmessage({ data }); }
  }
  const session = new BrowserSession(new ArrayBuffer(0), FakeWorker);
  const fixture = snapshot({ cells: [], roots: [] });
  const first = session.evaluate(fixture);
  const cancelled = assert.rejects(first, { name: 'AbortError' });
  workers[0].emit({ type: 'ready' });
  const oldRequest = workers[0].sent[1].snapshot;
  const second = session.evaluate({ ...fixture, documentRevision: 2 });
  await cancelled;
  assert.equal(workers[0].terminated, true);
  workers[0].emit({ type: 'result', result: { ...oldRequest, values: [42] } });
  assert.equal(session.gate.result, null);
  workers[1].emit({ type: 'ready' });
  const currentRequest = workers[1].sent[1].snapshot;
  workers[1].emit({ type: 'result', result: { ...currentRequest, status: 'diagnostic', values: [] } });
  assert.deepEqual((await second).values, []);
  assert.equal(workers[1].terminated, true);
});

const { DocumentDraft, DocumentSession } = await import('../web/document-session.mjs');
test('format switching restores exact draft bytes and invalidates the alternate view after edits', () => {
  const original = 'app [main!] {}\r\n\r\n#%%\r\n  1 + 1\r\n';
  const draft = new DocumentDraft(original);
  draft.converted('markdown', { status: 'ok', source: '```roc\n1 + 1\n```\n', model: { preamble: 'app [main!] {}\r\n', metadata: '' } });
  assert.equal(draft.restore('roc'), true);
  assert.equal(draft.source, original);
  draft.restore('markdown');
  draft.edit('```roc\n2 + 2\n```\n');
  assert.equal(draft.restore('roc'), false);
  assert.equal(draft.request('run').context.preamble, 'app [main!] {}\r\n');
  draft.open('# New doc', 'markdown');
  assert.equal(draft.request('run').context, undefined);
  assert.equal(draft.restore('roc'), false);
});
test('an invalid conversion never replaces an editable draft', () => {
  const draft = new DocumentDraft('# %%\nx = {');
  assert.equal(draft.converted('markdown', { status: 'diagnostic', source: 'different' }), false);
  assert.equal(draft.source, '# %%\nx = {');
  assert.equal(draft.format, 'roc');
});
test('document worker survives completed requests but cancellation rejects late results', async () => {
  const workers = [];
  class FakeWorker {
    sent = [];
    terminated = false;
    constructor() { workers.push(this); }
    postMessage(value) { this.sent.push(value); }
    terminate() { this.terminated = true; }
  }
  const session = new DocumentSession(new ArrayBuffer(1), FakeWorker);
  const first = session.request({ source: 'old' });
  workers[0].onmessage({ data: { result: { value: 1 } } });
  assert.equal((await first).value, 1);
  session.invalidate();
  const second = session.request({ source: 'new' });
  assert.equal(workers.length, 1);
  assert.equal(workers[0].sent[1].bytes, undefined);
  const late = workers[0].onmessage;
  const rejected = assert.rejects(second, { name: 'AbortError' });
  session.stop();
  await rejected;
  const third = session.request({ source: 'latest' });
  assert.equal(workers.length, 2);
  late({ data: { result: { value: 2 } } });
  workers[1].onmessage({ data: { result: { value: 3 } } });
  assert.equal((await third).value, 3);
  session.stop();
});
