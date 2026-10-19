import {test} from 'node:test';
import assert from 'node:assert/strict';
import {BuildCache,encodeCacheStream,decodeCacheStream,compilerNamespace} from '../web/build-cache.mjs';
import {fileChanges,mountChanges} from '../web/workspace.mjs';
import {DocumentSession} from '../web/document-session.mjs';
import {BrowserPackages} from '../web/packages.mjs';

test('workspace sends only changed modules and removes deleted modules',()=>{
  const first=fileChanges(new Map(),[{path:'/workspace/Geometry.roc',source:'area = 2'}]);
  assert.equal(first.patch.put.length,1);
  assert.deepEqual(fileChanges(first.next,[{path:'/workspace/Geometry.roc',source:'area = 2'}]).patch,{put:[],drop:[]});
  const next=fileChanges(first.next,[{path:'/workspace/Geometry.roc',source:'area = 3'},{path:'/workspace/Other.roc',source:'x = 1'}]);
  assert.equal(next.patch.put.length,2);
  assert.deepEqual(fileChanges(next.next,[]).patch.drop,['/workspace/Geometry.roc','/workspace/Other.roc']);
  for(const path of ['/workspace/../escape.roc','/packages/X.roc','Geometry.roc','/workspace/Main.roc','/workspace/main.roc','/workspace//Fresh.roc']) assert.throws(()=>fileChanges(new Map(),[{path,source:''}]));
  assert.throws(()=>mountChanges({workspace:false},first.patch),/Rebuild/);
  const text=fileChanges(new Map(),[{path:'/workspace/data/input.txt',source:'plain UTF-8 text'}]),mounted=[];
  mountChanges({workspace:true,putFile:(path,source)=>mounted.push({path,source})},text.patch);
  assert.deepEqual(mounted,[{path:'/workspace/data/input.txt',source:'plain UTF-8 text'}]);
});

test('session mounts unchanged files once and remounts after worker restart',async()=>{
  const workers=[];
  class Worker {constructor(){workers.push(this);this.sent=[];} postMessage(data){this.sent.push(data);} terminate(){}}
  const session=new DocumentSession(new ArrayBuffer(1),Worker),files=[{path:'/workspace/Geometry.roc',source:'area = 2'}];
  const run=async request=>{const result=session.request(request),worker=workers.at(-1);worker.onmessage({data:{result:{status:'ok'}}});await result;return worker.sent.at(-1);};
  assert.equal((await run({source:'a',files})).workspace.put.length,1);
  const second=await run({source:'b',files});assert.equal(second.workspace.put.length,0);assert.equal(second.request.files,undefined);
  session.stop();assert.equal((await run({source:'c',files})).workspace.put.length,1);
  session.stop();
});

test('session omits only a confirmed compiler baseline graph from later requests',async()=>{
  let worker;class Worker {constructor(){worker=this;} postMessage(data){this.sent=data;} terminate(){}}
  const session=new DocumentSession(new ArrayBuffer(1),Worker),graph={context:'one',definitions:[]};
  const first=session.request({source:'a'});worker.onmessage({data:{result:{status:'ok',workspaceCache:{hits:0},graph}}});await first;
  const request={operation:'document',reactivity:{known:true,previous:graph,current:graph,available:['out_1']}};
  const second=session.request(request);assert.deepEqual(worker.sent.request.reactivity,{known:true,available:['out_1']});worker.onmessage({data:{result:{status:'ok',workspaceCache:{hits:1},graph}}});await second;
  const placeholder=session.request({...request,reactivity:{...request.reactivity,current:{context:'',scope:'module',definitions:[]}}});assert.deepEqual(worker.sent.request.reactivity,{known:true,available:['out_1']});worker.onmessage({data:{result:{status:'ok',workspaceCache:{hits:1},graph}}});await placeholder;
  const different=session.request({...request,reactivity:{...request.reactivity,previous:{context:'different'}}});assert.equal(worker.sent.request.reactivity.previous.context,'different');worker.onmessage({data:{result:{status:'ok'}}});await different;session.stop();
});

