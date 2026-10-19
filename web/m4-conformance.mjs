import { benchmark } from '../tests/m4-benchmark.mjs';
import { assert, compilerSemantics } from '../tests/harness.mjs';
import { DocumentSession } from './document-session.mjs';
import { Studio, newDraft, makeCell } from './studio-model.mjs';
import { symbols, renameEdits } from './compiler-tools.mjs';
const status=document.getElementById('status'),log=document.getElementById('log');
const report=s=>{log.textContent+=`PASS ${s}\n`;};
let session,studio;
try {
  const [bytes,native]=await Promise.all([fetch('../artifacts/roclet.wasm').then(r=>r.arrayBuffer()),fetch('../artifacts/m4-conformance.json').then(r=>r.json())]);
  session=new DocumentSession(bytes);
  for (const c of native.cases) {
    status.textContent=c.name;
    const {workerMs,...result}=await session.request(c.request);
    assert.deepEqual(compilerSemantics(result),compilerSemantics(c.result));report(c.name);
  }
  const store={save:async()=>{},list:async()=>[]};
  studio=new Studio(bytes,store,{debounce:60000});studio.state=newDraft();studio.state.autoRun=false;
  studio.state.cells=[makeCell('code','a = 2\nf = |x| x + a\nout_left = f(3)'),makeCell('code','b = 7\nout_right = {\n    dbg b\n    b * 2\n}')];
  await studio.run();const right=studio.result.evaluation.values[1];
  studio.editCell(0,'a = 4\nf = |x| x + a\nout_left = f(3)');await studio.check();
  assert.deepEqual(studio.result.evaluation.values,[right]);assert.deepEqual(studio.result.plan.reused,['out_right']);
  await studio.run(0);assert.deepEqual(studio.result.evaluation.values.map(v=>v.text),['7.0','14.0']);
  assert.deepEqual(studio.result.evaluation.evaluated_roots,['out_left']);assert.equal(studio.result.evaluation.events.length,1);
  report('manual checks keep independent output current; a cell run updates its branch and retains the other transcript');
  studio.editCell(0,'a = 4\nf = |x| x + a\nout_left = {\n    crash "boom"\n    f(3)\n}');await studio.run(0);
  assert.equal(studio.result.status,'partial');assert.deepEqual(studio.result.evaluation.values,[right]);assert.equal(studio.result.evaluation.root_errors[0].root,'out_left');
  report('runtime failure is isolated without discarding the independent current result');
  studio.change(s=>{s.cells=[makeCell('code','# 🙂 a in a comment\na = 2\ntext = "a stays text"\nout_left = a + 3'),makeCell('code','b = 7\nout_right = b * 2')];});
  await studio.run();
  const a=symbols(studio.result).find(d=>d.name==='a');assert.equal(a.locations.length,2);assert.equal(a.type,'Dec');
  const pos=studio.state.cells[0].source.indexOf('a =');
  assert.throws(()=>renameEdits(studio.result,0,pos,'b'),/already bound/);
  await studio.rename(0,pos,'width');assert.match(studio.state.cells[0].source,/width = 2/);assert.match(studio.state.cells[0].source,/out_left = width \+ 3/);
  assert.match(studio.state.cells[0].source,/# 🙂 a in a comment/);assert.match(studio.state.cells[0].source,/"a stays text"/);
  studio.undo();assert.match(studio.state.cells[0].source,/\na = 2/);
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
finally{session?.stop();studio?.dispose();}
