import {test} from 'node:test';
import assert from 'node:assert/strict';
import {attachment,attachments,attachmentPreview,attachmentLimit,trimAttachmentHistory} from '../web/attachments.mjs';
import {Notebook,newDraft,requestFor,validDraft,independentCopy} from '../web/edit-model.mjs';
import {fileChanges,mountChanges} from '../web/workspace.mjs';
import {bundleFiles,importBundle} from '../web/sharing.mjs';
import {zip,utf8,text} from '../web/archive.mjs';

const csv=()=>attachment('data/measurements.csv',new Blob(['name,value\r\n"café, north",42\r\n'],{type:'text/csv'}));
const binary=()=>attachment('data/sample.bin',new Blob([new Uint8Array([0,255,254,128,13,10])]));
const notebook=()=>{
  const model=new Notebook(null,{save:async()=>{}},{session:{invalidate(){},stop(){}},deferScheduling:true});
  model.state=newDraft();model.state.autoRun=false;return model;
};
test('attachments preserve exact UTF-8 and binary bytes and validate portable paths, collisions and limits',async()=>{
  const a=await csv(),b=await binary();
  assert.equal(await a.blob.text(),'name,value\r\n"café, north",42\r\n');
  assert.deepEqual([...new Uint8Array(await b.blob.arrayBuffer())],[0,255,254,128,13,10]);
  assert.equal((await attachmentPreview(a)).kind,'text');assert.equal((await attachmentPreview(b)).kind,'bytes');
  assert.equal((await attachmentPreview(await attachment('empty',new Blob()))).text,'');
  for(const path of ['../escape','/absolute','nested/../bad','bad\\name','data//x','Main.roc','main.roc','data/a"b','data/${x}']) assert.throws(()=>attachments([{...a,path}]));
  assert.throws(()=>attachments([a,a]),/already used/);
  assert.throws(()=>attachments([a],[{path:a.path,source:'module []'}]),/already used/);
  assert.throws(()=>attachments([a],[{path:'data',source:'file, not a directory'}]),/overlaps/);
  assert.throws(()=>attachments([{...a,blob:new Blob([new Uint8Array(attachmentLimit+1)])}]),/16 MiB/);
  assert.throws(()=>attachments([{...a,sha256:'bad'}]),/Malformed/);
  assert.equal(validDraft({...newDraft(),attachments:[{...a,path:'../bad'}]}),false);
});
test('replacement, removal, rename and undo keep source, snapshots and independent copies consistent',async()=>{
  const model=notebook(),a=await csv();
  model.state.sourceCurrent=true;model.state.source='import "data/measurements.csv" as csv : Str';
  model.setAttachments([a]);
  const replacement=await attachment(a.path,new Blob(['new bytes']));model.setAttachments([replacement]);
  assert.equal(model.state.sourceCurrent,true);
  assert.equal(await model.state.attachments[0].blob.text(),'new bytes');
  model.undo();assert.equal(model.state.attachments[0].sha256,a.sha256);
  model.removeAttachment(a.path);assert.deepEqual(model.state.attachments,[]);
  model.undo();assert.equal(await model.state.attachments[0].blob.text(),await a.blob.text());
  model.setAttachments([{...a,path:'data/renamed.csv'}]);assert.equal(model.state.attachments[0].path,'data/renamed.csv');
  assert.throws(()=>model.setProjectFile('data/renamed.csv','colliding source'),/already used/);
  assert.equal(requestFor(model.state,'evaluate').files[0].path,'/workspace/data/renamed.csv');
  const copy=independentCopy(model.state);assert.notEqual(copy.id,model.state.id);
  assert.equal(await copy.attachments[0].blob.text(),await a.blob.text());
  model.dispose();
});
test('a source-only download cannot stand in for unsaved attachment data',async()=>{
  const model=notebook();model.store={save:async()=>{throw Error('Storage full');}};
  model.setAttachments([await binary()]);
  model.markDownloaded();assert.equal(model.downloadedCurrent,false);
  assert.equal(await model.keep(),false);
  model.markDownloaded({complete:true});assert.equal(await model.keep(),true);
  model.dispose();
});
test('attachment undo retains recent replacements within a byte budget and shares repeated contents',async()=>{
  const a=await attachment('data/file',new Blob(['aaaaaaaa'])),b=await attachment('data/file',new Blob(['bbbbbbbb'])),c=await attachment('data/file',new Blob(['cccccccc']));
  const model=notebook();model.setAttachments([a]);const original=model.state.attachments[0].blob;
  model.setAttachments([await attachment(a.path,new Blob(['aaaaaaaa']))]);
  assert.equal(model.state.attachments[0].blob,original,'Importing identical data must reuse its immutable backing');
  model.setAttachments([b]);model.undo();
  assert.equal(await model.state.attachments[0].blob.text(),'aaaaaaaa');
  model.setAttachments([await attachment(b.path,new Blob(['bbbbbbbb'],{type:'text/plain'}))]);
  assert.equal(model.state.attachments[0].blob.type,'text/plain');
  assert.equal(await model.state.attachments[0].blob.text(),'bbbbbbbb');
  const history=[{attachments:[a]},{attachments:[b]}];
  trimAttachmentHistory(history,{attachments:[c]},20);
  assert.equal(history.length,1);assert.equal(await history[0].attachments[0].blob.text(),'bbbbbbbb');
  const repeated=[{attachments:[a]},{attachments:[a]}];
  trimAttachmentHistory(repeated,{attachments:[b]},20);
  assert.equal(repeated.length,2,'Editing prose must not charge the same attachment again');
  model.dispose();
});
test('unchanged attachment content is not retransmitted; replacement and removal update the workspace',async()=>{
  const a=await csv(),path=`/workspace/${a.path}`;
  const first=fileChanges(new Map(),[{...a,path}]);assert.equal(first.patch.put.length,1);
  assert.deepEqual(fileChanges(first.next,[{...structuredClone(a),path}]).patch,{put:[],drop:[]});
  const b=await attachment(a.path,new Blob(['different']));
  const next=fileChanges(first.next,[{...b,path}]);assert.equal(next.patch.put.length,1);
  const mounted=[];mountChanges({workspace:true,putFile:(path,bytes)=>mounted.push({path,bytes})},{put:[{path,bytes:new Uint8Array(await b.blob.arrayBuffer())}],drop:[]});
  assert.equal(new TextDecoder().decode(mounted[0].bytes),'different');
  assert.deepEqual(fileChanges(next.next,[]).patch.drop,[path]);
});
test('portable bundles round-trip raw bytes, paths, media types and hashes without putting data in source JSON',async()=>{
  const data=[await csv(),await binary()];
  const compiler={compilerCommit:'test',artifacts:{'roclet.wasm':{sha256:'wasm'}}};
  const document={...newDraft('Attachments'),attachments:data,files:[{path:'Helpers.roc',source:'module []'}]};
  const capture={document,source:'app [main!] {}',snapshots:[],events:[],compiler:{commit:'test',wasmSha256:'wasm'},createdAt:'test'};
  const files=await bundleFiles(capture);
  const metadata=JSON.parse(text(files.get('document.json')));
  assert.deepEqual(metadata.attachments.map(file=>file.path),data.map(file=>file.path));
  assert(!text(files.get('document.json')).includes('café'));
  assert(!('blob' in metadata.attachments[0]));
  const {record}=await importBundle(await zip(files).arrayBuffer(),compiler);
  assert.equal(record.autoRun,false);
  for(let i=0;i<data.length;i++) {
    assert.equal(record.attachments[i].path,data[i].path);
    assert.equal(record.attachments[i].blob.type,data[i].blob.type);
    assert.equal(record.attachments[i].sha256,data[i].sha256);
    assert.deepEqual(await record.attachments[i].blob.arrayBuffer(),await data[i].blob.arrayBuffer());
  }
  files.set('attachments/data/sample.bin',utf8('corrupt'));
  await assert.rejects(importBundle(await zip(files).arrayBuffer(),compiler),/integrity/);
});
test('bundle import rejects duplicate paths and unlisted, missing or overlapping attachment members',async()=>{
  const compiler={compilerCommit:'test',artifacts:{'roclet.wasm':{sha256:'wasm'}}};
  const capture={document:{...newDraft(),attachments:[await csv()]},source:'app [main!] {}',snapshots:[],events:[],compiler:{commit:'test',wasmSha256:'wasm'},createdAt:'test'};
  const {sha256}=await import('../web/offline-cache.mjs');
  // Re-sign the outer manifest so these cases exercise attachment validation,
  // not just the ordinary member-integrity check.
  const changed=async mutate=>{
    const files=await bundleFiles(capture),doc=JSON.parse(text(files.get('document.json')));
    mutate(doc,files);files.set('document.json',utf8(JSON.stringify(doc)));
    const manifest=JSON.parse(text(files.get('roclet.json')));
    manifest.files=await Promise.all([...files].filter(([path])=>path!=='roclet.json').map(async([path,bytes])=>({path,bytes:bytes.length,sha256:await sha256(bytes)})));
    files.set('roclet.json',utf8(JSON.stringify(manifest)));return zip(files).arrayBuffer();
  };
  await assert.rejects(importBundle(await changed(doc=>doc.attachments.push(doc.attachments[0])),compiler),/already used/);
  await assert.rejects(importBundle(await changed(doc=>doc.attachments=[]),compiler),/Unexpected attachments/);
  await assert.rejects(importBundle(await changed((doc,files)=>files.delete('attachments/data/measurements.csv')),compiler),/missing/);
  await assert.rejects(importBundle(await changed(doc=>doc.attachments[0].sha256='0'.repeat(64)),compiler),/integrity/);
});
test('malformed bundle attachment metadata is rejected before allocating file copies',async()=>{
  const {sha256}=await import('../web/offline-cache.mjs');
  const compiler={compilerCommit:'test',artifacts:{'roclet.wasm':{sha256:'wasm'}}};
  const capture={document:{...newDraft(),attachments:[await csv()]},source:'app [main!] {}',snapshots:[],events:[],compiler:{commit:'test',wasmSha256:'wasm'},createdAt:'test'};
  const files=await bundleFiles(capture),doc=JSON.parse(text(files.get('document.json')));
  doc.attachments=Array.from({length:128},()=>doc.attachments[0]);
  files.set('document.json',utf8(JSON.stringify(doc)));
  const manifest=JSON.parse(text(files.get('roclet.json'))),entry=manifest.files.find(file=>file.path==='document.json');
  Object.assign(entry,{bytes:files.get('document.json').length,sha256:await sha256(files.get('document.json'))});
  files.set('roclet.json',utf8(JSON.stringify(manifest)));
  const bytes=await zip(files).arrayBuffer(),NativeBlob=globalThis.Blob;
  let copies=0;
  globalThis.Blob=class extends NativeBlob {constructor(...args){super(...args);copies++;}};
  try {
    await assert.rejects(importBundle(bytes,compiler),/already used/);
    assert.equal(copies,0,'Repeated manifest entries must not multiply the file allocation');
  } finally {globalThis.Blob=NativeBlob;}
});
