// Browser permission to read a user-selected file is independent of host CORS.
export function loadPackageBundle({url,error,retry,signal}) {
  return new Promise((resolve,reject)=>{
    const $=id=>document.getElementById(id),dialog=$('package-dialog'),input=$('package-file');
    const address=new URL(url);
    if(!['https:','http:'].includes(address.protocol)) {reject(new Error('Unsupported package download URL'));return;}
    const cancelled=()=>new DOMException('Package loading cancelled','AbortError');
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
    $('package-download').href=address.href;$('package-url').textContent=address.href;
    $('package-error').textContent=error;$('package-status').textContent=retry?error:'';
    $('package-load').disabled=false;$('package-load').onclick=()=>input.click();
    input.addEventListener('change',selected);dialog.addEventListener('close',closed);signal.addEventListener('abort',aborted,{once:true});
    dialog.showModal();
  });
}
