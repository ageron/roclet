import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assignPanelIds,partId,engineDetails,engineStats,engineDetailsKey,readPreference,writePreference} from '../web/workbench.mjs';

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

test('the engine details preference defaults off and survives unavailable storage',()=>{
  const values=new Map(),storage={getItem:key=>values.get(key)??null,setItem:(key,value)=>values.set(key,value)};
  assert.equal(readPreference(storage,engineDetailsKey),false);
  writePreference(storage,engineDetailsKey,true);assert.equal(readPreference(storage,engineDetailsKey),true);
  const broken={getItem(){throw new Error('denied');},setItem(){throw new Error('denied');}};
  assert.equal(readPreference(broken,engineDetailsKey),false);writePreference(broken,engineDetailsKey,true);
  assert.equal(readPreference(null,engineDetailsKey),false);
});
