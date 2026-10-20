import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assignPanelIds,partId,engineDetails,engineStats,engineDetailsKey,readPreference,writePreference} from '../web/workbench.mjs';
import {PackagePrompts} from '../web/package-dialog.mjs';
import {BrowserPackages} from '../web/packages.mjs';
import {encodeCacheStream} from '../web/build-cache.mjs';
import {Notebook,newDraft} from '../web/edit-model.mjs';

// A dialog driver that records prompts; each prompt is answered by the test.
function fakeDriver() {
  const prompts=[];
  return {prompts,updates:[],
    open(details){return new Promise((resolve,reject)=>{const prompt={...details,resolve,reject,closed:false};details.signal.addEventListener('abort',()=>{prompt.closed=true;reject(new DOMException('Package loading cancelled','AbortError'));});prompts.push(prompt);});},
    update(requesters){this.updates.push(requesters);}};
}
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
const settled=promise=>promise.then(value=>({value}),error=>({error}));

const fakeRoot=nodes=>({querySelectorAll:selector=>nodes.filter(node=>selector==='[data-part]'?node.dataset.part:node.dataset.for)});

test('panel ids keep the legacy names for the primary panel and prefix the second',()=>{
  const make=()=>[{dataset:{part:'title'}},{dataset:{part:'status'}},{dataset:{for:'title'}}];
  const left=make(),right=make();
  assignPanelIds(fakeRoot(left),'');assignPanelIds(fakeRoot(right),'right-');
  assert.deepEqual([left[0].id,left[1].id,left[2].htmlFor],['title','status','title']);
  assert.deepEqual([right[0].id,right[1].id,right[2].htmlFor],['right-title','right-status','right-title']);
  assert.equal(partId('right-','result-abc'),'right-result-abc');
});

test('engine details summarise the last completed response and default to a dash',()=>{
  assert.equal(engineDetails(null),'—');
  assert.equal(engineDetails({status:'ok'}),'—');
  const result={workerMs:33.6,plan:{reused:['b','c','d']},evaluation:{evaluated_roots:['a'],values:[{root:'a',reused:false},{root:'b',reused:true}]},transportMetrics:{memoryBytes:96*1024*1024}};
  assert.equal(engineDetails(result),'worker 34 ms · 1 evaluated · 3 reused · 96 MiB');
  delete result.plan;assert.equal(engineStats(result).reused,1);
});

test('package prompts: one prompt per URL, distinct copies of the bytes for every joiner',async()=>{
  const driver=fakeDriver(),prompts=new PackagePrompts(driver);
  const left=prompts.request({url:'https://p.invalid/a.tar.zst',error:'blocked',signal:new AbortController().signal,requester:'Left'});
  const right=prompts.request({url:'https://p.invalid/a.tar.zst',error:'blocked',signal:new AbortController().signal,requester:'Right'});
  await tick();
  assert.equal(driver.prompts.length,1);
  assert.deepEqual(driver.updates.at(-1) ?? driver.prompts[0].requesters,['Left','Right']);
  const bytes=new Uint8Array([1,2,3]);driver.prompts[0].resolve(bytes);
  const [a,b]=await Promise.all([left,right]);
  assert.deepEqual([...a],[1,2,3]);assert.deepEqual([...b],[1,2,3]);
  assert.notEqual(a.buffer,b.buffer);assert.notEqual(a.buffer,bytes.buffer);
});

test('package prompts: aborting one joiner keeps the prompt; aborting all closes it',async()=>{
  const driver=fakeDriver(),prompts=new PackagePrompts(driver);
  const first=new AbortController(),second=new AbortController();
  const a=settled(prompts.request({url:'https://p.invalid/a.tar.zst',error:'',signal:first.signal,requester:'Left'}));
  const b=settled(prompts.request({url:'https://p.invalid/a.tar.zst',error:'',signal:second.signal,requester:'Right'}));
  await tick();
  first.abort();assert.equal((await a).error.name,'AbortError');
  assert.equal(driver.prompts[0].closed,false);assert.deepEqual(driver.updates.at(-1),['Right']);
  second.abort();assert.equal((await b).error.name,'AbortError');
  await tick();assert.equal(driver.prompts[0].closed,true);assert.equal(prompts.current,null);
});

