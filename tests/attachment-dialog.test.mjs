import {test} from 'node:test';
import assert from 'node:assert/strict';
import {AttachmentDialog} from '../web/attachment-dialog.mjs';
import {Notebook,newDraft} from '../web/edit-model.mjs';

const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
function fixture() {
  const nodes=new Map();
  class Dialog extends EventTarget {
    open=false;
    showModal(){this.open=true;}
    close(){this.open=false;this.dispatchEvent(new Event('close'));}
  }
  const dialog=new Dialog();nodes.set('attachments-dialog',dialog);
  const doc={getElementById:id=>{if(!nodes.has(id))nodes.set(id,{dataset:{},setAttribute(){}});return nodes.get(id);}};
  const controller=new AttachmentDialog(doc);controller.render=async()=>{};
  const notebook=title=>{
    const n=new Notebook(null,{save:async()=>{}},{session:{stop(){},invalidate(){}},deferScheduling:true});
    n.state=newDraft(title);n.state.autoRun=false;return n;
  };
  return {controller,dialog,nodes,left:notebook('Left'),right:notebook('Right')};
}
test('closing a pending attachment import releases the dialog and cannot affect a reopened notebook',async()=>{
  const {controller,dialog,nodes,left,right}=fixture(),oldRead=deferred(),newRead=deferred();
  const oldFile=new File(['old'],'old.bin'),newFile=new File(['new'],'new.bin');
  oldFile.arrayBuffer=()=>oldRead.promise;newFile.arrayBuffer=()=>newRead.promise;
  try {
    await controller.open({notebook:left,title:'Left'});
    const oldWork=controller.importFiles([oldFile]);
    assert.equal(nodes.get('attachment-controls').inert,true);
    dialog.close();await controller.open({notebook:right,title:'Right'});
    assert.equal(nodes.get('attachment-controls').inert,false,'A cancelled disk read must not lock the next notebook');
    const newWork=controller.importFiles([newFile]);
    oldRead.reject(Error('Old disk read failed'));await oldWork;
    assert.equal(nodes.get('attachment-controls').inert,true,'An old completion must not unlock an active new import');
    assert.doesNotMatch(nodes.get('attachment-status').textContent,/Old disk read failed/);
    newRead.resolve(new TextEncoder().encode('new').buffer);await newWork;
    assert.equal(left.state.attachments.length,0);
    assert.equal(right.state.attachments.length,1);
    assert.equal(await right.state.attachments[0].blob.text(),'new');
    assert.equal(nodes.get('attachment-controls').inert,false);
  } finally {left.dispose();right.dispose();}
});
test('a stale successful read and queued close event cannot cancel a new import',async()=>{
  const {controller,dialog,left}=fixture(),oldRead=deferred();
  const oldFile=new File(['old'],'old.bin');oldFile.arrayBuffer=()=>oldRead.promise;
  try {
    await controller.open({notebook:left,title:'Left'});
    const oldWork=controller.importFiles([oldFile]);
    dialog.close();await controller.open({notebook:left,title:'Left'});
    dialog.dispatchEvent(new Event('close'));
    await controller.importFiles([new File(['new'],'new.bin')]);
    oldRead.resolve(new TextEncoder().encode('old').buffer);await oldWork;
    assert.deepEqual(left.state.attachments.map(file=>file.path),['data/new.bin']);
  } finally {left.dispose();}
});
test('dropping another file during a pending read cannot navigate away or silently replace data',async()=>{
  const {controller,dialog,nodes,left}=fixture(),read=deferred();
  const slow=new File(['slow'],'slow.bin');slow.arrayBuffer=()=>read.promise;
  try {
    await controller.open({notebook:left,title:'Left'});
    const work=controller.importFiles([slow]),drop=new Event('drop',{cancelable:true});
    drop.dataTransfer={files:[new File(['other'],'other.bin')]};dialog.dispatchEvent(drop);
    assert.equal(drop.defaultPrevented,true);
    assert.match(nodes.get('attachment-status').textContent,/Wait for the current file operation/);
    read.resolve(new TextEncoder().encode('slow').buffer);await work;
    assert.deepEqual(left.state.attachments.map(file=>file.path),['data/slow.bin']);
  } finally {left.dispose();}
});
