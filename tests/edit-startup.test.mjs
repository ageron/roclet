import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Notebook,newDraft} from '../web/edit-model.mjs';

test('startup defers automatic work until the selected notebook can be revealed',async()=>{
  const requested=[];
  const notebook=new Notebook(null,{save:async()=>{},list:async()=>[]},{
    session:{invalidate(){},stop(){},request:async value=>{
      requested.push(value);
      return {status:'ok',model:{cells:[],diagnostics:[]},evaluation:{status:'ok',values:[],events:[]}};
    }},
    deferScheduling:true,debounce:5,
  });
  try {
    await notebook.initialize({fresh:true});
    await notebook.replace(newDraft('Selected notebook'));
    await new Promise(resolve=>setTimeout(resolve,20));
    assert.equal(requested.length,0,'opening a document must not start an evaluation behind the loading gate');
    notebook.resumeScheduling();
    for(let i=0;i<100 && !requested.length;i++)await new Promise(resolve=>setTimeout(resolve,1));
    assert.equal(requested.length,1);
    assert.equal(requested[0].action,'evaluate');
    assert.equal(notebook.state.title,'Selected notebook');
  } finally {notebook.dispose();}
});