test('package prompts: cancel rejects every joiner; different URLs queue in order; retry prompts alone',async()=>{
  const driver=fakeDriver(),prompts=new PackagePrompts(driver);
  const a=settled(prompts.request({url:'https://p.invalid/a.tar.zst',error:'',signal:new AbortController().signal,requester:'Left'}));
  const b=settled(prompts.request({url:'https://p.invalid/a.tar.zst',error:'',signal:new AbortController().signal,requester:'Right'}));
  const c=prompts.request({url:'https://p.invalid/c.tar.zst',error:'',signal:new AbortController().signal,requester:'Right'});
  await tick();assert.equal(driver.prompts.length,1);
  driver.prompts[0].reject(new DOMException('Package loading cancelled','AbortError'));
  assert.equal((await a).error.name,'AbortError');assert.equal((await b).error.name,'AbortError');
  await tick();assert.equal(driver.prompts.length,2);assert.equal(driver.prompts[1].url,'https://p.invalid/c.tar.zst');
  // A retry is not joined by a later plain request for the same URL.
  const retry=prompts.request({url:'https://p.invalid/c.tar.zst',error:'invalid archive',retry:true,signal:new AbortController().signal,requester:'Left'});
  driver.prompts[1].resolve(new Uint8Array([4]));assert.deepEqual([...await c],[4]);
  await tick();assert.equal(driver.prompts.length,3);assert.equal(driver.prompts[2].retry,true);assert.deepEqual(driver.prompts[2].requesters,['Left']);
  driver.prompts[2].resolve(new Uint8Array([5]));assert.deepEqual([...await retry],[5]);
});

test('a worker re-reads the persistent package cache before fetching an archive another worker stored',async()=>{
  const url='https://packages.invalid/shared.tar.zst',archive=new Uint8Array([7,7,7]);
  const path='/cache/package/'+[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(url)))].map(b=>b.toString(16).padStart(2,'0')).join('');
  let stored=[],loads=0;
  const cache={load:async()=>{loads++;return encodeCacheStream(stored);},save:async()=>{},remove:async()=>{}};
  const installed=[];const transport=Object.assign(async()=>({status:'ok'}),{installPackage:(u,bytes)=>{installed.push([u,[...bytes]]);return true;}});
  const fail=()=>{throw new Error('unexpected download or prompt');};
  const packages=new BrowserPackages(cache,{fetch:fail,loadBundle:fail});
  await packages.load();assert.equal(loads,1);
  stored=[{path,bytes:archive}];
  assert.equal(await packages.install(transport,url),'cached');
  assert.equal(loads,2);assert.deepEqual(installed,[[url,[7,7,7]]]);
  assert.equal(await packages.install(transport,url),'cached');assert.equal(loads,2,'a hit does not re-read storage');
});

test('two notebooks keep their own workers: stop and document switches stay in their panel',async()=>{
  const session=()=>{const s={sent:[],stops:0,invalidations:0,stop(){s.stops++;},invalidate(){s.invalidations++;},request:async request=>{s.sent.push(request);return {status:'ok',graph:{},model:{cells:[],diagnostics:[]},evaluation:{status:'ok',values:[],events:[]}};}};return s;};
  const sessions=[session(),session()],store={save:async()=>{}};
  const [left,right]=sessions.map(s=>new Notebook(null,store,{session:s,debounce:60000}));
  left.state=newDraft('Left');right.state=newDraft('Right');left.state.autoRun=right.state.autoRun=false;
  await left.run();await right.run();
  const before={stops:sessions[1].stops,invalidations:sessions[1].invalidations};
  left.stop();
  assert.equal(sessions[0].stops,1);assert.deepEqual({stops:sessions[1].stops,invalidations:sessions[1].invalidations},before);
  await right.run();assert.deepEqual(sessions[1].sent.at(-1).reactivity,{});
  await left.replace(newDraft('Other'));await left.run();await right.run();
  assert.deepEqual(sessions[0].sent.at(-1).reactivity,{reset:true});assert.deepEqual(sessions[1].sent.at(-1).reactivity,{});
  left.dispose();right.dispose();
});

test('the engine details preference defaults off and survives unavailable storage',()=>{
  const values=new Map(),storage={getItem:key=>values.get(key)??null,setItem:(key,value)=>values.set(key,value)};
  assert.equal(readPreference(storage,engineDetailsKey),false);
  writePreference(storage,engineDetailsKey,true);assert.equal(readPreference(storage,engineDetailsKey),true);
  const broken={getItem(){throw new Error('denied');},setItem(){throw new Error('denied');}};
  assert.equal(readPreference(broken,engineDetailsKey),false);writePreference(broken,engineDetailsKey,true);
  assert.equal(readPreference(null,engineDetailsKey),false);
});
