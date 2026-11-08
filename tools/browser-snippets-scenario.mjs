// Exercise the real picker, package insertion, evaluator and notebook history.
export default async function({evaluate,send}) {
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const until=async expression=>{const end=Date.now()+30000;while(!await evaluate(expression)){if(Date.now()>end)throw Error(`Timed out: ${expression}`);await pause(30);}};
  await until("document.documentElement.dataset.ready==='true'");
  const results=await evaluate(`(async()=>{
    const assert=(ok,message)=>{if(!ok)throw Error(message);};
    const {workbench}=await import('/web/edit.mjs');
    const {snippets,dependencies}=await import('/web/snippets.mjs');
    const {newDraft}=await import('/web/edit-model.mjs');
    const panel=workbench().active,notebook=panel.notebook;
    const manifest=await fetch('/web/vendor/roc-packages/manifest.json').then(r=>r.json());
    const displayPin=(await fetch('/dependencies/roclet-display-url.txt').then(r=>r.text())).trim();
    const urls=Object.fromEntries(Object.entries(dependencies).map(([id,d])=>[id,d.pin?displayPin:manifest.packages.find(p=>p.package===d.repository && p.version===d.version).url]));
    const results=[];
    for(const snippet of snippets){
      const draft=newDraft();draft.autoRun=false;await notebook.replace(draft);
      panel.insertSnippet(snippet,urls,1);
      const source=notebook.state.cells[1].source;
      assert(!source.includes('{{'),'Unresolved placeholder '+snippet.id);
      const result=await notebook.run();
      assert(result.status==='ok',snippet.id+': '+JSON.stringify(result));
      assert(result.evaluation.values.length>0,'No output: '+snippet.id);
      if(typeof snippet.preview!=='string')assert(result.evaluation.values.some(v=>v.display?.kind===snippet.preview.kind),'Wrong rich output: '+snippet.id+': '+JSON.stringify(result));
      notebook.undo();assert(notebook.state.cells.length===1 && notebook.state.preamble===draft.preamble,'Partial undo: '+snippet.id);
      notebook.undo(true);assert(notebook.state.cells.length===2,'Redo: '+snippet.id);
      panel.insertSnippet(snippet,urls,2);
      assert(notebook.state.cells[2].source!==source,'Duplicate names: '+snippet.id);
      const repeated=await notebook.run();assert(repeated.status==='ok','Repeated '+snippet.id+': '+JSON.stringify(repeated));
      results.push(snippet.id);
    }
    // Existing built-in imports and source view also remain usable.
    await notebook.replace({...newDraft(),autoRun:false,preamble:'import Display'});
    panel.insertSnippet(snippets.find(s=>s.id==='slider'),urls,1);
    const mixed=await notebook.run();assert(mixed.status==='ok' && mixed.evaluation.values.some(v=>v.display?.kind==='slider'),'Built-in Display with Input import: '+JSON.stringify(mixed));
    await notebook.mode('source');await panel.prepareInsertion();panel.insertSnippet(snippets.find(s=>s.id==='table'),urls,1);
    assert(notebook.state.mode==='notebook' && (await notebook.run()).status==='ok','Source view insertion');
    await notebook.replace({...newDraft(),autoRun:false});
    document.querySelector('#insert-menu summary').click();document.querySelector('[data-insert-category=widgets]').click();
    return results;
  })()`);
  await until("document.querySelector('#snippet-dialog').open");
  if(!await evaluate("document.querySelector('[data-snippet=category]').value==='widgets' && document.querySelectorAll('[data-snippet=list] button').length===3"))throw Error('Wrong widget filter');
  await evaluate("document.querySelector('[data-snippet=insert]').click()");
  await until("!document.querySelector('#snippet-dialog').open");
  if(!await evaluate("document.activeElement.closest('.cell')?.textContent.includes('slider')"))throw Error('Inserted cell not focused');
  if(!await evaluate("(()=>{const editor=[...document.querySelectorAll('.cell .cm-editor')].at(-1);return editor && window.getSelection().toString()==='5';})()"))throw Error('Default value not selected');
  // Start insertion before the first cell via its rail, then cancel without a change.
  await evaluate("document.querySelector('.insertion button:last-child').click()");
  await until("document.querySelector('#snippet-dialog').open");
  if(!await evaluate("document.querySelector('[data-snippet=target]').textContent.includes('at start')"))throw Error('Wrong insertion position');
  await evaluate("document.querySelector('[data-snippet=search]').value='no such snippet';document.querySelector('[data-snippet=search]').dispatchEvent(new Event('input'))");
  if(!await evaluate("document.querySelector('[data-snippet=insert]').disabled && !document.querySelector('[data-snippet=empty]').hidden"))throw Error('Empty search did not disable Insert');
  await send('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await send('Input.dispatchKeyEvent',{type:'keyUp',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await until("!document.querySelector('#snippet-dialog').open");
  // Keep a chart selected for visual inspection of the picker.
  await evaluate("document.querySelector('#insert-menu summary').click();document.querySelector('[data-insert-category=charts]').click()");
  await until("document.querySelector('#snippet-dialog').open");
  await until("document.querySelector('[data-snippet=preview] iframe')!==null");
  await evaluate("document.querySelector('[data-snippet=preview] .rich-output').rendered");
  if(!await evaluate("(()=>{const frame=document.querySelector('[data-snippet=preview] iframe');return frame && !frame.failed && frame.getBoundingClientRect().height>100;})()"))throw Error('Chart preview did not render');
  if(!await evaluate("(()=>{const r=document.querySelector('[data-snippet=insert]').getBoundingClientRect();return r.top>=0 && r.bottom<=innerHeight;})()"))throw Error('Insert button is outside the viewport');
  return {result:'pass',evaluated:results,checks:'single undo/redo, repeated insertion, package imports, filters, rail position, focus, selected default, empty search, Escape'};
}
