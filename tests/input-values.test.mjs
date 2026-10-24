import {test} from 'node:test';
import assert from 'node:assert/strict';
import {inputValues,inputModule,sliderConfig} from '../web/input-values.mjs';
import {Notebook,newDraft,requestFor,validDraft} from '../web/edit-model.mjs';
test('inputs validate imported state and cannot inject Roc source',()=>{
  for(const raw of [null,[],{width:NaN},{width:Infinity},{'x"; echo!("oops")':1},JSON.parse('{"__proto__":1}')]) assert.throws(()=>inputValues(raw));
  assert.deepEqual(inputValues(),{});
  assert.equal(sliderConfig('{"key":"width"}'),null);
  assert.equal(validDraft({...newDraft(),inputValues:{width:Infinity}}),false);
});
test('input values are evaluated but never embedded into exported source',()=>{
  const state=newDraft();state.inputValues={width:8};
  assert.match(requestFor(state,'evaluate').modules[0].content,/8.0/);
  assert.equal(requestFor(state,'export').modules,undefined);
  assert.equal(inputModule({b:2,a:1}).content,inputModule({a:1,b:2}).content);
});
test('slider changes invalidate results, persist and undo without altering source',async()=>{
  let saved;
  const notebook=new Notebook(null,{save:async state=>{saved=state;}},{session:{invalidate(){},stop(){}},debounce:60000});
  notebook.state=newDraft();notebook.state.autoRun=false;notebook.state.sourceCurrent=true;notebook.state.source='out_1 = 3';
  notebook.result={status:'ok'};
  notebook.setInputValue('width',8);await notebook.persist();
  assert.equal(notebook.result,null);assert.equal(saved.inputValues.width,8);assert.equal(notebook.state.sourceCurrent,true);
  assert.equal(notebook.state.source,'out_1 = 3');notebook.undo();assert.deepEqual(notebook.state.inputValues,{});
  notebook.dispose();
});

test('custom numeric controls validate bounds and HTML payloads',()=>{
  const c={key:'wall',label:'Wall',min:'1',max:'20',default:'5',value:'8',html:'<p>Wall</p>'};
  assert.equal(sliderConfig(JSON.stringify(c),true).value,8);
  for(const changes of [{value:'NaN'},{value:21},{html:'x'.repeat(16385)},{key:'bad key'},{min:30}]) assert.equal(sliderConfig(JSON.stringify({...c,...changes}),true),null);
});
