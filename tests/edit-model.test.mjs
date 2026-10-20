import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Notebook,newDraft,requestFor,validDraft} from '../web/edit-model.mjs';
import {projectFiles} from '../web/project-files.mjs';
import {bundleFiles,importBundle} from '../web/sharing.mjs';
import {zip,utf8,text} from '../web/archive.mjs';
import {sha256} from '../web/offline-cache.mjs';
import {DocumentDraft,DocumentSession} from '../web/document-session.mjs';

test('project modules preserve raw source editing and undo as one notebook change',()=>{
  const session={invalidate(){},stop(){}};
  const notebook=new Notebook(null,{save:async()=>{}},{session,debounce:60000});
  notebook.state=newDraft();notebook.state.autoRun=false;notebook.state.sourceCurrent=true;notebook.state.source='out_1 = Geometry.area';
  notebook.result={status:'ok'};
  notebook.setProjectFile('Geometry.roc','module [area]\narea = 15');
  assert.equal(notebook.result,null);
  assert.equal(notebook.state.sourceCurrent,true);
  assert.equal(requestFor(notebook.state,'evaluate').source,'out_1 = Geometry.area');
  assert.deepEqual(requestFor(notebook.state,'evaluate').files,[{path:'/workspace/Geometry.roc',source:'module [area]\narea = 15'}]);
  notebook.setProjectFile('Geometry.roc','module [area]\narea = 24');
  notebook.undo();assert.equal(notebook.state.files[0].source,'module [area]\narea = 15');
  notebook.removeProjectFile('Geometry.roc');assert.deepEqual(notebook.state.files,[]);
  assert.equal(validDraft({...notebook.state,files:[{path:'../outside.roc',source:''}]}),false);
  notebook.dispose();
});

test('project paths cannot replace the notebook or escape a portable project',()=>{
  for(const path of ['Main.roc','main.roc','../secret.roc','/absolute.roc','nested/../secret.roc','nested//File.roc','C:File.roc','bad\\File.roc']) {
    assert.throws(()=>projectFiles([{path,source:'module []'}]));
  }
  assert.throws(()=>projectFiles([{path:'File.roc',source:''},{path:'File.roc',source:''}]));
  assert.deepEqual(projectFiles([{path:'Shapes/Wall.roc',source:'module [area]\narea = 15'}]),[{path:'Shapes/Wall.roc',source:'module [area]\narea = 15'}]);
});

test('portable bundles retain project sources once and reject modified members',async()=>{
  const display=utf8('module []'),displayHash=await sha256(display),originalFetch=globalThis.fetch;
  globalThis.fetch=async()=>new Response(display);
  try {
    const compiler={compilerCommit:'test-compiler',artifacts:{'roclet.wasm':{sha256:'test-wasm'}},inputs:{'package/Display.roc':displayHash}};
    const capture={document:{schema:1,title:'Project',format:'roc',preamble:'app [main!] {}',metadata:'',source:'',sourceCurrent:false,mode:'notebook',cells:[{kind:'code',source:'Geometry.area',attributes:'',outputs:[]}],files:[{path:'Geometry.roc',source:'module [area]\narea = 15'}]},source:'Geometry.area',snapshots:[],events:[],compiler:{commit:'test-compiler',wasmSha256:'test-wasm',displaySha256:displayHash},createdAt:'test'};
    const files=await bundleFiles(capture);
    assert.equal(text(files.get('project/Geometry.roc')),'module [area]\narea = 15');
    assert.deepEqual(JSON.parse(text(files.get('document.json'))).files,[{path:'Geometry.roc'}]);
    const imported=await importBundle(await zip(files).arrayBuffer(),compiler);
    assert.deepEqual(imported.record.files,capture.document.files);
    assert.equal(imported.record.autoRun,false);
    files.set('project/Geometry.roc',utf8('module [area]\narea = 24'));
    await assert.rejects(importBundle(await zip(files).arrayBuffer(),compiler),/integrity/i);
  } finally {globalThis.fetch=originalFetch;}
});

