// Real editor integration. Run with browser-check.mjs on web/edit.html?new=1.
// ?parser-demo=1 additionally uses unchanged release archives mirrored under
// artifacts/browser-packages to verify the published roc-parser CSV example.
(async()=>{
  const $=id=>document.getElementById(id),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const until=async(predicate,label)=>{for(let i=0;i<900;i++){if(predicate())return;await pause(50);}throw Error(`Timed out: ${label}; ${$('status').textContent}; ${$('attachment-status').textContent}`);};
  await until(()=>document.documentElement.dataset.ready==='true','editor startup');
  const {workbench}=await import('/web/edit.mjs'),bench=workbench(),notebook=bench.active.notebook;
  const {captureExport,exportBundle,importBundle,exportReport}=await import('/web/sharing.mjs');
  const manifest=await fetch('/artifacts/manifest.json').then(response=>response.json());
  const reports=[];
  const textValue=text=>'['+[...new TextEncoder().encode(text)].join(', ')+']';
  if(new URL(location.href).searchParams.has('verify-demo-startup')) {
    // Exercise the actual ?example= launch path, not Workbench.load after the
    // editor has already started. No external package downloads are needed to
    // verify that the selected example mounted its original attachment.
    notebook.stop();
    const files=notebook.state.attachments??[];
    assert(files.length===1 && files[0].path==='data/cafe-sales.csv','Direct demo launch did not load its CSV attachment');
    const original=await fetch('/demos/data/cafe-sales.csv').then(response=>response.text());
    assert(await files[0].blob.text()===original,'Direct demo launch changed the CSV bytes');
    const {DocumentSession}=await import('/web/document-session.mjs');
    const session=new DocumentSession(await fetch('/artifacts/roclet.wasm').then(response=>response.arrayBuffer()));
    try {
      const result=await session.request({operation:'document',action:'evaluate',format:'roc',source:'app [] {}\n# %%\nimport "data/cafe-sales.csv" as csv : Str\nout_bytes = Str.to_utf8(csv)',files:files.map(file=>({...file,path:`/workspace/${file.path}`}))});
      assert(result.status==='ok',JSON.stringify(result));
      assert(result.evaluation.values[0].text===textValue(original),'Direct demo launch did not supply its CSV to Roc');
    } finally {session.stop();}
    await notebook.persist();
    const stored=await bench.active.store.get(notebook.state.id);
    assert(stored.attachments.length===1 && await stored.attachments[0].blob.text()===original,'Direct demo launch did not persist its CSV attachment');
    return {result:'pass',checks:['direct CSV demo URL loads, mounts and persists its attachment before evaluation']};
  }
  notebook.state.autoRun=false;
  const source='app [main!] {}\n# %%\nimport "data/values.csv" as csv : Str\nout_text = Str.to_utf8(csv)\n# %%\nimport "data/raw.bin" as bytes : List(U8)\nout_bytes = bytes\n# %%\nout_constant = 7\n';
  await notebook.open(source,'Attachment checks.roc');notebook.state.autoRun=false;
  const open=async()=>{$('document-menu').open=true;$('attachments').click();await until(()=>$('attachments-dialog').open,'attachments dialog');};
  const close=()=>$('attachments-dialog').close();
  const select=async path=>{
    const entry=[...$('attachment-list').children].find(node=>node.dataset.path===path);assert(entry,`Missing attachment ${path}`);entry.click();
    await until(()=>$('attachment-path').value===path && $('attachment-preview').textContent!=='Loading preview…','attachment selection');
  };
  const choose=(id,files)=>{
    const transfer=new DataTransfer();for(const file of files)transfer.items.add(file);
    $(id).files=transfer.files;$(id).dispatchEvent(new Event('change',{bubbles:true}));
  };
  await open();assert(!$('attachment-empty').hidden,'Empty state is missing');
  const original='name,value\r\n"café, north",42\r\n';
  choose('attachment-upload',[new File([original],'values.csv',{type:'text/csv'})]);
  await until(()=>notebook.state.attachments.length===1 && $('attachment-status').textContent.includes('File copied'),'file import');
  assert($('attachment-import').value==='import "data/values.csv" as file_data : Str','Text import snippet is incorrect');
  assert($('attachment-preview').textContent===original,'Text preview changed UTF-8 or CRLF');
  const raw=[0,255,254,128,13,10],transfer=new DataTransfer();transfer.items.add(new File([new Uint8Array(raw)],'raw.bin'));
  $('attachment-drop').dispatchEvent(new DragEvent('drop',{dataTransfer:transfer,bubbles:true,cancelable:true}));
  await until(()=>notebook.state.attachments.length===2 && $('attachment-status').textContent.includes('File copied'),'binary drop');
  assert($('attachment-kind').value==='bytes','Binary file did not default to byte import');
  assert($('attachment-import').value.endsWith(': List(U8)'),'Binary import snippet is missing');
  close();
  let result=await notebook.run();assert(result.status==='ok',JSON.stringify(result));
  const value=root=>notebook.result?.evaluation?.values?.find(value=>value.root===root)?.text;
  assert(value('out_text')===textValue(original),'Roc did not receive exact UTF-8');
  assert(value('out_bytes')==='[0, 255, 254, 128, 13, 10]','Roc did not receive exact binary bytes');
  await notebook.run();assert(notebook.result.transportMetrics.fileBytes===0,'Unchanged attachments were retransmitted');
  notebook.editCell(2,'value : Try(U64, [Bad])\nvalue = Ok(7)\n\nout_constant = match value {\n    Ok(n) => n\n    Err(_) => 0\n}');
  await notebook.run();
  assert(notebook.result.model.diagnostics.some(d=>d.message.startsWith('**Unused Branch**')),'Fixture did not produce the empirical compiler warning');
  assert(![...document.querySelectorAll('.diagnostic')].some(node=>node.textContent.includes('Unused Branch')),'Empirical warning is visible in the editor');
  const report=await exportReport(await captureExport(notebook,manifest,{results:true}));
  assert(!(await report.text()).includes('Unused Branch'),'Empirical warning is visible in the exported report');
  reports.push('empirical branch warnings stay in compiler data and are hidden from the editor and report');
  reports.push('file picker and drop handlers, bounded previews, import snippets, exact UTF-8 and raw bytes in Roc');

  await open();await select('data/values.csv');
  choose('attachment-upload',[new File(['duplicate'],'values.csv')]);
  await until(()=>$('attachment-status').dataset.error==='true','duplicate rejection');
  assert(notebook.state.attachments.length===2 && await notebook.state.attachments[0].blob.text()===original,'Duplicate import overwrote existing data');
  $('auto').checked=true;$('auto').dispatchEvent(new Event('change'));
  choose('attachment-replacement',[new File(['replacement ✓\n'],'another-name.txt')]);
  await until(()=>$('attachment-status').textContent.startsWith('Replaced'),'replacement');
  assert(notebook.state.attachments.some(file=>file.path==='data/values.csv'),'Replacement renamed the path');
  await until(()=>value('out_text')===textValue('replacement ✓\n'),'automatic recomputation after replacement');
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  close();
  assert(value('out_text')===textValue('replacement ✓\n'),'Replacement returned stale text');
  notebook.undo();await notebook.run();assert(value('out_text')===textValue(original),'Undo did not restore the original bytes');
  await open();await select('data/raw.bin');$('attachment-remove').click();
  await until(()=>notebook.state.attachments.length===1,'removal');close();
  result=await notebook.run();assert(result.status!=='ok','Missing attachment did not produce a diagnostic');
  assert(!document.querySelector('#notebook .value[data-stale="false"]'),'Removed attachment left current outputs visible');
  notebook.undo();await notebook.run();assert(value('out_bytes')==='[0, 255, 254, 128, 13, 10]','Undo removal did not restore bytes');
  await open();await select('data/raw.bin');$('attachment-path').value='data/renamed.bin';$('attachment-rename').click();
  await until(()=>$('attachment-status').textContent.startsWith('Path updated'),'path update');
  assert($('attachment-import').value.includes('data/renamed.bin'),'Import snippet did not follow renamed path');
  $('attachment-undo').click();await until(()=>notebook.state.attachments.some(file=>file.path==='data/raw.bin'),'inline undo');close();await notebook.run();
  reports.push('duplicate protection, stable replacement paths, removal diagnostics, rename and undo');

  await notebook.persist();
  const {DraftStore}=await import('/web/edit-store.mjs'),store=new DraftStore();
  const saved=await store.get(notebook.state.id);store.close();
  assert(saved.attachments.length===2 && saved.attachments.every(file=>file.blob instanceof Blob),'Browser persistence lost attachment blobs');
  assert(await saved.attachments.find(file=>file.path==='data/values.csv').blob.text()===original,'Persisted UTF-8 changed');
  assert(JSON.stringify([...new Uint8Array(await saved.attachments.find(file=>file.path==='data/raw.bin').blob.arrayBuffer())])===JSON.stringify(raw),'Persisted binary changed');
  const capture=await captureExport(notebook,manifest,{results:true}),bundle=await exportBundle(capture);
  const imported=await importBundle(await bundle.arrayBuffer(),manifest);
  assert(imported.record.attachments.length===2 && imported.record.autoRun===false,'Bundle did not restore attachments safely');
  const previous=notebook.state.id;
  choose('open',[new File([bundle],'attachments.roclet.zip',{type:'application/zip'})]);
  await until(()=>notebook.state.id!==previous,'bundle opening through File menu');
  result=await notebook.run();assert(result.status==='ok',JSON.stringify(result));
  assert(value('out_text')===textValue(original) && value('out_bytes')==='[0, 255, 254, 128, 13, 10]','Bundle restored different computations');
  notebook.session.stop();await notebook.run();assert(value('out_bytes')==='[0, 255, 254, 128, 13, 10]','Worker restart lost mounted bytes');
  const validSource=notebook.state.cells.findIndex(cell=>cell.source.includes('out_text'));
  const textCell=notebook.state.cells[validSource].source;
  notebook.editCell(validSource,textCell.replace('data/values.csv','data/raw.bin'));
  result=await notebook.run();assert(result.status!=='ok','Invalid UTF-8 was silently accepted as Str');
  notebook.undo();await notebook.run();assert(value('out_text')===textValue(original),'Valid UTF-8 did not recover after a decoding diagnostic');
  reports.push('IndexedDB Blob persistence, bundle import through File menu, compiler restart');

  if(new URL(location.href).searchParams.has('parser-demo')) {
    const [{createWasmTransport},{BuildCache,compilerNamespace},{BrowserPackages}]=await Promise.all([import('/compiler-adapter/wasm.mjs'),import('/web/build-cache.mjs'),import('/web/packages.mjs')]);
    const bytes=await fetch('/artifacts/roclet.wasm').then(response=>response.arrayBuffer()),raw=await createWasmTransport(bytes);
    const ns=await compilerNamespace(bytes,raw.cacheIdentity());
    const packages=new BrowserPackages(new BuildCache(ns+':packages'),{fetch:url=>fetch('/artifacts/browser-packages/'+new URL(url).pathname.split('/').at(-1))});
    const packageSource=await fetch('/fixtures/documents/roc-parser-package.roc').then(response=>response.text());
    const primed=await packages.evaluate(raw,{operation:'document',action:'evaluate',format:'roc',source:packageSource});
    assert(primed.status==='ok',JSON.stringify(primed));
    await bench.load(bench.active,{example:'csv-attachments'});notebook.state.autoRun=false;
    result=await notebook.run();assert(result.status==='ok',JSON.stringify(result));
    assert(value('out_revenue').includes('15420'),'CSV demo did not calculate the expected revenue');
    assert(notebook.result.evaluation.values.find(value=>value.root==='out_rows').display.rows.some(row=>row[0]==='Tea, Earl Grey'),'Quoted CSV field was not decoded');
    await open();await select('data/cafe-sales.csv');
    choose('attachment-replacement',[new File(['item,units,unit_price_cents\n"Café, special",2,500\n'],'sales.csv',{type:'text/csv'})]);
    await until(()=>$('attachment-status').textContent.startsWith('Replaced'),'CSV demo replacement');close();
    await notebook.run();assert(value('out_revenue').includes('1000'),'Replaced CSV was not parsed by roc-parser');
    reports.push('real roc-parser release and Unicode dependency, typed CSV decoding, quoted Unicode fields, replacing CSV updates revenue');
  }
  await open();await select(notebook.state.attachments[0].path);
  const overflow=$('attachments-dialog').scrollWidth>$('attachments-dialog').clientWidth+1;
  assert(!overflow,'Attachments dialog overflows horizontally');
  return {result:'pass',buildMode:manifest.wasmOptimize,checks:reports,dialogOverflow:overflow};
})()
