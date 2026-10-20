import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assignPanelIds,partId,engineDetails,engineStats,engineDetailsKey,readPreference,writePreference,parseLayout,parseSlot,layoutUrl,openDecision,documentTitle,statusDot,Workbench} from '../web/workbench.mjs';
import {PackagePrompts} from '../web/package-dialog.mjs';
import {BrowserPackages} from '../web/packages.mjs';
import {encodeCacheStream} from '../web/build-cache.mjs';
import {Notebook,newDraft,independentCopy,validDraft} from '../web/edit-model.mjs';

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

test('layout URLs name the right slot and leave one-panel URLs alone',()=>{
  const base='https://roclet.test/web/edit.html';
  assert.deepEqual(parseLayout(`${base}?notebook=A&right=B`),{left:{id:'A',fresh:false,example:null,publication:null},right:{id:'B'}});
  assert.deepEqual(parseLayout(`${base}?example=reactivity&right=example:weather`).right,{example:'weather'});
  assert.equal(parseLayout(`${base}?example=reactivity&right=example:weather`).left.example,'reactivity');
  assert.deepEqual(parseSlot('new'),{fresh:true});
  assert.match(parseSlot('example:https://evil.invalid/x.roc').error,/Unknown example/);
  assert.equal(parseSlot(''),null);assert.equal(parseLayout(`${base}?notebook=A`).right,null);
  assert.equal(layoutUrl(`${base}?example=reactivity&right=new#top`,{left:'A',right:'B'}),'/web/edit.html?notebook=A&right=B#top');
  assert.equal(layoutUrl(`${base}?notebook=A&right=B`,{}),'/web/edit.html');
  // Round trip: the written URL restores the same two drafts.
  const written=layoutUrl(base,{left:'id 1',right:'id/2'}),restored=parseLayout(new URL(written,base).href);
  assert.deepEqual([restored.left.id,restored.right.id],['id 1','id/2']);
});

test('a draft can be open in only one panel',()=>{
  assert.deepEqual(openDecision({left:'A',right:'B'},'right','A'),{action:'refuse',other:'left'});
  assert.deepEqual(openDecision({left:'A',right:'B'},'left','B'),{action:'refuse',other:'right'});
  assert.deepEqual(openDecision({left:'A',right:'B'},'right','B'),{action:'noop'});
  assert.deepEqual(openDecision({left:'A',right:null},'right','C'),{action:'open'});
  assert.deepEqual(openDecision({left:'A',right:null},'left','B'),{action:'open'});
  assert.deepEqual(openDecision({left:'A',right:'B'},'right',null),{action:'open'});
});

test('titles and tab status dots describe each panel',()=>{
  assert.equal(documentTitle(['Wall area']),'Roclet: Wall area');
  assert.equal(documentTitle(['Left','']),'Roclet: Left | Untitled');
  assert.equal(documentTitle([]),'Roclet');
  assert.equal(statusDot({status:'Running…',saveStatus:'Saved in this browser'}).state,'running');
  assert.equal(statusDot({status:'Needs attention · 1 failed test',saveStatus:'Saved in this browser'}).state,'attention');
  assert.equal(statusDot({status:'Running…',saveStatus:'Not saved: quota. Download a copy.'}).state,'unsaved');
  assert.equal(statusDot({status:'Current · 2 results',saveStatus:'Saved in this browser'}).state,'idle');
  // A notebook's current operation decides activity, not its status wording.
  assert.equal(statusDot({status:'Waiting for package…',saveStatus:'Saved in this browser',busy:false}).state,'idle');
  assert.equal(statusDot({status:'Ready',saveStatus:'Saved in this browser',busy:true}).state,'running');
});

test('an independent copy has a new id, fresh cell keys and the same content',()=>{
  const original={...newDraft('Notes',true),files:[{path:'Geometry.roc',source:'module [area]\narea = 15'}],_storageVersion:'v1'};
  const copy=independentCopy(original);
  assert(validDraft(copy));assert.notEqual(copy.id,original.id);assert.equal(copy.title,'Notes (copy)');
  assert.equal(copy._storageVersion,undefined);assert.equal(copy.revision,1);
  assert.deepEqual(copy.cells.map(c=>c.source),original.cells.map(c=>c.source));
  assert(copy.cells.every((cell,i)=>cell.key!==original.cells[i].key));
  assert.deepEqual(copy.files,original.files);assert.notEqual(copy.files,original.files);
  assert(independentCopy({...original,title:'x'.repeat(200)}).title.length<=120);
});