test('format switching restores exact draft bytes and invalidates the alternate view after edits',()=>{
  const original='app [main!] {}\r\n\r\n#%%\r\n  1 + 1\r\n';
  const draft=new DocumentDraft(original);
  draft.converted('markdown',{status:'ok',source:'```roc\n1 + 1\n```\n',model:{preamble:'app [main!] {}\r\n',metadata:''}});
  assert.equal(draft.restore('roc'),true);
  assert.equal(draft.source,original);
  draft.restore('markdown');
  draft.edit('```roc\n2 + 2\n```\n');
  assert.equal(draft.restore('roc'),false);
  assert.equal(draft.request('run').context.preamble,'app [main!] {}\r\n');
  draft.open('# New doc','markdown');
  assert.equal(draft.request('run').context,undefined);
  assert.equal(draft.restore('roc'),false);
});

test('an invalid conversion never replaces an editable draft',()=>{
  const draft=new DocumentDraft('# %%\nx = {');
  assert.equal(draft.converted('markdown',{status:'diagnostic',source:'different'}),false);
  assert.equal(draft.source,'# %%\nx = {');
  assert.equal(draft.format,'roc');
});

test('document worker survives completed requests but cancellation rejects late results',async()=>{
  const workers=[];
  class FakeWorker {
    sent=[];
    terminated=false;
    constructor(){workers.push(this);}
    postMessage(value){this.sent.push(value);}
    terminate(){this.terminated=true;}
  }
  const session=new DocumentSession(new ArrayBuffer(1),FakeWorker);
  const first=session.request({source:'old'});
  workers[0].onmessage({data:{result:{value:1}}});
  assert.equal((await first).value,1);
  session.invalidate();
  const second=session.request({source:'new'});
  assert.equal(workers.length,1);
  assert.equal(workers[0].sent[1].bytes,undefined);
  const late=workers[0].onmessage;
  const rejected=assert.rejects(second,{name:'AbortError'});
  session.stop();
  await rejected;
  const third=session.request({source:'latest'});
  assert.equal(workers.length,2);
  late({data:{result:{value:2}}});
  workers[1].onmessage({data:{result:{value:3}}});
  assert.equal((await third).value,3);
  session.stop();
});

// A fresh browser worker receives its message only after the compiler module
// is compiled and hashed, so the session must own the request before that await.
test('a fresh worker posts the request as submitted even if the caller mutates it',async()=>{
  const posted=[];
  class FakeWorker {
    postMessage(value){posted.push(structuredClone(value));}
    terminate(){}
  }
  const originalWorker=globalThis.Worker;
  globalThis.Worker=FakeWorker;
  try {
    // The smallest valid WebAssembly module: magic number and version.
    const session=new DocumentSession(new Uint8Array([0,97,115,109,1,0,0,0]).buffer,FakeWorker);
    const request={operation:'document',action:'evaluate',format:'roc',source:'out_1 = 1',draft:{cells:[{kind:'code',source:'out_1 = 1'}]},files:[{path:'/workspace/Geometry.roc',source:'module [area]\narea = 15'}]};
    const result=session.request(request);
    request.source='out_1 = 999';
    request.draft.cells[0].source='out_1 = 999';
    request.files[0].source='module [area]\narea = 999';
    request.extra=true;
    while(!posted.length) await new Promise(resolve=>setTimeout(resolve,1));
    assert.equal(posted.length,1);
    assert.equal(posted[0].bytes,undefined);
    assert.ok(posted[0].module instanceof WebAssembly.Module);
    assert.deepEqual(posted[0].request,{operation:'document',action:'evaluate',format:'roc',source:'out_1 = 1',draft:{cells:[{kind:'code',source:'out_1 = 1'}]}});
    assert.deepEqual(posted[0].workspace.put,[{path:'/workspace/Geometry.roc',source:'module [area]\narea = 15'}]);
    session.stop();
    await assert.rejects(result,{name:'AbortError'});
  } finally {globalThis.Worker=originalWorker;}
});
