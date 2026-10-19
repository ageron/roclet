import { benchmark } from '../tests/m4-benchmark.mjs';
import { assert } from '../tests/harness.mjs';
import { DocumentSession } from './document-session.mjs';
import { Notebook, newDraft, makeCell } from './edit-model.mjs';
import { symbols, renameEdits } from './compiler-tools.mjs';
const status=document.getElementById('status'),log=document.getElementById('log');
const report=s=>{log.textContent+=`PASS ${s}\n`;};
let session,notebook;
try {
  const [bytes,native]=await Promise.all([fetch('../artifacts/roclet.wasm').then(r=>r.arrayBuffer()),fetch('../artifacts/m4-conformance.json').then(r=>r.json())]);
  session=new DocumentSession(bytes);
  for (const c of native.cases) {
    status.textContent=c.name;
    const {workerMs,...result}=await session.request(c.request);
    assert.deepEqual(result,c.result);report(c.name);
  }
  const store={save:async()=>{},list:async()=>[]};
  notebook=new Notebook(bytes,store,{debounce:60000});notebook.state=newDraft();notebook.state.autoRun=false;
  notebook.state.cells=[makeCell('code','a = 2\nf = |x| x + a\nout_left = f(3)'),makeCell('code','b = 7\nout_right = {\n    dbg b\n    b * 2\n}')];
  await notebook.run();const right=notebook.result.evaluation.values[1];
  notebook.editCell(0,'a = 4\nf = |x| x + a\nout_left = f(3)');await notebook.check();
  assert.deepEqual(notebook.result.evaluation.values,[right]);assert.deepEqual(notebook.result.plan.reused,['out_right']);
  await notebook.run(0);assert.deepEqual(notebook.result.evaluation.values.map(v=>v.text),['7.0','14.0']);
  assert.deepEqual(notebook.result.evaluation.evaluated_roots,['out_left']);assert.equal(notebook.result.evaluation.events.length,1);
  report('manual checks keep independent output current; a cell run updates its branch and retains the other transcript');
  notebook.editCell(0,'a = 4\nf = |x| x + a\nout_left = {\n    crash "boom"\n    f(3)\n}');await notebook.run(0);
  assert.equal(notebook.result.status,'partial');assert.deepEqual(notebook.result.evaluation.values,[right]);assert.equal(notebook.result.evaluation.root_errors[0].root,'out_left');
  report('runtime failure is isolated without discarding the independent current result');
  notebook.change(s=>{s.cells=[makeCell('code','# 🙂 a in a comment\na = 2\ntext = "a stays text"\nout_left = a + 3'),makeCell('code','b = 7\nout_right = b * 2')];});
  await notebook.run();
  const a=symbols(notebook.result).find(d=>d.name==='a');assert.equal(a.locations.length,2);assert.equal(a.type,'Dec');
  const pos=notebook.state.cells[0].source.indexOf('a =');
  assert.throws(()=>renameEdits(notebook.result,0,pos,'b'),/already bound/);
  await notebook.rename(0,pos,'width');assert.match(notebook.state.cells[0].source,/width = 2/);assert.match(notebook.state.cells[0].source,/out_left = width \+ 3/);
  assert.match(notebook.state.cells[0].source,/# 🙂 a in a comment/);assert.match(notebook.state.cells[0].source,/"a stays text"/);
  notebook.undo();assert.match(notebook.state.cells[0].source,/\na = 2/);
  report('checked UTF-8 locations power atomic rename; comments/strings stay literal, collisions are rejected, undo restores all edits');
  const escaped = await session.request({operation:'document',action:'analyze',format:'roc',source:'# %%\n# roclet:literal-marker "# %%"\na = 3\na\n'});
  assert.equal(escaped.status,'ok');
  const mapped=symbols(escaped).find(d=>d.name==='a');
  assert.equal(mapped.locations[0].from,escaped.model.cells[0].source.indexOf('a ='));
  report('semantic locations target normalized editable cells even when the imported file contains escaped markers');
  const timings=await benchmark(session);
  log.textContent+=`BENCHMARK ${JSON.stringify(timings)}\n`;
  document.documentElement.dataset.summary=JSON.stringify({parityCases:native.cases.length,timings});
  status.textContent='PASS — native/WASM parity, reactive model, rename, and benchmark';document.documentElement.dataset.result='pass';
} catch(error) {status.textContent='FAIL';log.textContent+=error.stack??error.message;document.documentElement.dataset.result='fail';}
finally{session?.stop();notebook?.dispose();}
