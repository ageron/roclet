import {test} from 'node:test';
import assert from 'node:assert/strict';
import {LocalFiles} from '../web/local-files.mjs';
function handle(name='demo.roc',source='old') {
  return {name,source,writes:0,permission:'granted',async getFile(){const text=this.source;return {name:this.name,size:text.length,text:async()=>text};},async isSameEntry(other){return other===this;},async queryPermission(){return this.permission;},async requestPermission(){return this.permission;},async createWritable(){this.writes++;let text;return {write:async value=>{text=value;},close:async()=>{this.source=text;},abort:async()=>{}};}};
}
function notebook(){return {state:{id:'one',revision:1,format:'roc'},async open(source,name){this.state={id:name,revision:1,format:name.endsWith('.md')?'markdown':'roc'};},async inspect(){return {status:'ok',source:'new'};}};}
async function opened(){const files=new LocalFiles(),n=notebook(),h=handle();await files.open(n,h);return {files,n,h};}
test('open retains file identity, save writes exported source and tracks dirty state',async()=>{
 const {files,n,h}=await opened();n.state.revision++;assert.match(files.status(n.state),/Unsaved/);
 await files.save(n,()=>{throw Error('Unexpected picker');});assert.equal(h.source,'new');assert.match(files.status(n.state),/Saved to/);
 n.state={...n.state,id:'different'};assert.equal(files.status(n.state),'');
});
test('external edits are never overwritten, including changes during export',async()=>{
 const {files,n,h}=await opened();h.source='external';await assert.rejects(files.save(n),/outside Roclet/);assert.equal(h.writes,0);
 h.source='old';n.inspect=async()=>{h.source='external';return {status:'ok',source:'new'};};await assert.rejects(files.save(n),/while preparing/);assert.equal(h.writes,0);
});
test('cancelled picker and denied permission preserve original files and bindings',async()=>{
 const {files,n,h}=await opened();await assert.rejects(files.save(n,async()=>{throw new DOMException('Cancelled','AbortError');},{as:true}),{name:'AbortError'});
 assert.equal(files.get(n.state).handle,h);h.permission='denied';await assert.rejects(files.save(n),/permission/);assert.equal(h.writes,0);assert.equal(files.saving,false);
});
test('Save as and format switches choose a new file without modifying the original',async()=>{
 const {files,n,h}=await opened(),copy=handle('copy.roc','');await files.save(n,async()=>copy,{as:true});assert.equal(h.source,'old');assert.equal(copy.source,'new');
 n.state.format='markdown';n.state.revision++;const md=handle('copy.md','');await files.save(n,async()=>md);assert.equal(files.get(n.state).handle,md);
});
test('edits and document switches during export cannot write stale content',async()=>{
 for(const change of [n=>n.state.revision++,n=>n.state.id='other']){
 const {files,n,h}=await opened();n.inspect=async()=>{change(n);return {status:'ok',source:'new'};};await assert.rejects(files.save(n),/notebook changed/);assert.equal(h.writes,0);
 }
});
test('invalid Roc export and wrong extensions do not write',async()=>{
 const {files,n,h}=await opened();n.inspect=async()=>({status:'error',source:'invalid'});await assert.rejects(files.save(n),/Fix the errors/);assert.equal(h.writes,0);
 await assert.rejects(files.save(n,async()=>handle('wrong.md'),{as:true}),/filename/);
});
test('concurrent saves are refused and a failed write aborts its stream',async()=>{
 const {files,n,h}=await opened();let release,aborted=false;n.inspect=()=>new Promise(resolve=>{release=resolve;});
 const saving=files.save(n);while(!release)await new Promise(resolve=>setTimeout(resolve,0));await assert.rejects(files.save(n),/already in progress/);
 h.createWritable=async()=>({write:async()=>{throw Error('Disk full');},abort:async()=>{aborted=true;}});release({status:'ok',source:'new'});await assert.rejects(saving,/Disk full/);assert(aborted);assert.equal(files.get(n.state).source,'old');
});
