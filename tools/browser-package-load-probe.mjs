// Run on a static server with endpoint:null and browser-check's --upload-plan.
// The plan selects: invalid archive, roc-time, roc-time (wrong package), parser, Unicode.
(async()=>{
  const $=id=>document.getElementById(id),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const assert=(ok,message)=>{if(!ok)throw Error(message);};
  const until=async predicate=>{for(let i=0;i<1200;i++){if(predicate())return;await pause(100);}throw Error('Timed out: '+$('status').textContent+' '+$('package-status').textContent);};
  const dialog=()=>$('package-dialog').open;
  const choose=()=>globalThis.__rocletFilePicker('#package-load');
  const values=()=>[...document.querySelectorAll('#notebook .value[data-stale="false"] > pre')].map(node=>node.textContent);
  const cached=async()=>{
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('roclet-build-cache');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
    try {return await new Promise((resolve,reject)=>{const r=db.transaction('entries').objectStore('entries').getAll();r.onsuccess=()=>resolve(r.result.filter(entry=>entry.namespace.endsWith(':packages')).length);r.onerror=()=>reject(r.error);});}finally{db.close();}
  };
  await until(()=>document.documentElement.dataset.ready==='true');
  assert((await fetch('/web/package-config.json').then(r=>r.json())).endpoint===null,'Static fallback must run without a proxy');
  await until(dialog);
  const timeUrl=$('package-download').href;
  assert(timeUrl.includes('roc-time/releases/download/0.2.0/'),'Download link lost the compiler-resolved package URL');
  if(innerWidth>=680) {await pause(16000);assert(dialog() && $('status').textContent.startsWith('Waiting for package'),'Execution timed out while waiting for a user');}
  assert(await cached()===0,'Fresh site already has verified packages');
  choose();await until(()=>dialog() && $('package-status').textContent.includes('invalid archive or content hash'));
  assert(await cached()===0,'Invalid archive entered persistent storage');
  choose();await until(()=>$('status').textContent.startsWith('Current'));
  assert(!dialog() && document.querySelectorAll('#notebook .value[data-stale="false"]').length===6,'Loading did not resume the six calendar outputs');
  assert(document.querySelector('#notebook').textContent.includes('Book 15 Jun 2026, 09:00–09:45 UTC.'),'Wrong calendar result');
  assert($('status').textContent.includes('2 tests passed') && await cached()===1,'Calendar assertions or archive persistence failed');
  $('stop').click();$('run').click();await until(()=>$('status').textContent.startsWith('Current'));
  assert(!dialog(),'Restart did not restore the user-loaded archive');
  const {editorFor}=await import('/web/cell-editor.mjs');
  const parserUrl='https://github.com/lukewilliamboswell/roc-parser/releases/download/2.0.0/7CLzCK6qUz7zmj6nvBxMEFu11HPwQTnCovKiyWzDSLTW.tar.zst';
  const unicodeUrl='https://github.com/roc-lang/unicode/releases/download/4.2.0/4W8SHzvwet9hH9qZewJ1J1CVQoH7YKA6zyijWFTB3y1w.tar.zst';
  const source=`app [] { parser: "${parserUrl}" }\n# %%\nimport parser.Utf8\nout_number = Utf8.parse_str(Utf8.digits, "12345")\n# %%\nout_invalid = Utf8.parse_str(Utf8.digits, "12x")\n`;
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  $('source-view').click();await until(()=>!$('source-pane').hidden);
  const editor=editorFor(document.querySelector('#source .cm-content'));
  editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:source},userEvent:'input'});
  $('notebook-view').click();await until(()=>!$('notebook').hidden);$('run').click();await until(dialog);
  assert($('package-download').href===parserUrl,'Wrong package requested');
  $('package-dialog').querySelector('button[data-close]').click();await until(()=>$('status').textContent.includes('cancelled'));
  assert(!dialog() && await cached()===1,'Cancellation installed a package or left the popup open');
  $('run').click();await until(dialog);choose();
  await until(()=>dialog() && $('package-status').textContent.includes('invalid archive or content hash'));
  assert(await cached()===1,'A different valid bundle was accepted for the parser hash');
  choose();await until(()=>dialog() && $('package-download').href===unicodeUrl);
  assert(await cached()===2,'Verified parser archive was not cached before its dependency');
  choose();await until(()=>$('status').textContent.startsWith('Current'));
  assert(JSON.stringify(values())===JSON.stringify(['Ok(12345)','Err(ParseError({ message: "unexpected input", offset: 2 }))']),'Parser values differ after loading transitive dependencies');
  assert(await cached()===3 && !dialog(),'Verified package caches differ');
  $('stop').click();$('run').click();await until(()=>$('status').textContent.startsWith('Current'));
  assert(values()[0]==='Ok(12345)' && !dialog(),'Fresh worker did not restore both parser dependencies');
  const bytes=await fetch('/artifacts/roclet.wasm').then(r=>r.arrayBuffer()),timeSource=await fetch('/demos/04-meeting-windows.roc').then(r=>r.text());
  const module=path=>JSON.stringify(new URL(path,location.href).href);
  const code=`import{createWasmTransport}from ${module('/compiler-adapter/wasm.mjs')};import{BuildCache,compilerNamespace}from ${module('/web/build-cache.mjs')};import{BrowserPackages}from ${module('/web/packages.mjs')};onmessage=async({data})=>{try{const raw=await createWasmTransport(data.bytes),ns=await compilerNamespace(data.bytes,raw.cacheIdentity());const packages=new BrowserPackages(new BuildCache(ns+':packages'),{fetch:async()=>{throw Error('Package networking disabled');}});const results=[];for(const source of data.sources){const r=await packages.evaluate(raw,{operation:'document',action:'evaluate',format:'roc',source,compact:true});results.push({status:r.status,values:r.evaluation?.values.map(v=>v.text),tests:r.evaluation?.tests});}postMessage({results});}catch(error){postMessage({error:error.stack});}};`;
  const blob=URL.createObjectURL(new Blob([code],{type:'text/javascript'})),worker=new Worker(blob,{type:'module'});
  let offline;
  try {offline=await new Promise((resolve,reject)=>{worker.onmessage=({data})=>data.error?reject(Error(data.error)):resolve(data.results);worker.onerror=reject;worker.postMessage({bytes,sources:[timeSource,source]});});}
  finally {worker.terminate();URL.revokeObjectURL(blob);}
  assert(offline.every(r=>r.status==='ok') && offline[0].values.length===6 && offline[0].tests.length===2 && offline[0].tests.every(t=>t.passed) && offline[1].values[0]==='Ok(12345)','User-loaded archives could not restore without package networking');
  assert(document.documentElement.scrollWidth<=innerWidth,'Package dialog or notebook overflowed');
  return {result:'pass',mode:'static-file-picker',timeUrl,parserUrl,unicodeUrl,invalidArchive:'rejected',wrongPackage:'rejected',transitiveDependencies:'pass',cancellation:'pass',userWaitTimeout:innerWidth>=680?'16 seconds without timeout':'covered in wide run',freshWorkerRestore:'pass',offlinePackageNetworking:'disabled',verifiedArchives:await cached(),values:values(),overflow:false};
})()