// Panels made of a real Notebook with a fake session and an in-memory store.
function memoryStore(records=new Map()) {
  return {records,closed:false,
    async get(id){const r=records.get(id);return r&&structuredClone(r);},
    async save(record){records.set(record.id,structuredClone(record));},
    async list(){return [...records.values()].map(r=>structuredClone(r));},
    async fork(){return memoryStore(records);},close(){this.closed=true;}};
}
function fakeWorkbench(records) {
  const store=memoryStore(records),history={urls:[],replaceState(_,__,url){this.urls.push(url);}};
  const created=[];
  const bench=new Workbench({store,history,location:{href:'https://roclet.test/web/edit.html'},document:{title:''},
    createPanel:({slot,store,onChange})=>{
      const session={stop(){},invalidate(){},request:async()=>({status:'ok',graph:{},model:{cells:[],diagnostics:[]},evaluation:{status:'ok',values:[],events:[]}})};
      const panel={slot,store,notices:[],disposed:false,focused:0,revealed:[],reveal(options){this.revealed.push(options);},
        notebook:new Notebook(null,store,{session,debounce:60000,onChange:reason=>onChange(panel,reason)}),
        get title(){return this.notebook.state?.title||'Untitled';},
        notice(message,actions=[]){this.notices.push({message,actions});},focus(){this.focused++;},
        dispose(){this.disposed=true;this.notebook.dispose();}};
      created.push(panel);return panel;
    }});
  return {bench,store,history,created,page:bench.page};
}

test('the workbench opens a second draft, refuses a duplicate and offers a copy',async()=>{
  const a=newDraft('Alpha'),b=newDraft('Beta');a.autoRun=b.autoRun=false;
  const {bench,history,created,page}=fakeWorkbench(new Map([[a.id,a],[b.id,b]]));
  const left=await bench.addPanel('left');await left.notebook.initialize({id:a.id});
  const right=await bench.open('right',{id:b.id});
  assert.equal(bench.panels.length,2);assert.equal(right.notebook.state.id,b.id);assert.notEqual(right.store,left.store);
  assert.equal(history.urls.at(-1),`/web/edit.html?notebook=${a.id}&right=${b.id}`);
  assert.equal(page.title,'Roclet: Alpha | Beta');assert.equal(bench.active,right);
  assert.deepEqual(right.revealed,[{schedule:true}],'a new panel is revealed once its document is loaded');
  // Choosing the left draft in the right panel leaves the right panel as it was.
  await bench.open('right',{id:a.id});
  assert.equal(right.notebook.state.id,b.id);
  const refusal=right.notices.at(-1);assert.match(refusal.message,/already open in the left panel/);
  const [goTo,copy]=refusal.actions;assert.equal(goTo[0],'Go to it');assert.equal(copy[0],'Open an independent copy here');
  goTo[1]();assert.equal(bench.active,left);assert.equal(left.focused,1);
  await copy[1]();
  assert.notEqual(right.notebook.state.id,a.id);assert.equal(right.notebook.state.title,'Alpha (copy)');
  assert.equal(right.notebook.saveStatus,'Saved in this browser');assert.equal(left.notebook.saveStatus,'Saved in this browser');
  assert.equal(created.length,2);bench.dispose();
});

test('closing the left panel moves the right document into the left slot',async()=>{
  const a=newDraft('Alpha'),b=newDraft('Beta');a.autoRun=b.autoRun=false;
  const {bench,history}=fakeWorkbench(new Map([[a.id,a],[b.id,b]]));
  const left=await bench.addPanel('left');await left.notebook.initialize({id:a.id});
  const right=await bench.open('right',{id:b.id});
  right.notebook.change(s=>{s.title='Beta edited';});
  await bench.close('left');
  assert.equal(bench.panels.length,1);assert(right.disposed);assert(right.store.closed);
  assert.equal(left.notebook.state.id,b.id);assert.equal(left.notebook.state.title,'Beta edited');
  assert.equal(left.notebook.resetBaseline,true,'the next request resets the engine baseline');
  assert.equal(left.notebook.saveStatus,'Saved in this browser');
  assert.equal(history.urls.at(-1),'/web/edit.html');
  // A refused URL right=left opens an empty right panel with the notice.
  const refused=await bench.open('right',{id:b.id},{focus:false});
  assert.equal(refused.notebook.state,null);assert.match(refused.notices.at(-1).message,/already open/);
  assert.equal(refused.revealed.length,1,'a refused panel is still shown with its notice');
  await bench.close('right');assert.equal(bench.panels.length,1);bench.dispose();
});

test('the engine details preference defaults off and survives unavailable storage',()=>{
  const values=new Map(),storage={getItem:key=>values.get(key)??null,setItem:(key,value)=>values.set(key,value)};
  assert.equal(readPreference(storage,engineDetailsKey),false);
  writePreference(storage,engineDetailsKey,true);assert.equal(readPreference(storage,engineDetailsKey),true);
  const broken={getItem(){throw new Error('denied');},setItem(){throw new Error('denied');}};
  assert.equal(readPreference(broken,engineDetailsKey),false);writePreference(broken,engineDetailsKey,true);
  assert.equal(readPreference(null,engineDetailsKey),false);
});

test('panels opened while the page starts are revealed without starting evaluation',async()=>{
  const a=newDraft('Alpha'),b=newDraft('Beta');
  const {bench}=fakeWorkbench(new Map([[a.id,a],[b.id,b]]));
  const left=await bench.addPanel('left');await left.notebook.initialize({id:a.id});
  bench.holdScheduling=true;
  const right=await bench.open('right',{id:b.id},{focus:false});
  assert.deepEqual(right.revealed,[{schedule:false}]);bench.dispose();
});
