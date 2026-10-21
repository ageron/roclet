// Run on a static server with endpoint:null and browser-check's --upload-plan,
// against edit.html?example=meeting-windows&right=example:meeting-windows.
// The plan selects one file: the roc-time 0.2.0 bundle. Both panels need it;
// one dialog and one selection must serve both.
(async()=>{
  const $=id=>document.getElementById(id),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const assert=(ok,message)=>{if(!ok)throw Error(message);};
  const status=slot=>$(slot==='left'?'status':'right-status').textContent;
  const until=async(predicate,what)=>{for(let i=0;i<1200;i++){if(predicate())return;await pause(100);}throw Error(`Timed out: ${what} · ${status('left')} · ${status('right')} · ${$('package-status').textContent}`);};
  const dialog=()=>$('package-dialog').open;
  const choose=()=>globalThis.__rocletFilePicker('#package-load');
  const current=slot=>document.querySelectorAll(`[data-panel="${slot}"] .value[data-stale="false"]`).length;
  const cached=async()=>{
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('roclet-build-cache');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
    try {return await new Promise((resolve,reject)=>{const r=db.transaction('entries').objectStore('entries').getAll();r.onsuccess=()=>resolve(r.result.filter(entry=>entry.namespace.endsWith(':packages')).length);r.onerror=()=>reject(r.error);});}finally{db.close();}
  };
  await until(()=>document.documentElement.dataset.ready==='true','startup');
  assert((await fetch('/web/package-config.json').then(r=>r.json())).endpoint===null,'Static fallback must run without a proxy');
  assert(document.querySelectorAll('.notebook-panel').length===2,'Two panels did not open');
  assert(new URL(location.href).searchParams.get('right')!==new URL(location.href).searchParams.get('notebook'),'Both panels hold the same draft');
  await until(dialog,'the package dialog');
  await until(()=>/^Needed by: .+, .+/.test($('package-needed').textContent),'both panels to join the prompt');
  assert(status('left').startsWith('Waiting for package') && status('right').startsWith('Waiting for package'),'A panel is not waiting for the package');
  assert($('package-download').href.includes('roc-time/releases/download/0.2.0/'),'Download link lost the compiler-resolved package URL');
  const neededBy=$('package-needed').textContent;
  choose();
  await until(()=>status('left').startsWith('Current') && status('right').startsWith('Current'),'both panels to resume');
  assert(!dialog(),'The dialog stayed open');
  for(const slot of ['left','right']) {
    assert(current(slot)===6,`${slot} panel does not show six current values`);
    assert(status(slot).includes('2 tests passed'),`${slot} calendar assertions failed`);
    assert(document.querySelector(`[data-panel="${slot}"]`).textContent.includes('Book 15 Jun 2026, 09:00–09:45 UTC.'),`${slot} calendar result is wrong`);
  }
  assert(await cached()===1,'Expected exactly one verified package entry');
  for(const [stop,run,slot] of [['stop','run','left'],['right-stop','right-run','right']]) {
    $(stop).click();$(run).click();await until(()=>status(slot).startsWith('Current'),`${slot} restart`);
    assert(!dialog(),`Restarting the ${slot} panel prompted again`);
  }
  assert(document.documentElement.scrollWidth<=innerWidth,'The page overflowed');
  return {result:'pass',layout:$('workbench').dataset.layout,neededBy,verifiedArchives:await cached(),statuses:[status('left'),status('right')],freshWorkerRestore:'pass'};
})()
