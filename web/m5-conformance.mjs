import {assert} from '../tests/harness.mjs';
import {startNotebook} from './edit.mjs';
import {normalizeDisplay,renderDisplay} from './display-view.mjs';
import {captureExport,exportBundle,importBundle,exportReport} from './sharing.mjs';
import {unzip,text} from './archive.mjs';
import {DocumentSession} from './document-session.mjs';
let notebook,session,count=0,log='';
const loadedFrames=new WeakSet(),frameLoaded=event=>{if(event.target instanceof HTMLIFrameElement)loadedFrames.add(event.target);};
document.addEventListener('load',frameLoaded,true);
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
  const markup=(kind,content)=>({version:1,kind,text:'Markup test',content});
  assert.equal(normalizeDisplay(markup('html','x'.repeat(16385))),null);
  assert.equal(normalizeDisplay(markup('svg','é'.repeat(8193))),null);
  const staticHTML=renderDisplay(markup('html','<h2>Hello</h2><script>parent.postMessage("unexpected-script","*")</script>'),'HTML');
  assert.equal(staticHTML.querySelector('iframe').getAttribute('sandbox'),'');
  assert.match(staticHTML.querySelector('iframe').srcdoc,/script-src 'none'/);
  const savedWidget=renderDisplay(markup('widget','<button>Saved</button>'),'Saved',{interactive:false});
  assert.equal(savedWidget.querySelector('iframe').getAttribute('sandbox'),'');
  assert.match(savedWidget.textContent,/Run this cell/);
  const svg=renderDisplay(markup('svg','<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="purple"/></svg>'),'Square');
  document.body.append(svg);await until(()=>svg.querySelector('img').complete);assert(svg.querySelector('img').naturalWidth>0);svg.remove();
  const script=`<input id="slider" type="range" min="1" max="10" value="2"><output id="value"></output><script>
    const input=document.getElementById('slider'),output=document.getElementById('value');
    input.oninput=()=>output.value=String(Number(input.value)*3);
    input.value=7;input.dispatchEvent(new Event('input'));
    let parentBlocked=false,storageBlocked=false;
    try {parent.document.body;}catch {parentBlocked=true;}
    try {localStorage.setItem('widget-test','bad');}catch {storageBlocked=true;}
    fetch('https://example.com/roclet-widget-test').then(()=>false,()=>true).then(networkBlocked=>parent.postMessage({rocletWidgetTest:true,value:output.value,parentBlocked,storageBlocked,networkBlocked},'*'));
  </script>`;
  const widget=renderDisplay(markup('widget',script),'Interactive');const frame=widget.querySelector('iframe');
  let message;
  const receive=event=>{if(event.source===frame.contentWindow && event.data?.rocletWidgetTest)message=event.data;};
  window.addEventListener('message',receive);document.body.append(widget);
  try {await until(()=>message);assert.equal(message.value,'21');assert(message.parentBlocked);assert(message.storageBlocked);assert(message.networkBlocked);}
  finally {window.removeEventListener('message',receive);widget.remove();}
  report('HTML and saved widgets are inert; SVG loads; live widgets respond locally without parent/storage/fetch access');
  const markdown=await session.request({operation:'document',action:'evaluate',format:'roc',source:'import Display\n# %%\nDisplay.markdown("# Safe\\n<script>alert(1)</script>\\n[unsafe](javascript:alert(1))")'});
  assert.equal(markdown.status,'ok');const md=renderDisplay(markdown.evaluation.values[0].display,markdown.evaluation.values[0].text);assert(md.querySelector('h1'));assert.equal(md.querySelectorAll('script,[href^="javascript:"]').length,0);
  report('Markdown uses the existing parser and safe DOM renderer');
  const rows=Array.from({length:205},(_,i)=>`["${i}"]`).join(',');const bounded=await session.request({operation:'document',action:'evaluate',format:'roc',source:`import Display\n# %%\nDisplay.table(["Index"], [${rows}])`});assert.equal(bounded.status,'ok');assert.equal(bounded.evaluation.values[0].display.rows.length,200);assert.equal(bounded.evaluation.values[0].display.row_count,205);
  report('Roc bounds table previews before crossing the WASM boundary');
  notebook=await startNotebook({save:async()=>{},list:async()=>[]});await until(()=>notebook.result?.status==='ok');
  await notebook.open(await fetch('../fixtures/documents/rich-outputs.roc').then(r=>r.text()),'Rich outputs.roc');notebook.setAuto(false);await notebook.run();
  assert.equal(notebook.result.status,'ok');assert.equal(document.querySelectorAll('#cells .rich-output').length,7);assert.equal(document.querySelectorAll('#cells .display-image').length,2);assert.match(document.querySelector('#cells table').textContent,/9007199254740993/);
  await until(()=>document.querySelector('#cells .display-image')?.complete);assert(document.querySelector('#cells .display-image').naturalWidth>0);
  const original=document.querySelector('#cells table'),slider=document.querySelector('#cells input[type="range"]');
  // A srcdoc frame finishing navigation can reset focus in its parent.
  await until(()=>[...document.querySelectorAll('#cells iframe')].every(frame=>loadedFrames.has(frame)));
  assert(slider && !slider.disabled);slider.focus();assert(document.activeElement===slider,`Initial focus: ${document.activeElement?.outerHTML.slice(0,200)}`);slider.value=8;slider.dispatchEvent(new Event('input',{bubbles:true}));
  assert(document.activeElement===slider,'Focus lost on input event');assert.equal(notebook.state.inputValues.width,8);assert(document.contains(original));assert.equal(original.closest('.result-block').dataset.stale,'true');await notebook.run();assert.match(document.querySelector('#cells .markdown').textContent,/Rich outputs|area/);assert(notebook.result.evaluation.values.some(v=>v.text.includes('24')));
  assert.equal(document.querySelector('#cells input[type="range"]'),slider);assert(document.activeElement===slider,`After run focus: ${document.activeElement?.outerHTML.slice(0,200)}`);
  assert.equal(slider.value,'8');
  notebook.setAuto(true);slider.value=7;slider.dispatchEvent(new Event('input',{bubbles:true}));
  await until(()=>notebook.result?.status==='ok' && notebook.result.evaluation.values.some(v=>v.text.includes('21')));
  notebook.setAuto(false);notebook.setInputValue('width',8);await notebook.run();
  report('native slider drives Roc reactively, respects manual run, and retains its DOM node and focus');
  const mdIndex=notebook.state.cells.findIndex(c=>c.source.includes('Display.markdown')),mdSource=notebook.state.cells[mdIndex].source;
  notebook.editCell(mdIndex,'Display.text(width.to_str())');await notebook.run();assert.equal(document.querySelector('#cells .rich-output > pre').textContent,'8');
  notebook.setInputValue('width',9);await notebook.run();assert.equal(document.querySelector('#cells .rich-output > pre').textContent,'9');
  notebook.editCell(mdIndex,mdSource);await notebook.run();
  report('plain-text alternatives update even when the rich envelope stays identical');
  const capture=await captureExport(notebook,compiler,{results:true,debug:true}),bundle=await exportBundle(capture),files=await unzip(await bundle.arrayBuffer());assert(!files.has('Display.roc'));assert.match(text(files.get('notebook.roc')),/import roclet\.Display/);assert.match(text(files.get('notebook.roc')),/main! =/);
  const imported=await importBundle(await bundle.arrayBuffer(),compiler);assert(imported.record.savedResults.snapshots.some(s=>s.display?.kind==='table'));await notebook.replace(imported.record);await until(()=>document.querySelectorAll('#cells .unverified .rich-output').length===7);assert.equal(notebook.state.autoRun,false);assert.equal(notebook.state.inputValues.width,9);assert([...document.querySelectorAll('#cells .unverified iframe')].every(f=>f.getAttribute('sandbox')===''));
  assert(document.querySelector('#cells .unverified input[type=range]').disabled);
  await notebook.run();assert(notebook.result.evaluation.values.some(v=>v.text.includes('27')));
  const html=new DOMParser().parseFromString(await (await exportReport(capture)).text(),'text/html');assert(html.querySelector('table'));assert.equal(html.querySelectorAll('iframe').length,2);assert([...html.querySelectorAll('iframe')].every(f=>f.getAttribute('sandbox')===''));assert(html.querySelector('img[src^="data:image/png;base64,"]'));assert.equal(html.querySelectorAll('script,[onerror]').length,0);assert.match(html.body.textContent,/9007199254740993/);
  report('bundles preserve unverified rich snapshots and the pinned Display package; reports preserve safe rich output');
  const bridgeHtml=`<script>
    roclet.onValue(value=>{parent.postMessage({customValue:value},'*');roclet.setValue(value);});
    addEventListener('message',event=>{
      if(event.source!==parent)return;
      if(event.data?.testInput!==undefined)roclet.setValue(event.data.testInput);
      if(event.data?.testSpoof)parent.postMessage({type:'value',value:19},'*');
    });
  </script>`;
  const bridgeSource=`import Display\nimport Input\n# %%\ncontrol = Input.custom({key: "custom", label: "Custom", min: 1, max: 20, default: 5, html: ${JSON.stringify(bridgeHtml)}})\nout_control = control.display\n# %%\nout_area = control.value * 3`;
  let bridgeValue;const bridgeMessage=event=>{if(event.source===bridgeFrame?.contentWindow && 'customValue' in (event.data??{}))bridgeValue=event.data.customValue;};
  let bridgeFrame;window.addEventListener('message',bridgeMessage);
  try {
    await notebook.open(bridgeSource,'Custom input.roc');notebook.setAuto(false);await notebook.run();
    bridgeFrame=document.querySelector('#cells iframe');assert(bridgeFrame);await until(()=>bridgeValue===5);
    bridgeFrame.contentWindow.postMessage({testInput:8},'*');await until(()=>notebook.state.inputValues.custom===8);
    assert.equal(notebook.result,null);await notebook.run();await until(()=>bridgeValue===8);
    assert(notebook.result.evaluation.values.some(v=>v.root==='out_area'&&v.text==='24'));
    assert.equal(document.querySelector('#cells iframe'),bridgeFrame);
    for(const invalid of [21,NaN,'9'])bridgeFrame.contentWindow.postMessage({testInput:invalid},'*');
    bridgeFrame.contentWindow.postMessage({testSpoof:true},'*');
    await new Promise(resolve=>setTimeout(resolve,100));assert.equal(notebook.state.inputValues.custom,8);
    notebook.group=null;notebook.setAuto(true);bridgeFrame.contentWindow.postMessage({testInput:9},'*');
    await until(()=>notebook.result?.evaluation?.values.some(v=>v.root==='out_area'&&v.text==='27'));
    await until(()=>bridgeValue===9);assert.equal(document.querySelector('#cells iframe'),bridgeFrame);
    notebook.undo();await until(()=>notebook.result?.evaluation?.values.some(v=>v.root==='out_area'&&v.text==='24'));
    await until(()=>bridgeValue===8);
    const snapshot=await captureExport(notebook,compiler,{results:true});
    const reportDoc=new DOMParser().parseFromString(await (await exportReport(snapshot)).text(),'text/html');
    assert.equal(reportDoc.querySelector('iframe').getAttribute('sandbox'),'');
    const importedCustom=await importBundle(await (await exportBundle(snapshot)).arrayBuffer(),compiler);
    assert.equal(importedCustom.record.inputValues.custom,8);
    const oldFrame=bridgeFrame;await notebook.open('out_1 = 42','Other.roc');
    oldFrame.contentWindow?.postMessage({testInput:10},'*');assert.equal(notebook.state.inputValues.custom,undefined);
    report('custom input bridge drives manual/automatic Roc runs, preserves frames, restores undo/bundles, rejects invalid/spoofed messages and leaves reports inert');
  } finally {window.removeEventListener('message',bridgeMessage);}
  const runnable=await session.request({operation:'document',action:'run',format:'roc',source:'import Display\n# %%\nDisplay.table(["Exact"], [["9007199254740993"]])'});assert.equal(runnable.status,'ok');assert(runnable.evaluation.events.some(e=>e.message.includes('9007199254740993')));
  report('generated display! uses the same readable plain-text representation in script execution');
  parent.postMessage({rocletM5:true,status:`PASS — ${count} M5 rich output contracts`,log,result:'pass'},new URL(document.baseURI).origin);
} catch(error) {log+=error.stack??error.message;parent.postMessage({rocletM5:true,status:'FAIL',log,result:'fail'},new URL(document.baseURI).origin);}
finally {document.removeEventListener('load',frameLoaded,true);notebook?.dispose();session?.stop();}
