// Side-by-side contracts: two notebook panels, each with its own worker and
// engine, in the real editor UI. Panels are found through their roots
// ([data-panel=left|right]), never through global ids.
import { editorFor } from './cell-editor.mjs';
import { startNotebook, workbench } from './edit.mjs';
import { DraftStore } from './edit-store.mjs';
import { newDraft, makeCell, requestFor, independentCopy } from './edit-model.mjs';
import { DocumentSession } from './document-session.mjs';
import { assert } from '../tests/harness.mjs';
const name = `roclet-dual-test-${crypto.randomUUID()}`, store = new DraftStore(name);
let notebook, bench, log = '', count = 0;
const post = data => parent.postMessage({rocletDualTest:true,...data},new URL(document.baseURI).origin);
const report = text => { count++; log += `PASS ${text}\n`; post({status:`${count} checks passed…`,log}); };
const until = async (predicate, what = 'UI') => { for (let i=0;i<3000;i++) { if (predicate()) return; await new Promise(resolve=>setTimeout(resolve,20)); } throw new Error(`Timed out waiting for ${what}`); };
const frame = () => new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
const $ = id => document.getElementById(id);
const L = () => bench.left.notebook, R = () => bench.right.notebook;
const root = slot => document.querySelector(`[data-panel="${slot}"]`);
const cells = slot => [...root(slot).querySelectorAll('.cell')];
const part = (slot, name) => root(slot).querySelector(`[data-part="${name}"]`);
const byRoot = result => Object.fromEntries((result?.evaluation?.values ?? []).map(value=>[value.root,value]));
const texts = result => Object.fromEntries((result?.evaluation?.values ?? []).map(value=>[value.root,value.text]));
const visible = node => node.getClientRects().length > 0;
const compact = () => innerWidth < 900;
// In the compact layout only the active panel is displayed.
const show = async slot => { bench.activate(bench.panel(slot)); await frame(); };
const key = (value, extra={}) => {
  if(extra.metaKey && !/Mac/.test(navigator.platform)) extra={...extra,metaKey:false,ctrlKey:true};
  const event=new KeyboardEvent('keydown',{key:value,bubbles:true,cancelable:true,...extra}); document.activeElement.dispatchEvent(event); return event;
};
// Every request a panel's session sends, the response, and whether the other
// panel's session had a request in flight at that moment.
const sent = {left:[], right:[]}, hooks = {};
function watch(slot) {
  const session = bench.panel(slot).notebook.session;
  if (session.watched) return;
  const request = session.request.bind(session); session.watched = true;
  session.request = (body, options) => {
    const other = bench.panel(slot === 'left' ? 'right' : 'left')?.notebook.session;
    const entry = {request:body, overlap:!!other?.pending}; sent[slot].push(entry);
    const pending = request(body, options); pending.then(result=>{entry.result=result;},()=>{});
    hooks[slot]?.(); return pending;
  };
}
const geometry = area => `Geometry := [].{ area : U64\narea = ${area} }`;
function draft(title, sources, area) {
  const record = newDraft(title);
  record.cells = sources.map(([kind, source]) => makeCell(kind, source));
  record.files = [{path:'Geometry.roc', source:geometry(area)}]; record.autoRun = false;
  return record;
}
const alpha = () => draft('Alpha', [
  ['markdown', '# Alpha\nThe left notebook.'],
  ['code', 'import Geometry\nout_area = Geometry.area'],
  ['code', 'width = 5\nout_width = {\n    dbg "left-111"\n    width\n}'],
  ['code', 'expect width == 5'],
  ['code', 'height = 3\nout_other = height * 2'],
], 15);
const beta = () => draft('Beta', [
  ['code', 'out_b = {\n    dbg "right-222"\n    7\n}'],
  ['code', 'import Geometry\nout_area = Geometry.area'],
  ['code', 'expect 1 == 2'],
  ['code', 'scale = 2\nout_scaled = scale * 10'],
], 24);
// Values of a document evaluated alone, in a fresh worker of its own.
async function alone(state) {
  const session = new DocumentSession(L().session.bytes);
  try { return texts(await session.request({...requestFor(state, 'evaluate'), compact:true, isolateErrors:true})); }
  finally { session.stop(); }
}
// Count compilations of the compiler module across both panels and the highlighter.
const compile = WebAssembly.compile;
let compiles = 0;
WebAssembly.compile = (...args) => { compiles++; return compile.apply(WebAssembly, args); };
try {
  notebook = await startNotebook(store); bench = workbench(); assert(notebook && bench, 'The editor did not start');
  clearTimeout(notebook.timer); notebook.setAuto(false);
  watch('left');
  await bench.open('left', {record:alpha()});
  await until(()=>sent.left[0]?.result, 'the left notebook’s first response');
  const leftFirst = sent.left[0].result;
  await bench.open('right', {record:beta()}, {focus:false}); watch('right');
  await until(()=>sent.right[0]?.result, 'the right notebook’s first response');
  const rightFirst = sent.right[0].result;
  assert(rightFirst.workspaceCache.hits >= 1, `Right worker did not reuse stored compiler artifacts: ${JSON.stringify(rightFirst.workspaceCache)}`);
  assert(rightFirst.workspaceCache.misses <= leftFirst.workspaceCache.misses, `Right worker missed more than the left one did cold: ${rightFirst.workspaceCache.misses} > ${leftFirst.workspaceCache.misses}`);
  report('D9 a panel opened after another has run starts from the shared compiler artifact cache');

  await frame();
  assert.equal(document.querySelectorAll('.notebook-panel').length, 2);
  assert.equal($('workbench').dataset.panels, '2'); assert.equal($('workbench').dataset.layout, compact() ? 'tabs' : 'columns');
  for (const [slot, title] of [['left','Alpha'],['right','Beta']]) {
    await show(slot);
    const panel = root(slot).getBoundingClientRect(), bar = part(slot,'title-bar').getBoundingClientRect(), status = part(slot,'status-bar').getBoundingClientRect();
    assert(Math.abs(bar.top - panel.top) <= 1, `${slot} title bar is not at the top of its panel`);
    assert(Math.abs(status.bottom - panel.bottom) <= 1 && status.bottom <= innerHeight + 1, `${slot} status bar is not at the bottom of its panel`);
    assert.equal(part(slot,'title').value, title);
    assert(!root(slot).inert && root(slot).dataset.loading === 'false', `${slot} panel is still loading`);
    assert.equal(part(slot,'status-bar').querySelectorAll('button').length, 0, `${slot} status bar holds a button`);
    assert(part(slot,'run').parentElement === part(slot,'stop').parentElement && part(slot,'run').parentElement.classList.contains('run-slot'), `${slot} Run and Stop do not share a slot`);
    assert(part(slot,'title-bar').contains(part(slot,'title')) && part(slot,'status-bar').contains(part(slot,'status')), `${slot} parts are misplaced`);
  }
  assert.equal(document.title, 'Roclet: Alpha | Beta');
  assert(document.documentElement.scrollWidth <= innerWidth, 'The page overflowed horizontally');
  if (compact()) {
    assert(!$('panel-tabs').hidden, 'No tabs in the compact layout');
    assert.equal($('panel-tabs').querySelectorAll('[role=tab]').length, 2);
    assert.equal(['left','right'].filter(slot=>visible(root(slot))).length, 1);
  } else {
    assert($('panel-tabs').hidden, 'Tabs shown in the columns layout');
    assert(root('left').getBoundingClientRect().right <= root('right').getBoundingClientRect().left + 1, 'Panels are not side by side');
  }
  report('D1 each panel has its own title bar at the top and status bar at the bottom; titles, document title and layout (columns or tabs) are right');

  // Search belongs to a panel, including its controls, query and undo history.
  await show('left');bench.left.find();
  part('left','find-query').value='Geometry';part('left','find-query').dispatchEvent(new Event('input'));
  await until(()=>part('left','find-results').textContent==='1 of 2','left search');
  await show('right');bench.right.find();
  part('right','find-query').value='scale';part('right','find-query').dispatchEvent(new Event('input'));
  part('right','replace-query').value='factor';part('right','replace-query').dispatchEvent(new Event('input'));
  await until(()=>part('right','find-results').textContent==='1 of 3','right search');
  const leftSource=JSON.stringify(L().state.cells),rightSource=R().state.cells.map(c=>c.source);
  part('right','replace-all').click();await until(()=>part('right','find-results').textContent==='No matches','replacement');
  assert.equal(JSON.stringify(L().state.cells),leftSource);
  assert.equal(part('left','find-query').value,'Geometry');
  assert.match(R().state.cells[3].source,/out_factord = factor/);
  part('right','find-close').click();bench.right.undo(false);
  assert.deepEqual(R().state.cells.map(c=>c.source),rightSource);
  await show('left');part('left','find-close').click();
  report('Find & Replace keeps independent queries and changes only the intended panel, with one-step undo');

  // run() saves first. Independent IndexedDB transactions can finish far
  // enough apart for a warm worker to reply before the other is dispatched.
  // Release both real session requests together after both saves complete;
  // keep the overlap assertion below so serialized worker dispatch still fails.
  const sessions = [L().session, R().session], requests = sessions.map(session=>session.request);
  let releaseDispatch, readyToDispatch = 0;
  const dispatchGate = new Promise(resolve=>{releaseDispatch=resolve;});
  sessions.forEach((session,index)=>{
    session.request = async (...args) => {
      readyToDispatch++;
      await dispatchGate;
      return requests[index].apply(session,args);
    };
  });
  let leftRun, rightRun;
  const runs = Promise.all([L().run(), R().run()]);
  try {
    await until(()=>readyToDispatch===2, 'both runs to finish saving before dispatch');
    releaseDispatch();
    [leftRun, rightRun] = await runs;
  } finally {
    releaseDispatch();
    sessions.forEach((session,index)=>{session.request=requests[index];});
  }
  assert(leftRun && rightRun, 'A concurrent run did not complete');
  assert(sent.left.at(-1).overlap || sent.right.at(-1).overlap, 'The two requests were never in flight at the same time');
  assert.deepEqual(texts(leftRun), await alone(L().state));
  assert.deepEqual(texts(rightRun), await alone(R().state));
  assert.equal(texts(leftRun).out_area, '15'); assert.equal(texts(rightRun).out_area, '24');
  for (const result of [leftRun, rightRun]) assert(!JSON.stringify(result).includes('protocol_error'), 'A response reported a protocol error');
  report('D2 both panels evaluate concurrently and each produces the values its document produces alone');

  await show('left');
  assert(cells('left')[2].querySelector('.debug')?.textContent.includes('left-111'), 'Left dbg is missing from cell 3');
  assert.equal(cells('left').filter(cell=>cell.textContent.includes('left-111')).length, 1);
  assert.match(cells('left')[3].querySelector('.tests .result-heading').textContent, /1 passed/);
  await show('right');
  assert(cells('right')[0].querySelector('.debug')?.textContent.includes('right-222'), 'Right dbg is missing from cell 1');
  assert.equal(cells('right').filter(cell=>cell.textContent.includes('right-222')).length, 1);
  assert.match(cells('right')[2].querySelector('.tests .result-heading').textContent, /1 failed/);
  assert(!root('right').textContent.includes('left-111') && !root('left').textContent.includes('right-222'), 'Debug output crossed panels');
  for (const result of [leftRun, rightRun]) assert(result.evaluation.events.length && result.evaluation.events.every(event=>event.cell != null), 'An event is unattributed');
  assert(leftRun.evaluation.events.every(event=>event.message.includes('left-111')) && rightRun.evaluation.events.every(event=>event.message.includes('right-222')), 'Events reached the wrong notebook');
  report('D6 dbg and expect results appear only in their own panel and cell; every event is attributed');

  assert.equal(compiles, 1, `Expected one compilation, saw ${compiles}`);
  report('D10 both notebook workers and the highlighter share one compiled module');

  await L().run(); await R().run();
  const again = await L().run();
  assert.equal(again.workspaceCache.prepared_hits, 1); assert.equal(again.workspaceCache.analyses, 0); assert.equal(again.workspaceCache.frontend_builds, 0);
  L().editCell(4, 'height = 4\nout_other = height * 2'); await R().run();
  const edited = await L().run(4);
  assert.equal(edited.workspaceCache.analyses, 1);
  assert.deepEqual(edited.evaluation.evaluated_roots, ['out_other']);
  assert.equal(edited.workspaceCache.executions, edited.evaluation.evaluated_roots.length);
  report('D3 the left engine keeps its retained revision across right-panel runs and re-analyses only after its own edit');

  await L().run(undefined, {automatic:true});
  for (let i = 0; i < 5; i++) { R().editCell(3, `scale = ${i + 3}\nout_scaled = scale * 10`); await R().run(undefined, {automatic:true}); }
  await show('left');
  const kept = [1, 2].map(i=>cells('left')[i].querySelector('.value'));
  L().editCell(4, 'height = 5\nout_other = height * 2');
  const reuse = byRoot(await L().run(undefined, {automatic:true}));
  assert.equal(reuse.out_area.reused, true); assert.equal(reuse.out_width.reused, true); assert.equal(reuse.out_other.reused, false);
  assert.equal(reuse.out_other.text, '10.0');
  assert([1, 2].every((i, n)=>cells('left')[i].querySelector('.value') === kept[n]), 'Unchanged outputs were re-rendered');
  report('D4 reuse in the left engine is unaffected by five edits and runs in the right panel; unchanged outputs keep their DOM');

  L().editCell(4, '# Only a comment changed\nheight = 5\nout_other = height * 2');
  const commented = await L().run(undefined, {automatic:true});
  assert(Object.values(byRoot(commented)).every(value=>value.reused), 'A comment edit re-evaluated a root');
  assert.deepEqual(commented.evaluation.evaluated_roots, []);
  const scope = commented.graph.scope;
  R().change(s=>{ s.cells.push(makeCell('code', 'Point := { x : F64, y : F64 }')); });
  const typed = await R().run(undefined, {automatic:true});
  assert(typed && typed.status !== 'diagnostic', `The type declaration did not check: ${JSON.stringify(typed?.model?.diagnostics ?? typed?.failure)}`);
  assert.equal((await L().run(undefined, {automatic:true})).graph.scope, scope);
  report('D4b a comment edit reuses every left root; a type declaration in the right notebook leaves the left graph scope unchanged');

  // A previous run may have persisted this preference in the same browser.
  if ($('engine-details').getAttribute('aria-pressed') !== 'true') $('engine-details').click();
  for (const slot of ['left','right']) {
    await show(slot);
    assert(visible(part(slot,'engine-status')), `${slot} engine details are hidden`);
    assert.match(part(slot,'engine-status').textContent, /^worker \d+ ms · \d+ evaluated · \d+ reused · \d+ MiB$/);
  }
  const memory = [L(), R()].map(n=>n.result.transportMetrics.memoryBytes);
  assert(memory.every(bytes=>bytes > 0 && bytes <= 256 * 1024 * 1024), `Worker memory out of bounds: ${memory}`);
  assert(memory[0] + memory[1] <= 512 * 1024 * 1024, `Combined worker memory ${memory[0] + memory[1]}`);
  assert([L(), R()].every(n=>n.result.workspaceCache.image_retries === 0), 'A warm run retried its image buffer');
  report(`D11 each panel shows its own worker memory (${memory.map(bytes=>Math.round(bytes / 1048576)).join(' and ')} MiB), within bounds, with no image retries`);

  await show('left'); cells('left')[1].focus();
  assert(bench.active === bench.left, `The ${bench.slotOf(bench.active)} panel is active`);
  $('document-menu').querySelector('summary').click(); $('project-files').click(); assert($('project-dialog').open);
  assert.equal($('project-path').value, 'Geometry.roc');
  $('project-source').value = geometry(16); $('project-save').click(); $('project-dialog').querySelector('[data-close]').click();
  assert.equal(L().state.files[0].source, geometry(16)); assert.equal(R().state.files[0].source, geometry(24));
  assert.equal(texts(await L().run()).out_area, '16'); assert.equal(texts(await R().run()).out_area, '24');
  report('D12 project files belong to their panel: editing the left Geometry.roc changes only the left value');

  await show('left');
  const rightSelection = () => cells('right').map(cell=>cell.dataset.selected);
  const rightBefore = rightSelection();
  cells('left')[1].querySelector('.cm-content').focus(); key('Escape'); assert(document.activeElement === cells('left')[1]);
  key('ArrowDown'); assert.equal(cells('left')[2].dataset.selected, 'true'); assert.deepEqual(rightSelection(), rightBefore);
  await show('right');
  const leftHistory = L().history.length, original = R().state.cells[3].source;
  cells('right')[3].querySelector('.cm-content').focus(); R().editCell(3, 'scale = 99\nout_scaled = scale * 10'); key('Escape');
  key('z', {metaKey:true}); assert.equal(R().state.cells[3].source, original); assert.equal(L().history.length, leftHistory);
  await show('left'); root('right').dispatchEvent(new PointerEvent('pointerdown', {bubbles:true}));
  assert(bench.active === bench.right, `The ${bench.slotOf(bench.active)} panel is active`);
  const click = HTMLAnchorElement.prototype.click; let downloaded = null;
  HTMLAnchorElement.prototype.click = function () { downloaded = this.download; };
  try { $('download').click(); await until(()=>downloaded || part('right','notice').textContent, 'a download'); }
  finally { HTMLAnchorElement.prototype.click = click; }
  assert(downloaded ? downloaded.startsWith('Beta') : /Fix the errors/.test(part('right','notice').textContent), `Download did not act on the right notebook: ${downloaded}`);
  for (const slot of ['left','right']) { await show(slot); await until(()=>root(slot).querySelector('.cm-content .tok-number,.cm-content .tok-keyword'), `${slot} highlighting`); }
  report('D13 keyboard selection and undo stay in their panel; a pointer makes a panel active and header commands follow it; both panels are highlighted');

  const leftWorker = L().session.worker, rightWorker = R().session.worker;
  assert(rightWorker, 'The right panel has no worker');
  hooks.left = () => { hooks.left = null; L().stop(); };
  const [stopped, finished] = await Promise.all([L().run(), R().run()]);
  assert.equal(stopped, null); assert.match(L().status, /^Stopped/); assert.notEqual(L().session.worker, leftWorker);
  assert(finished?.evaluation?.values?.length, 'The right run did not finish'); assert.equal(R().session.worker, rightWorker);
  assert.doesNotMatch(R().status, /^Stopped/);
  assert(texts(await L().run()).out_area, 'The left notebook did not run again after Stop');
  assert.equal(compiles, 1, `A restarted worker compiled again: ${compiles}`);
  report('D7 Stop in one panel replaces only its worker; the other run finishes; the restarted worker reuses the compiled module (D10)');

  L().editCell(4, 'height = 7\nout_other = height * 2'); R().editCell(3, 'scale = 7\nout_scaled = scale * 10');
  await until(()=>L().saveStatus === 'Saved in this browser' && R().saveStatus === 'Saved in this browser', 'both saves');
  const [savedLeft, savedRight] = await Promise.all([store.get(L().state.id), store.get(R().state.id)]);
  assert.equal(savedLeft.cells[4].source, 'height = 7\nout_other = height * 2'); assert.equal(savedRight.cells[3].source, 'scale = 7\nout_scaled = scale * 10');
  report('D14 edits in both panels within one debounce window both save');

  await bench.open('left', {record:independentCopy(L().state)});
  const switched = await L().run(undefined, {automatic:true});
  assert.deepEqual(sent.left.at(-1).request.reactivity, {reset:true});
  assert.deepEqual(switched.plan.reused, []); assert(switched.evaluation.values.every(value=>value.reused === false), 'A switched document reused results');
  R().editCell(3, 'scale = 8\nout_scaled = scale * 10');
  const rightReuse = byRoot(await R().run(undefined, {automatic:true}));
  assert.equal(rightReuse.out_b.reused, true); assert.equal(rightReuse.out_scaled.reused, false);
  report('D5 a document switch in the left panel resets its engine baseline only; the right panel keeps reusing');

  await show('right'); cells('right')[0].focus(); assert(bench.active === bench.right, `The ${bench.slotOf(bench.active)} panel is active`);
  const leftId = L().state.id, rightId = R().state.id;
  // Recent notebooks lists drafts for the active panel and marks the one open
  // in the other panel; choosing it is refused like any other open.
  const chooseLeft = async () => {
    $('recent').click(); const entry = () => $('recent-list').querySelector(`[data-notebook-id="${leftId}"]`);
    await until(entry, 'the recent list');
    assert.equal($('recent-list').querySelector(`[data-notebook-id="${rightId}"]`)?.getAttribute('aria-current'), 'true');
    assert.match(entry().textContent, /Open in the left panel/); entry().click();
  };
  const refusal = () => part('right','notice').textContent.includes('already open in the left panel');
  await chooseLeft(); await until(refusal, 'the refusal notice'); assert.equal(R().state.id, rightId); assert(!$('recent-dialog').open);
  [...part('right','notice').querySelectorAll('button')].find(b=>b.textContent==='Go to it').click();
  await until(()=>bench.active === bench.left, 'Go to it');
  await show('right'); await chooseLeft(); await until(refusal, 'the refusal notice');
  [...part('right','notice').querySelectorAll('button')].find(b=>b.textContent==='Open an independent copy here').click();
  await until(()=>R().state.id !== rightId, 'the independent copy');
  assert.notEqual(R().state.id, leftId); assert.equal(R().state.title, `${L().state.title} (copy)`);
  const leftKeys = new Set(L().state.cells.map(cell=>cell.key));
  assert(R().state.cells.every(cell=>!leftKeys.has(cell.key)), 'The copy shares cell keys');
  await until(()=>R().saveStatus === 'Saved in this browser', 'the copy to save');
  assert(![L(), R()].some(n=>/Another tab|Not saved/.test(n.saveStatus)), 'A save reported a conflict');
  report('D15 a draft open in one panel is refused in the other, with Go to it and an independent copy (new id, fresh keys, “(copy)”)');
  assert.deepEqual(texts(await R().run()), texts(await L().run()));
  report('D2b an independent copy evaluated by the other engine produces identical values');

  const closingSession = R().session;
  await bench.close('right');
  assert.equal(closingSession.worker, null); assert.equal(bench.panels.length, 1);
  assert.equal(document.querySelectorAll('.notebook-panel').length, 1); assert.equal($('workbench').dataset.panels, '1');
  assert(!document.getElementById('right-title') && $('title') && $('status') && $('notebook'), 'Legacy ids changed after closing');
  await bench.open('right', {record:draft('Gamma', [['code', 'out_gamma = 3']], 1)}, {focus:false});
  const gamma = R().state.id; clearTimeout(R().timer);
  await bench.close('left');
  assert.equal(L().state.id, gamma); assert.equal(part('left','title').value, 'Gamma'); assert.equal(bench.panels.length, 1);
  await L().run(undefined, {automatic:true});
  assert.deepEqual(sent.left.at(-1).request.reactivity, {reset:true});
  report('D16 closing the right panel disposes its worker and restores one panel with legacy ids; closing the left panel moves the right document left with a reset');
  // A panel opening its first notebook shows a loading state, and evaluates
  // only after its document is rendered.
  const createPanel = bench.createPanel; let releaseParse, held = [];
  const parseGate = new Promise(resolve=>{ releaseParse = resolve; });
  bench.createPanel = options => {
    const created = createPanel(options), session = created.notebook.session, request = session.request.bind(session);
    session.request = async (body, callbacks) => { held.push(body.action); if (held.length === 1) await parseGate; return request(body, callbacks); };
    return created;
  };
  const delta = draft('Delta', [['markdown', '# Delta prose'], ['code', 'out_delta = 4']], 1); delta.autoRun = true;
  let opening;
  try {
    opening = bench.open('right', {record:delta}, {focus:false});
    await until(()=>held.length === 1, 'the right panel’s first request');
    assert.equal(root('right').dataset.loading, 'true'); assert(root('right').inert);
    assert.deepEqual(held, ['parse'], 'The right panel evaluated before it was shown');
    if (!compact()) assert(visible(part('right','panel-loading')) && getComputedStyle(part('right','panel-scroll')).visibility === 'hidden', 'The loading state is not shown');
    assert.equal(root('left').dataset.loading, 'false'); assert(!root('left').inert);
    releaseParse(); await opening;
  } finally { releaseParse(); bench.createPanel = createPanel; }
  assert.equal(root('right').dataset.loading, 'false'); assert(!root('right').inert);
  assert.equal(part('right','title').value, 'Delta'); assert.equal(root('right').querySelector('.cell-preview h1')?.textContent, 'Delta prose');
  await until(()=>byRoot(R().result).out_delta?.text === '4.0', 'the revealed panel to evaluate').catch(error=>{throw new Error(`${error.message}: ${R().status}; ${JSON.stringify(held)}; ${JSON.stringify(R().result?.evaluation?.values)}`);});
  assert(held.includes('evaluate')); assert.equal(document.title, 'Roclet: Gamma | Delta');
  // Keyboard help is reached from Help and `?`, also in the second panel.
  await show('right'); cells('right')[0].focus(); assert(bench.active === bench.right);
  key('?', {shiftKey:true}); assert($('shortcuts-dialog').open, '? did not open keyboard help'); $('shortcuts-dialog').close();
  $('help-menu').open = true; $('shortcuts').click(); assert($('shortcuts-dialog').open && !$('help-menu').open, 'Help menu did not open keyboard help'); $('shortcuts-dialog').close();
  await bench.close('right');
  report('D17 a panel opening its first notebook stays in a loading state until its prose is rendered, then evaluates; the tab title names both notebooks; keyboard help opens from Help and ? in the second panel, whose status bar has no buttons');
  // Another tab (here a second DraftStore on the same database) saves the
  // right draft; closing it must not dead-end.
  await bench.open('right', {record:draft('Epsilon', [['code', 'out_e = 5']], 1)}, {focus:false}); clearTimeout(R().timer);
  await until(()=>R().saveStatus === 'Saved in this browser', 'the right draft to save');
  const other = new DraftStore(name), stored = await other.get(R().state.id);
  await other.save({...stored, title:`${stored.title} elsewhere`}); other.close();
  assert.equal(await bench.close('right'), false); assert.equal(bench.panels.length, 2);
  assert.match(R().saveStatus, /^Not saved: Another tab changed this draft\. .*reopening it\. Download a copy\.$/); assert(!/\.\./.test(R().saveStatus), 'Doubled punctuation');
  const closeNotice = part('right','notice'), action = label => [...closeNotice.querySelectorAll('button')].find(b=>b.textContent===label);
  assert.match(closeNotice.textContent, /right notebook could not be saved, so the right panel stays open/);
  assert(action('Download a copy') && action('Close without saving (discards unsaved changes in this tab)'), 'The notice lacks its actions');
  assert.equal(await bench.close('right'), false, 'A retry closed without saving');
  action('Close without saving (discards unsaved changes in this tab)').click();
  await until(()=>bench.panels.length === 1, 'closing without saving');
  assert(!document.getElementById('right-title') && $('title') && $('status') && $('notebook'), 'Legacy ids changed after closing');
  report('D18 closing a panel whose draft another tab changed keeps it open with Download and Close without saving; the latter restores one panel with legacy ids');

  // Package prompts with a stub dialog driver; the real file picker is
  // tools/browser-dual-package-probe.mjs.
  const archive = 'FPCEjLpsoY5fJ6nDBCeJQ1s6aMTQjMWUYAVQu6QdNuzr.tar.zst';
  const bundle = new Uint8Array(await fetch(new URL(`../artifacts/${archive}`, import.meta.url)).then(r=>{assert(r.ok,'Run zig build test to write the package fixture');return r.arrayBuffer();}));
  const missing = n => new URL(`../artifacts/missing-${n}-${crypto.randomUUID()}/${archive}`, import.meta.url).href;
  const stub = {prompts:0, current:null,
    open(details) { this.prompts++; const current = this.current = {...details}; return new Promise((resolve, reject)=>{ current.resolve = resolve; details.signal.addEventListener('abort', ()=>{ current.closed = true; reject(new DOMException('Package loading cancelled','AbortError')); }); }); },
    update(requesters) { if (this.current) this.current.requesters = requesters; }};
  const driver = bench.prompts.driver; bench.prompts.driver = stub;
  const packaged = (title, url) => { const record = newDraft(title); record.preamble = `app [] { geom: "${url}" }`; record.cells = [makeCell('code', 'import geom.Geometry\nout_answer = Geometry.answer')]; record.autoRun = false; return record; };
  const openPackages = async url => {
    await bench.open('left', {record:packaged('Package left', url)}); clearTimeout(L().timer);
    await bench.open('right', {record:packaged('Package right', url)}, {focus:false}); clearTimeout(R().timer);
  };
  try {
    await openPackages(missing(1));
    const both = Promise.all([L().run(), R().run()]);
    await until(()=>stub.current?.requesters?.length === 2, 'both panels to wait for the package');
    assert.equal(stub.prompts, 1); assert.deepEqual(stub.current.requesters, ['Package left','Package right']);
    stub.current.resolve(bundle.slice());
    assert.deepEqual((await both).map(result=>result?.evaluation?.values?.[0]?.text), ['42.0','42.0']);
    assert.equal(stub.prompts, 1);
    // Fresh workers: a worker that installed the archive under one URL already
    // knows its hash and would not ask again.
    await openPackages(missing(2)); L().stop(); R().stop();
    const waiting = [L().run(), R().run()];
    await until(()=>stub.prompts === 2 && stub.current?.requesters?.length === 2, 'the second shared prompt');
    L().stop(); await waiting[0]; await frame();
    assert(!stub.current.closed, 'Stop in one panel closed the shared prompt'); assert.deepEqual(stub.current.requesters, ['Package right']);
    stub.current.resolve(bundle.slice());
    assert.equal((await waiting[1])?.evaluation?.values?.[0]?.text, '42.0'); assert.match(L().status, /^Stopped/);
    R().stop(); assert.equal((await R().run())?.evaluation?.values?.[0]?.text, '42.0');
    assert.equal(stub.prompts, 2, 'A fresh worker prompted again for a stored package');
  } finally { bench.prompts.driver = driver; }
  report('D8 both panels needing one package share one prompt; Stop in one leaves it open for the other; a fresh worker restores the archive');

  await Promise.all(bench.panels.map(panel=>panel.notebook.persist()));
  notebook.dispose(); store.close();
  await new Promise((resolve,reject)=>{const request=indexedDB.deleteDatabase(name); request.onsuccess=resolve;request.onerror=()=>reject(request.error);});
  post({status:`PASS — ${count} side-by-side contracts`,log,result:'pass'});
} catch (error) { post({status:'FAIL',log:log+(error.stack??error.message),result:'fail'}); }
finally { notebook?.dispose(); store.close(); WebAssembly.compile = compile; }
