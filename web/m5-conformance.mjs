import {assert} from '../tests/harness.mjs';
import {startNotebook} from './edit.mjs';
import {normalizeDisplay,renderDisplay} from './display-view.mjs';
import {captureExport,exportBundle,importBundle,exportReport} from './sharing.mjs';
import {unzip,text} from './archive.mjs';
import {DocumentSession} from './document-session.mjs';
let notebook,session,count=0,log='';
const report=message=>{count++;log+=`PASS ${message}\n`;parent.postMessage({rocletM5:true,status:`${count} checks passed…`,log},new URL(document.baseURI).origin);};
const until=async predicate=>{const start=performance.now();while(!predicate()){if(performance.now()-start>20000) throw new Error('Timed out waiting for UI');await new Promise(r=>setTimeout(r,25));}};
try {
  const bytes=await fetch('../artifacts/roclet.wasm').then(r=>r.arrayBuffer()),compiler=await fetch('../artifacts/manifest.json').then(r=>r.json());
  session=new DocumentSession(bytes);
  const fixtures=(await fetch('../tests/documents.json').then(r=>r.json())).filter(f=>f.name.startsWith('M5:'));
  for(const fixture of fixtures) {
    const result=await session.request(fixture.request);assert.equal(result.status,'ok');
    assert.deepEqual(result.evaluation.values.map(v=>v.display?.kind??null),fixture.expect.display_kinds);
    if(fixture.expect.evaluated_values) assert.deepEqual(result.evaluation.values.map(v=>v.text),fixture.expect.evaluated_values);
    if(fixture.expect.preview_rows) assert.deepEqual(result.evaluation.values.map(v=>v.display.rows.length),fixture.expect.preview_rows);
    if(fixture.expect.events) assert.equal(result.evaluation.events.length,fixture.expect.events.length);
    report(fixture.name);
  }
  const oversize=await session.request({operation:'document',action:'evaluate',format:'roc',source:'import Display\ngrow = |s, n| if n == 0 { s } else { grow(Str.concat(s, s), n - 1) }\nout_1 = Display.image("Too big", "image/png", grow("AAAA", 18))'});
  assert(oversize.status==='ok',JSON.stringify(oversize));assert.match(oversize.evaluation.values[0].text,/Image preview omitted/);assert.equal(oversize.evaluation.values[0].display.kind,'text');
  const custom=await session.request({operation:'document',action:'evaluate',format:'roc',source:'import Display\nout_1 = Display.({text: "custom"})',modules:[{name:'Display',content:'Display := { text : Str }'}]});assert.equal(custom.status,'ok');assert.equal(custom.evaluation.values[0].display,undefined);
  report('oversized images return readable text; replacement modules cannot opt into trusted display decoding');
  const table={version:1,kind:'table',text:'Plain table',columns:['Exact','Label'],rows:Array.from({length:123},(_,i)=>['9007199254740993',`Row ${i+1}`]),row_count:123,column_count:2};
  const view=renderDisplay(table,table.text);document.body.append(view);assert.equal(view.querySelectorAll('tbody tr').length,50);assert.equal(view.querySelector('td').textContent,'9007199254740993');
  view.querySelector('[aria-label="Next table page"]').click();assert.match(view.querySelector('.display-pagination').textContent,/51–100/);
  view.querySelector('[aria-label="Next table page"]').click();assert.equal(view.querySelectorAll('tbody tr').length,23);assert(view.querySelector('[aria-label="Next table page"]').disabled);view.remove();
  report('tables page through bounded rows without rounding large numbers');
  assert.equal(normalizeDisplay({...table,rows:[['ragged']]}),null);assert.equal(normalizeDisplay({...table,rows:Array(201).fill(['a','b'])}),null);
  const hostile=renderDisplay({...table,columns:['<script>bad()</script>','B'],rows:[['<img src=x onerror=bad()>','x']]},'fallback');assert.equal(hostile.querySelectorAll('script,img').length,0);assert.match(hostile.textContent,/<img/);
  for(const kind of ['image/svg+xml','text/html']) {const v=renderDisplay({version:1,kind:'image',text:'alt',mime:kind,content:'PHN2Zz4='},'safe fallback');assert.equal(v.querySelectorAll('img,svg,script').length,0);assert.match(v.textContent,/safe fallback/);}
  assert.match(renderDisplay({version:999},'future fallback').textContent,/future fallback/);
  report('malformed, oversized and unknown displays fall back; table markup and SVG stay inert');
  const markdown=await session.request({operation:'document',action:'evaluate',format:'roc',source:'import Display\n# %%\nDisplay.markdown("# Safe\\n<script>alert(1)</script>\\n[unsafe](javascript:alert(1))")'});
  assert.equal(markdown.status,'ok');const md=renderDisplay(markdown.evaluation.values[0].display,markdown.evaluation.values[0].text);assert(md.querySelector('h1'));assert.equal(md.querySelectorAll('script,[href^="javascript:"]').length,0);
  report('Markdown uses the existing parser and safe DOM renderer');
  const rows=Array.from({length:205},(_,i)=>`["${i}"]`).join(',');const bounded=await session.request({operation:'document',action:'evaluate',format:'roc',source:`import Display\n# %%\nDisplay.table(["Index"], [${rows}])`});assert.equal(bounded.status,'ok');assert.equal(bounded.evaluation.values[0].display.rows.length,200);assert.equal(bounded.evaluation.values[0].display.row_count,205);
  report('Roc bounds table previews before crossing the WASM boundary');
  notebook=await startNotebook({save:async()=>{},list:async()=>[]});await until(()=>notebook.result?.status==='ok');
  await notebook.open(await fetch('../fixtures/documents/rich-outputs.roc').then(r=>r.text()),'Rich outputs.roc');notebook.setAuto(false);await notebook.run();
  assert.equal(notebook.result.status,'ok');assert.equal(document.querySelectorAll('#cells .rich-output').length,3);assert.equal(document.querySelectorAll('#cells .display-image').length,1);assert.match(document.querySelector('#cells table').textContent,/9007199254740993/);
  await until(()=>document.querySelector('#cells .display-image')?.complete);assert(document.querySelector('#cells .display-image').naturalWidth>0);
  const original=document.querySelector('#cells table'),index=notebook.state.cells.findIndex(c=>c.source.includes('width = 5'));
  notebook.editCell(index,'width = 8\nheight = 3');assert(document.contains(original));assert.equal(original.closest('.result-block').dataset.stale,'true');await notebook.run();assert.match(document.querySelector('#cells .markdown').textContent,/Rich outputs|area/);assert(notebook.result.evaluation.values.some(v=>v.text.includes('24')));
  report('the real editor renders all rich kinds, retains stale previews and updates reactive values');
  const mdIndex=notebook.state.cells.findIndex(c=>c.source.includes('Display.markdown')),mdSource=notebook.state.cells[mdIndex].source;
  notebook.editCell(mdIndex,'Display.text(width.to_str())');await notebook.run();assert.equal(document.querySelector('#cells .rich-output > pre').textContent,'8.0');
  notebook.editCell(index,'width = 9\nheight = 3');await notebook.run();assert.equal(document.querySelector('#cells .rich-output > pre').textContent,'9.0');
  notebook.editCell(mdIndex,mdSource);await notebook.run();
  report('plain-text alternatives update even when the rich envelope stays identical');
  const capture=await captureExport(notebook,compiler,{results:true,debug:true}),bundle=await exportBundle(capture),files=await unzip(await bundle.arrayBuffer());assert(!files.has('Display.roc'));assert.match(text(files.get('notebook.roc')),/import roclet\.Display/);assert.match(text(files.get('notebook.roc')),/main! =/);
  const imported=await importBundle(await bundle.arrayBuffer(),compiler);assert(imported.record.savedResults.snapshots.some(s=>s.display?.kind==='table'));await notebook.replace(imported.record);await until(()=>document.querySelectorAll('#cells .unverified .rich-output').length===3);assert.equal(notebook.state.autoRun,false);
  const html=new DOMParser().parseFromString(await (await exportReport(capture)).text(),'text/html');assert(html.querySelector('table'));assert(html.querySelector('img[src^="data:image/png;base64,"]'));assert.equal(html.querySelectorAll('script,[onerror]').length,0);assert.match(html.body.textContent,/9007199254740993/);
  report('bundles preserve unverified rich snapshots and the pinned Display package; reports preserve safe rich output');
  const runnable=await session.request({operation:'document',action:'run',format:'roc',source:'import Display\n# %%\nDisplay.table(["Exact"], [["9007199254740993"]])'});assert.equal(runnable.status,'ok');assert(runnable.evaluation.events.some(e=>e.message.includes('9007199254740993')));
  report('generated display! uses the same readable plain-text representation in script execution');
  parent.postMessage({rocletM5:true,status:`PASS — ${count} M5 rich output contracts`,log,result:'pass'},new URL(document.baseURI).origin);
} catch(error) {log+=error.stack??error.message;parent.postMessage({rocletM5:true,status:'FAIL',log,result:'fail'},new URL(document.baseURI).origin);}
finally {notebook?.dispose();session?.stop();}
