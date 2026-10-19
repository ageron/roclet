// Run through browser-check.mjs --page web/studio.html --script <this file>.
// The default probes public GitHub URLs. ?package-test=local-mirror explicitly
// isolates compilation/cache behavior using unchanged, locally served archives.
(async()=>{
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const until=async predicate=>{for(let i=0;i<600;i++){if(predicate())return;await pause(100);}throw Error('Timed out waiting for Studio');};
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const $=id=>document.getElementById(id);
  const urls=[
    'https://github.com/lukewilliamboswell/roc-parser/releases/download/2.0.0/7CLzCK6qUz7zmj6nvBxMEFu11HPwQTnCovKiyWzDSLTW.tar.zst',
    'https://github.com/roc-lang/unicode/releases/download/4.2.0/4W8SHzvwet9hH9qZewJ1J1CVQoH7YKA6zyijWFTB3y1w.tar.zst'
  ];
  const header=`app [] { parser: "${urls[0]}" }\n\n`;
  const source=header+'# %% id=number\nimport parser.Utf8\nout_number = Utf8.parse_str(Utf8.digits, "12345")\n# %% id=invalid\nout_invalid = Utf8.parse_str(Utf8.digits, "12x")\n';
  const request={operation:'document',action:'evaluate',format:'roc',source,compact:true};
  const localMirror=new URL(location.href).searchParams.get('package-test')==='local-mirror';
  const manifest=await fetch('/artifacts/manifest.json').then(response=>response.json());
  const report={compilerSha256:manifest.artifacts['roclet.wasm'].sha256,buildMode:manifest.wasmOptimize,packageUrl:urls[0],mode:localMirror?'local-mirror':'public-url'};
  await until(()=>document.documentElement.dataset.ready==='true' && $('status').textContent.includes('Current'));
  let raw,packages,bytes,namespace,reference;
  if(localMirror) {
    const [{createWasmTransport},{BuildCache,compilerNamespace},{BrowserPackages}]=await Promise.all([
      import('/compiler-adapter/wasm.mjs'),import('/web/build-cache.mjs'),import('/web/packages.mjs')
    ]);
    bytes=await fetch('/artifacts/roclet.wasm').then(response=>response.arrayBuffer());
    raw=await createWasmTransport(bytes);namespace=await compilerNamespace(bytes,raw.cacheIdentity());
    const packageCache=new BuildCache(namespace+':packages');await packageCache.clear();
    const downloads=[];
    packages=new BrowserPackages(packageCache,{fetch:async url=>{
      assert(urls.includes(url),'Unexpected package URL '+url);downloads.push(url);
      return fetch('/artifacts/browser-packages/'+new URL(url).pathname.split('/').at(-1));
    }});
    const result=await packages.evaluate(raw,request);
    assert(result.status==='ok',JSON.stringify(result));reference=result.evaluation.values;
    assert(reference[0].text==='Ok(12345)','Wrong parsed number');
    assert(reference[1].text==='Err(ParseError({ message: "unexpected input", offset: 2 }))','Wrong invalid-input error');
    assert(downloads.length===2,'Must resolve parser and transitive Unicode archives');
    await new BuildCache(namespace).save(raw.takeCacheUpdates());
    report.transport='Local mirrors of unchanged release archives; this is not a public-download pass';
    report.downloads=downloads;report.initial={values:reference,workspaceCache:result.workspaceCache};
  } else {
    try {const response=await fetch(urls[0],{mode:'cors',credentials:'omit',signal:AbortSignal.timeout(15000)});report.directFetch={status:response.status,bytes:(await response.arrayBuffer()).byteLength};}
    catch(error){report.directFetch={error:error.message};}
  }
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  const {editorFor}=await import('/web/cell-editor.mjs');
  const enter=async text=>{
    $('source-view').click();await until(()=>!$('source-pane').hidden);
    const editor=editorFor(document.querySelector('#source .cm-content'));
    editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:text},userEvent:'input'});
    $('notebook-view').click();await until(()=>!$('notebook').hidden);
  };
  const values=()=>[...document.querySelectorAll('#notebook .value[data-stale="false"] > pre')].map(node=>node.textContent);
  const run=async()=>{$('run').click();await until(()=>/failed|attention|Current|Stopped after/i.test($('status').textContent));};
  await enter(source);await run();
  report.status=$('status').textContent;report.diagnostics=$('document-diagnostics').textContent;
  report.studioInitial=values();
  if(!$('status').textContent.startsWith('Current')) {
    assert(!localMirror,'Mirrored package failed in Studio: '+report.status+' '+report.diagnostics);
    return {...report,result:'blocked',passed:false};
  }
  assert(values()[0]==='Ok(12345)','Studio number mismatch');
  assert(values()[1]==='Err(ParseError({ message: "unexpected input", offset: 2 }))','Studio error mismatch');
  await enter(source.replace('12345','67890'));await run();
  assert(values()[0]==='Ok(67890)','Edit returned stale output');report.studioEdited=values();
  $('stop').click();await run();assert(values()[0]==='Ok(67890)','Studio worker restart failed');report.studioWorkerRestart=values();
  if(localMirror) {
    const module=path=>JSON.stringify(new URL(path,location.href).href);
    const workerSource=`import{createWasmTransport}from ${module('/compiler-adapter/wasm.mjs')};import{BuildCache,compilerNamespace}from ${module('/web/build-cache.mjs')};import{BrowserPackages}from ${module('/web/packages.mjs')};onmessage=async({data})=>{try{const raw=await createWasmTransport(data.bytes),ns=await compilerNamespace(data.bytes,raw.cacheIdentity());if(!raw.importCache(await new BuildCache(ns).load()))throw Error('Cache restore failed');const p=new BrowserPackages(new BuildCache(ns+':packages'),{fetch:async()=>{throw Error('Network disabled for this worker');}});postMessage({result:await p.evaluate(raw,data.request)});}catch(e){postMessage({error:e.stack});}};`;
    const offlineRequest=async request=>{
      const blob=URL.createObjectURL(new Blob([workerSource],{type:'text/javascript'})),worker=new Worker(blob,{type:'module'});
      try {return await new Promise((resolve,reject)=>{worker.onmessage=({data})=>data.error?reject(Error(data.error)):resolve(data.result);worker.onerror=reject;worker.postMessage({bytes,request});});}
      finally {worker.terminate();URL.revokeObjectURL(blob);}
    };
    const offline=await offlineRequest(request);
    assert(offline.status==='ok' && JSON.stringify(offline.evaluation.values)===JSON.stringify(reference),'Offline values differ');
    assert(offline.workspaceCache.hits>0,'Restored compiler artifacts unused');report.offline={values:offline.evaluation.values,workspaceCache:offline.workspaceCache};
    const csvSource=await fetch('/fixtures/documents/roc-parser-package.roc').then(response=>{if(!response.ok)throw Error('CSV fixture is missing');return response.text();});
    const csv=await packages.evaluate(raw,{...request,source:csvSource});
    assert(csv.status==='ok',JSON.stringify(csv));
    assert(JSON.stringify(csv.evaluation.values.map(value=>value.text))===JSON.stringify(['Ok(12345)','Ok(["Earth", "Mars"])','Ok(3)']),'Typed CSV values differ');
    await enter(csvSource);await run();assert(JSON.stringify(values())===JSON.stringify(['Ok(12345)','Ok(["Earth", "Mars"])','Ok(3)']),'Studio CSV values differ');
    $('stop').click();await run();assert(JSON.stringify(values())===JSON.stringify(['Ok(12345)','Ok(["Earth", "Mars"])','Ok(3)']),'Restarted Studio CSV values differ');
    const {BuildCache}=await import('/web/build-cache.mjs');await new BuildCache(namespace).save(raw.takeCacheUpdates());
    const offlineCsv=await offlineRequest({...request,source:csvSource});
    assert(offlineCsv.status==='ok' && JSON.stringify(offlineCsv.evaluation.values)===JSON.stringify(csv.evaluation.values),'Offline CSV values differ');
    assert(offlineCsv.workspaceCache.hits>0,'Offline CSV did not use build cache');
    report.csv={values:csv.evaluation.values,studioValues:values(),offline:{values:offlineCsv.evaluation.values,workspaceCache:offlineCsv.workspaceCache}};
  }
  return {...report,result:localMirror?'isolated-pass':'pass',passed:true};
})()
