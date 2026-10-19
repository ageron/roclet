import {BuildCache,decodeCacheStream,compilerNamespace} from './build-cache.mjs';
import {DocumentSession} from './document-session.mjs';
import {createWasmTransport} from '../compiler-adapter/wasm.mjs';
import {assert} from '../tests/harness.mjs';
const report=text=>document.querySelector('#log').textContent+=text+'\n';
const namespace=`browser-conformance:${crypto.randomUUID()}`;
function coldCacheWorker(action) {
  const module=new URL('./build-cache.mjs',import.meta.url).href;
  const source=`import {BuildCache,encodeCacheStream,decodeCacheStream} from ${JSON.stringify(module)};
  onmessage=async({data})=>{try {const cache=new BuildCache(data.namespace);if(data.action==='save')await cache.save(encodeCacheStream([{path:'/cache/test',bytes:new Uint8Array([7,8,9])}]));postMessage({entries:decodeCacheStream(await cache.load()).map(e=>({path:e.path,bytes:[...e.bytes]}))});}catch(error){postMessage({error:error.message});}};`;
  return new Promise((resolve,reject)=>{
    const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'})),worker=new Worker(url,{type:'module'});
    worker.onmessage=({data})=>{worker.terminate();URL.revokeObjectURL(url);data.error?reject(new Error(data.error)):resolve(data.entries);};
    worker.onerror=reject;worker.postMessage({namespace,action});
  });
}
function offlinePackageWorker(bytes,request) {
  const module=name=>JSON.stringify(new URL(name,import.meta.url).href);
  const source=`import {createWasmTransport} from ${module('../compiler-adapter/wasm.mjs')};
  import {BuildCache,compilerNamespace} from ${module('./build-cache.mjs')};
  import {BrowserPackages} from ${module('./packages.mjs')};
  onmessage=async({data})=>{try{const transport=await createWasmTransport(data.bytes),namespace=await compilerNamespace(data.bytes,transport.cacheIdentity());
  const packages=new BrowserPackages(new BuildCache(namespace+':packages'),{fetch:async()=>{throw new Error('Network disabled for package restore test');}});
  postMessage({result:await packages.evaluate(transport,data.request)});}catch(error){postMessage({error:error.stack});}};`;
  return new Promise((resolve,reject)=>{
    const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'})),worker=new Worker(url,{type:'module'});
    worker.onmessage=({data})=>{worker.terminate();URL.revokeObjectURL(url);data.error?reject(new Error(data.error)):resolve(data.result);};
    worker.onerror=reject;worker.postMessage({bytes,request});
  });
}
async function corruptCache() {
  const db=await new Promise((resolve,reject)=>{const request=indexedDB.open('roclet-build-cache');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
  await new Promise((resolve,reject)=>{const tx=db.transaction('entries','readwrite'),store=tx.objectStore('entries'),request=store.get(`${namespace}\0/cache/test`);request.onsuccess=()=>{const record=request.result;record.bytes[0]=0;store.put(record);};tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});db.close();
}
try {
  assert.deepEqual(await coldCacheWorker('save'),[{path:'/cache/test',bytes:[7,8,9]}]);
  assert.deepEqual(await coldCacheWorker('load'),[{path:'/cache/test',bytes:[7,8,9]}]);
  report('PASS IndexedDB survives terminating both compiler/cache workers');
  await corruptCache();assert.deepEqual(await coldCacheWorker('load'),[]);
  report('PASS corrupted persisted artifact is discarded before compiler import');
  await new BuildCache(namespace).clear();
  const response=await fetch('../artifacts/roclet.wasm');if(!response.ok) throw new Error('Build the compiler WASM artifact to complete workspace conformance');
  const bytes=await response.arrayBuffer(),raw=await createWasmTransport(bytes);
  assert(raw.workspace,'Compiler WASM lacks workspace ABI');
  const request={requestId:'workspace-conformance',documentRevision:1,inputRevision:0,workerGeneration:1,cells:[{key:'code',source:'import Fresh\nout_1 = Fresh.value'}],roots:['out_1']};
  const session=new DocumentSession(bytes),files=[{path:'/workspace/Fresh.roc',source:'Fresh := [].{ value : U64\nvalue = 7 }'}];
  const first=await session.request({...request,files});assert.equal(first.status,'ok');assert.equal(first.values[0].text,'7');
  const second=await session.request({...request,files:[{...files[0],source:'Fresh := [].{ value : U64\nvalue = 8 }'}]});assert.equal(second.status,'ok');assert.equal(second.values[0].text,'8');
  session.stop();
  const restored=await session.request({...request,files});assert.equal(restored.status,'ok');assert.equal(restored.values[0].text,'7');assert(restored.workspaceCache.hits>0,'Cold worker must hit the restored build cache');session.stop();
  report('PASS module edits invalidate compiled artifacts and cold workers restore browser build cache');
  const nestedSession=new DocumentSession(bytes),nestedRequest={...request,requestId:'nested-module',cells:[{key:'code',source:'import Shapes/Wall\nout_1 = Wall.cost(5, 3)'}]};
  const wall=extra=>`import /Materials\nWall := [].{\ncost : U64, U64 -> U64\ncost = |width, height| width * height * Materials.price + ${extra}\n}`;
  const materials=price=>`Materials := [].{\nprice : U64\nprice = ${price}\n}`;
  const nestedFiles=(extra,price)=>[{path:'/workspace/Shapes/Wall.roc',source:wall(extra)},{path:'/workspace/Materials.roc',source:materials(price)}];
  for(const [extra,price,expected] of [[0,4,'60'],[1,4,'61'],[1,5,'76']]) {
    const result=await nestedSession.request({...nestedRequest,files:nestedFiles(extra,price)});
    assert.equal(result.status,'ok');assert.equal(result.values[0].text,expected);
  }
  const removed=await nestedSession.request({...nestedRequest,files:[nestedFiles(1,5)[1]]});
  assert.notEqual(removed.status,'ok');assert.deepEqual(removed.values,[]);
  const repaired=await nestedSession.request({...nestedRequest,files:nestedFiles(0,4)});assert.equal(repaired.status,'ok');assert.equal(repaired.values[0].text,'60');nestedSession.stop();
  report('PASS nested Shapes/Wall imports package-root Materials; nested/dependency edits invalidate results, removal clears values, repair recovers');
  const textSession=new DocumentSession(bytes),textRequest={...request,requestId:'text-file',cells:[{key:'code',source:'import "data/message.txt" as message : Str\nout_1 = message'}]};
  for(const text of ['hello 🪨','updated ✓']) {
    const result=await textSession.request({...textRequest,files:[{path:'/workspace/data/message.txt',source:text}]});
    assert.equal(result.status,'ok');assert.equal(result.values[0].text,JSON.stringify(text));
  }
  const missingText=await textSession.request({...textRequest,files:[]});assert.notEqual(missingText.status,'ok');assert.deepEqual(missingText.values,[]);textSession.stop();
  report('PASS UTF-8 text file imports update through the compiler filesystem and missing files clear previous values');
  const customDisplaySession=new DocumentSession(bytes);
  const customDisplay=await customDisplaySession.request({...request,requestId:'custom-display',cells:[{key:'custom',source:'import Display\nout_1 = Display.({text: "custom"})'}],files:[{path:'/workspace/Display.roc',source:'Display := { text : Str }'}]});
  assert.equal(customDisplay.status,'ok');assert(customDisplay.values[0].text.includes('custom'));assert.equal(customDisplay.values[0].display,undefined);customDisplaySession.stop();
  report('PASS an explicit workspace Display module overrides the default library and remains ordinary inspected text');
  raw.putFile('/workspace/Fresh.roc',files[0].source);assert.equal(raw(request).status,'ok');
  const coldStats=raw.cacheStats();
  const artifacts=raw.takeCacheUpdates();
  assert(decodeCacheStream(artifacts).length>0,'Compiler must emit real checked/canonicalized cache artifacts');
  report('PASS compiler emits opaque build artifacts, independent of evaluation values');
  const restoredRaw=await createWasmTransport(bytes);assert(restoredRaw.importCache(artifacts));restoredRaw.putFile('/workspace/Fresh.roc',files[0].source);
  assert.equal(restoredRaw(request).status,'ok');const restoredStats=restoredRaw.cacheStats();
  assert(restoredStats.hits>0,'Restored compiler must use persisted build artifacts');
  assert(restoredStats.misses<coldStats.misses,'Restored artifacts must reduce compiler cache misses versus identical empty-cache compilation');
  report('PASS a fresh WASM instance uses restored compiler artifacts (compiler cache hits)');
  const packageUrl=new URL('../artifacts/FPCEjLpsoY5fJ6nDBCeJQ1s6aMTQjMWUYAVQu6QdNuzr.tar.zst',import.meta.url).href;
  await new BuildCache(`${await compilerNamespace(bytes,raw.cacheIdentity())}:packages`).clear();
  const packageRequest={operation:'document',action:'evaluate',format:'roc',source:`app [] { geom: "${packageUrl}" }\n# %% id=package\nimport geom.Geometry\nGeometry.answer`};
  const packageSession=new DocumentSession(bytes),packaged=await packageSession.request(packageRequest);packageSession.stop();
  assert.equal(packaged.status,'ok');assert.equal(packaged.evaluation.values[0].text,'42.0');
  const packageRestored=await offlinePackageWorker(bytes,packageRequest);assert.equal(packageRestored.status,'ok');assert.equal(packageRestored.evaluation.values[0].text,'42.0');
  report('PASS compiler-resolved package fetch, hash verification, and cold-worker package restore without network');
  document.querySelector('#status').textContent='PASS workspace conformance';
  document.documentElement.dataset.result='pass';
} catch(error) {document.querySelector('#status').textContent='FAIL';document.documentElement.dataset.result='fail';report(error.stack??error.message);throw error;}
