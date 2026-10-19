// The app header is a normal editable Roc source block, outside the cell list.
(async()=>{
  const $=id=>document.getElementById(id),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const until=async predicate=>{for(let i=0;i<900;i++){if(predicate())return;await pause(100);}throw Error('Timed out: '+$('status').textContent+' '+$('notice').textContent);};
  await until(()=>document.documentElement.dataset.ready==='true' && $('status').textContent.startsWith('Current'));
  const {editorFor}=await import('/web/cell-editor.mjs');
  const editor=editorFor(document.querySelector('#app-header-source .cm-content')),original=editor.source;
  assert(!$('app-header').open,'The app header should be collapsed on first opening');
  $('app-header').querySelector('summary').click();assert($('app-header').open,'Header did not expand');
  assert(original.includes('app [] {') && original.includes('roc-time-7QH5V') && original.includes('import time.ExactInterval') && original.includes('import time.Coverage'),'The full original header is not visible');
  assert(!document.querySelector('#notebook').textContent.includes('Unused Branch'),'Empirical warning is visible');
  const cells=[...document.querySelectorAll('#notebook .cm-content')].map(node=>editorFor(node).source);
  $('app-header').querySelector('summary').click();assert(!$('app-header').open,'Header did not collapse');
  $('app-header').querySelector('summary').click();assert($('app-header').open,'Header did not expand');
  const replace=source=>editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:source},userEvent:'input'});
  // Header edits use the same automatic compilation path as cell edits.
  editor.focus();replace(original.replace('import time.Coverage','import time.NotAModule'));$('app-header').querySelector('summary').focus();
  await until(()=>/attention|failed/i.test($('status').textContent));
  assert(!document.querySelector('#notebook .value[data-stale="false"]'),'Broken header left current results');
  assert($('document-diagnostics').textContent.includes('NotAModule'),'Header import diagnostic is missing');
  editor.focus();editor.element.dispatchEvent(new KeyboardEvent('keydown',{key:'z',ctrlKey:true,bubbles:true,cancelable:true}));
  await until(()=>$('status').textContent.startsWith('Current'));assert(editor.source===original,'Header undo did not restore the source');
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  replace(original+'\n# QA header comment\n');editor.focus();
  editor.element.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));
  await until(()=>$('status').textContent.startsWith('Current'));
  assert([...document.querySelectorAll('#notebook .cm-content')].map(editorFor).find(cell=>cell.source.includes('out_candidates =')).dom.closest('.cell').querySelectorAll('.value[data-stale="false"] table tbody tr').length===3,'Header run shortcut did not evaluate');
  await until(()=>$('save-status').textContent==='Saved in this browser');
  const {DraftStore}=await import('/web/studio-store.mjs'),store=new DraftStore();
  try {assert((await store.list()).some(record=>record.preamble===editor.source),'Header edit was not autosaved');}finally{store.close();}
  $('source-view').click();await until(()=>!$('source-pane').hidden);
  assert($('app-header').hidden,'Header card is repeated in source view');
  assert(editorFor(document.querySelector('#source .cm-content')).source.includes('# QA header comment'),'Source view lost header edits');
  $('notebook-view').click();await until(()=>!$('notebook').hidden);
  assert(editor.source.includes('# QA header comment'),'Returning to notebook lost header edits');
  $('undo').click();$('run').click();await until(()=>$('status').textContent.startsWith('Current'));
  assert(editor.source===original,'Original header was not restored');
  assert(JSON.stringify([...document.querySelectorAll('#notebook .cm-content')].map(node=>editorFor(node).source))===JSON.stringify(cells),'Header edits changed notebook cells');
  $('app-header').open=true;
  return {result:'pass',header:editor.source,verified:'expand/collapse, auto-run, import diagnostics, undo, Ctrl+Enter, autosave, source view, cell preservation',horizontalOverflow:document.documentElement.scrollWidth>innerWidth};
})()
