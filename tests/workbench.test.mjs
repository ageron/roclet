import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assignPanelIds,partId} from '../web/workbench.mjs';

const fakeRoot=nodes=>({querySelectorAll:selector=>nodes.filter(node=>selector==='[data-part]'?node.dataset.part:node.dataset.for)});

test('panel ids keep the legacy names for the primary panel and prefix the second',()=>{
  const make=()=>[{dataset:{part:'title'}},{dataset:{part:'status'}},{dataset:{for:'title'}}];
  const left=make(),right=make();
  assignPanelIds(fakeRoot(left),'');assignPanelIds(fakeRoot(right),'right-');
  assert.deepEqual([left[0].id,left[1].id,left[2].htmlFor],['title','status','title']);
  assert.deepEqual([right[0].id,right[1].id,right[2].htmlFor],['right-title','right-status','right-title']);
  assert.equal(partId('right-','result-abc'),'right-result-abc');
});