test('real-worker boot shares a compiled module across restarts without copying compiler bytes',async()=>{
  const original=globalThis.Worker,workers=[];
  class Worker {constructor(){workers.push(this);} postMessage(data){this.sent=data;} terminate(){}}
  globalThis.Worker=Worker;
  try {
    const bytes=new Uint8Array([0,97,115,109,1,0,0,0]).buffer,session=new DocumentSession(bytes,Worker);
    const request=session.request({source:'one'});
    while(!workers[0].sent) await new Promise(resolve=>setImmediate(resolve));
    const first=workers[0].sent;assert(first.module instanceof WebAssembly.Module);assert.equal(first.bytes,undefined);assert.match(first.compilerDigest,/^[a-f0-9]{64}$/);
    workers[0].onmessage({data:{result:{status:'ok'}}});await request;session.stop();
    const restarted=session.request({source:'two'});while(!workers[1].sent) await new Promise(resolve=>setImmediate(resolve));
    assert.equal(workers[1].sent.module,first.module);workers[1].onmessage({data:{result:{status:'ok'}}});await restarted;session.stop();
  } finally {if(original===undefined)delete globalThis.Worker;else globalThis.Worker=original;}
});

test('opaque compiler artifacts restore into a cold cache in the correct namespace',async()=>{
  const namespace=await compilerNamespace(new Uint8Array([1,2,3]),'wasm32/compiler-test');
  const cache=new BuildCache(namespace,{indexedDB:null}),entry={path:'/cache/checked/a',bytes:new Uint8Array([4,5,6])};
  await cache.clear();await cache.save(encodeCacheStream([entry]));
  assert.deepEqual(decodeCacheStream(await new BuildCache(namespace,{indexedDB:null}).load()),[entry]);
  const different=new BuildCache(await compilerNamespace(new Uint8Array([1,2,4]),'wasm32/compiler-test'),{indexedDB:null});
  assert.deepEqual(decodeCacheStream(await different.load()),[]);
  await cache.clear();assert.deepEqual(decodeCacheStream(await cache.load()),[]);
});

test('cache bounds evict old artifacts and reject malformed paths and truncated data',async()=>{
  const cache=new BuildCache('bounded',{indexedDB:null,maxBytes:4,maxEntries:1});await cache.clear();
  await cache.save(encodeCacheStream([{path:'/cache/a',bytes:new Uint8Array([1,2,3])}]));
  await new Promise(resolve=>setTimeout(resolve,2));
  await cache.save(encodeCacheStream([{path:'/cache/b',bytes:new Uint8Array([4,5,6])}]));
  assert.deepEqual(decodeCacheStream(await cache.load()).map(e=>e.path),['/cache/b']);
  assert.throws(()=>decodeCacheStream(new Uint8Array([1,2,3])),/format/);
  assert.throws(()=>decodeCacheStream(encodeCacheStream([{path:'/workspace/evil',bytes:new Uint8Array([1])}])) ,/path/);
  const stream=encodeCacheStream([{path:'/cache/a',bytes:new Uint8Array([1,2])}]);assert.throws(()=>decodeCacheStream(stream.subarray(0,stream.length-1)),/entry/);
  await cache.clear();
});

test('packages use compiler resolver URLs and persist only compiler-verified archives',async()=>{
  const cache=new BuildCache('package-test',{indexedDB:null});await cache.clear();
  const url='https://packages.invalid/example.tar.zst',archive=new Uint8Array([9,8,7]);let downloads=0,mounted=false;
  const transport=()=>mounted?{status:'ok'}:{status:'diagnostic',packagesRequired:[{url,destination:'/bundles/compiler-owned'},{url,destination:'/bundles/compiler-owned'}]};
  transport.installPackage=(requested,bytes)=>{assert.equal(requested,url);mounted=bytes[0]===9;return mounted;};
  const fetch=async requested=>{assert.equal(requested,url);downloads++;return new Response(archive);};
  assert.equal((await new BrowserPackages(cache,{fetch}).evaluate(transport,{})).status,'ok');assert.equal(downloads,1);
  mounted=false;assert.equal((await new BrowserPackages(new BuildCache('package-test',{indexedDB:null}),{fetch}).evaluate(transport,{})).status,'ok');assert.equal(downloads,1);
  await cache.clear();mounted=false;
  await assert.rejects(new BrowserPackages(cache,{fetch:async()=>new Response(new Uint8Array([0]))}).evaluate(transport,{}),/invalid archive or content hash/);
  assert.deepEqual(decodeCacheStream(await cache.load()),[]);
});
