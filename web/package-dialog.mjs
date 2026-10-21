const cancelled=()=>new DOMException('Package loading cancelled','AbortError');
// Browser permission to read a user-selected file is independent of host CORS.
// The page has one package dialog; PackagePrompts decides what it shows.
function openDialog({url,error,retry,requesters=[],signal}) {
  return new Promise((resolve,reject)=>{
    const $=id=>document.getElementById(id),dialog=$('package-dialog'),input=$('package-file');
    const address=new URL(url);
    if(!['https:','http:'].includes(address.protocol)) {reject(new Error('Unsupported package download URL'));return;}
    if(signal.aborted) {reject(cancelled());return;}
    const cleanup=()=>{
      input.removeEventListener('change',selected);dialog.removeEventListener('close',closed);signal.removeEventListener('abort',aborted);
      $('package-load').onclick=null;input.value='';dialog.close();
    };
    const closed=()=>{if(!dialog.open){cleanup();reject(cancelled());}};
    const aborted=()=>{cleanup();reject(cancelled());};
    const selected=async()=>{
      const file=input.files[0];input.value='';if(!file)return;
      if(file.size>32*1024*1024) {$('package-status').textContent='Choose a bundle smaller than 32 MiB.';return;}
      $('package-load').disabled=true;$('package-status').textContent='Reading bundle…';
      try {
        const bytes=new Uint8Array(await file.arrayBuffer());
        if(signal.aborted || !dialog.open)return;
        cleanup();resolve(bytes);
      } catch(error) {
        if(!signal.aborted && dialog.open) {$('package-status').textContent=error.message;$('package-load').disabled=false;}
      }
    };
    $('package-download').href=address.href;$('package-url').textContent=address.href;showRequesters(requesters);
    $('package-error').textContent=error;$('package-status').textContent=retry?error:'';
    $('package-load').disabled=false;$('package-load').onclick=()=>input.click();
    input.addEventListener('change',selected);dialog.addEventListener('close',closed);signal.addEventListener('abort',aborted,{once:true});
    dialog.showModal();
  });
}
function showRequesters(requesters) {
  const node=document.getElementById('package-needed');
  node.textContent=requesters.length?`Needed by: ${requesters.join(', ')}`:'';node.hidden=!requesters.length;
}
export const packageDialog={open:openDialog,update:showRequesters};

// One page-level coordinator for package prompts from every notebook worker.
// Requests for the same URL join the open (or queued) prompt and one file
// selection serves them all, each with its own copy because the bytes are
// transferred to that worker. Different URLs wait their turn. A requester whose
// signal aborts leaves; the prompt closes when nobody is left. Cancel in the
// dialog is one decision and rejects every requester. A retry after rejected
// bytes is a new prompt for that requester only.
export class PackagePrompts {
  constructor(driver=packageDialog) {this.driver=driver;this.queue=[];this.current=null;}
  request({url,error,retry=false,signal,requester=''}) {
    return new Promise((resolve,reject)=>{
      if(signal?.aborted) {reject(cancelled());return;}
      let group=retry?null:[this.current,...this.queue].find(g=>g && !g.retry && !g.settled && g.url===url);
      if(!group) {group={url,error,retry,joiners:new Set(),controller:new AbortController(),settled:false};this.queue.push(group);}
      const joiner={resolve,reject,signal,requester};
      joiner.abort=()=>this.leave(group,joiner);
      signal?.addEventListener('abort',joiner.abort,{once:true});
      group.joiners.add(joiner);
      if(group===this.current) this.driver.update?.(this.requesters(group));
      this.next();
    });
  }
  requesters(group) {return [...group.joiners].map(joiner=>joiner.requester).filter(Boolean);}
  leave(group,joiner) {
    if(group.settled || !group.joiners.delete(joiner)) return;
    joiner.reject(cancelled());
    if(group.joiners.size) {if(group===this.current) this.driver.update?.(this.requesters(group));return;}
    if(group===this.current) group.controller.abort();
    else this.queue=this.queue.filter(g=>g!==group);
  }
  settle(group,outcome) {
    group.settled=true;
    for(const joiner of group.joiners) {joiner.signal?.removeEventListener('abort',joiner.abort);outcome(joiner);}
    group.joiners.clear();
    if(this.current===group) this.current=null;
    this.next();
  }
  next() {
    if(this.current || !this.queue.length) return;
    const group=this.current=this.queue.shift();
    Promise.resolve().then(()=>this.driver.open({url:group.url,error:group.error,retry:group.retry,requesters:this.requesters(group),signal:group.controller.signal}))
      .then(bytes=>this.settle(group,joiner=>joiner.resolve(bytes.slice())),failure=>this.settle(group,joiner=>joiner.reject(failure)));
  }
}
