import {BuildCache,decodeCacheStream} from './build-cache.mjs';
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
async function corruptCache() {
  const db=await new Promise((resolve,reject)=>{const request=indexedDB.open('roclet-build-cache',1);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
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
  const session=new DocumentSession(bytes),files=[{path:'/workspace/Fresh.roc',source:'Fresh := [].{ value = 7 }'}];
  const first=await session.request({...request,files});assert.equal(first.status,'ok');assert.equal(first.values[0].text,'7');
  const second=await session.request({...request,files:[{...files[0],source:'Fresh := [].{ value = 8 }'}]});assert.equal(second.status,'ok');assert.equal(second.values[0].text,'8');
  session.stop();
  const restored=await session.request({...request,files});assert.equal(restored.status,'ok');assert.equal(restored.values[0].text,'7');session.stop();
  report('PASS module edits invalidate compiled artifacts and cold workers restore browser build cache');
  raw.putFile('/workspace/Fresh.roc',files[0].source);assert.equal(raw(request).status,'ok');
  assert(decodeCacheStream(raw.takeCacheUpdates()).length>0,'Compiler must emit real checked/canonicalized cache artifacts');
  report('PASS compiler emits opaque build artifacts, independent of evaluation values');
  document.querySelector('#status').textContent='PASS workspace conformance';
} catch(error) {document.querySelector('#status').textContent='FAIL';report(error.stack??error.message);throw error;}
