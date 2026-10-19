// Actual Studio demo plus a separate fresh worker with package networking disabled.
(async()=>{
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const until=async predicate=>{for(let i=0;i<1800;i++){if(predicate())return;await pause(100);}throw Error('Timed out: '+document.querySelector('#status')?.textContent);};
  const $=id=>document.getElementById(id);
  const rows=()=>[...document.querySelectorAll('.value[data-stale="false"] table tbody tr')].map(row=>row.textContent);
  const values=()=>[...document.querySelectorAll('.value[data-stale="false"] > pre')].map(node=>node.textContent);
  const expected=['2026-06-15T09:00:00Z/2026-06-15T10:00:00Z','2026-06-15T12:00:00Z/2026-06-15T15:00:00Z','2026-06-15T16:00:00Z/2026-06-15T17:00:00Z'];
  await until(()=>document.documentElement.dataset.ready==='true');
  await until(()=>rows().length===3 || /failed|attention|Stopped after/i.test($('status').textContent));
  assert(JSON.stringify(rows())===JSON.stringify(expected),$('status').textContent+' '+$('document-diagnostics').textContent);
  assert(values().includes('Ok(3)'),'Wrong free-window count');
  const initial={rows:rows(),values:values()};
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  const {editorFor}=await import('/web/cell-editor.mjs');
  const editor=[...document.querySelectorAll('#notebook .cm-content')].map(editorFor).find(editor=>editor?.source.includes('bookings = ['));
  assert(editor,'Editable bookings cell is missing');
  const original=editor.view.state.doc.toString(),edited=original.replace('2026-06-15T12:00:00+02:00','2026-06-15T11:00:00+02:00');
  editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:edited},userEvent:'input'});
  const run=async()=>{$('run').click();await until(()=>/Current|failed|attention|Stopped after/i.test($('status').textContent));assert($('status').textContent.startsWith('Current'),$('status').textContent+' '+$('document-diagnostics').textContent);};
  await run();assert(JSON.stringify(rows())===JSON.stringify(expected.slice(1)),'Booking edit did not remove the first free slot');assert(values().includes('Ok(2)'),'Edited count is stale');
  const changed={rows:rows(),values:values()};
  $('stop').click();await run();assert(values().includes('Ok(2)'),'Fresh Studio worker failed');
  const manifest=await fetch('/artifacts/manifest.json').then(response=>response.json());
  const source=await fetch('/demos/04-meeting-windows.roc').then(response=>response.text());
  const bytes=await fetch('/artifacts/roclet.wasm').then(response=>response.arrayBuffer());
  const module=path=>JSON.stringify(new URL(path,location.href).href);
  const code=`import{createWasmTransport}from ${module('/compiler-adapter/wasm.mjs')};import{BuildCache,compilerNamespace}from ${module('/web/build-cache.mjs')};import{BrowserPackages}from ${module('/web/packages.mjs')};onmessage=async({data})=>{try{const raw=await createWasmTransport(data.bytes),ns=await compilerNamespace(data.bytes,raw.cacheIdentity());if(!raw.importCache(await new BuildCache(ns).load()))throw Error('Invalid compiler cache');const packages=new BrowserPackages(new BuildCache(ns+':packages'),{fetch:async()=>{throw Error('Package networking disabled');}});postMessage({result:await packages.evaluate(raw,data.request)});}catch(error){postMessage({error:error.stack});}};`;
  const blob=URL.createObjectURL(new Blob([code],{type:'text/javascript'})),worker=new Worker(blob,{type:'module'});let offline;
  try{offline=await new Promise((resolve,reject)=>{worker.onmessage=({data})=>data.error?reject(Error(data.error)):resolve(data.result);worker.onerror=reject;worker.postMessage({bytes,request:{operation:'document',action:'evaluate',format:'roc',source,compact:true}});});}
  finally{worker.terminate();URL.revokeObjectURL(blob);}
  assert(offline.status==='ok','Offline compile failed: '+JSON.stringify(offline));
  assert(offline.evaluation.values.find(value=>value.root==='out_count')?.text==='Ok(3)','Offline values differ');
  assert(offline.workspaceCache.hits>0,'Offline run did not consume compiler artifacts');
  // Leave the original, readable demonstration visible for the screenshot.
  editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:original},userEvent:'input'});await run();
  assert(JSON.stringify(rows())===JSON.stringify(expected),'Restored demo differs');
  return {result:'pass',buildMode:manifest.wasmOptimize,compilerSha256:manifest.artifacts['roclet.wasm'].sha256,initial,changed,studioWorkerRestart:'pass',offline:{values:offline.evaluation.values,workspaceCache:offline.workspaceCache},horizontalOverflow:document.documentElement.scrollWidth>innerWidth};
})()
