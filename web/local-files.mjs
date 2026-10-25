// File handles stay in this page session; browser drafts remain recovery copies.
export class LocalFiles {
  bindings = new Map();
  saving = false;
  get(state) { return this.bindings.get(state.id); }
  status(state) {
    const file=this.get(state);
    if (!file) return '';
    return `${file.revision===state.revision ? 'Saved to' : 'Unsaved changes to'} ${file.handle.name}`;
  }
  async open(notebook,handle) {
    const file=await handle.getFile();
    if(file.size>256*1024)throw new Error('Roclet notebooks are limited to 256 KiB.');
    const source=await file.text();
    await notebook.open(source,file.name);
    this.bindings.set(notebook.state.id,{handle,source,revision:notebook.state.revision,format:notebook.state.format});
  }
  async save(notebook,pick,{as=false}={}) {
    if(this.saving)throw new Error('A file save is already in progress.');
    this.saving=true;
    const {id,revision,format}=notebook.state;
    const current=this.get(notebook.state);
    const unchanged=()=>{if(notebook.state.id!==id || notebook.state.revision!==revision)throw new Error('The notebook changed during saving. Save again to write the latest version.');};
    let writable;
    try {
      // Invoke the picker before any asynchronous compilation loses user activation.
      const handle=(!as && current && current.format===format) ? current.handle : await pick();
      unchanged();
      const extension=format==='roc'?'.roc':'.md';
      if(!handle.name.toLowerCase().endsWith(extension))throw new Error(`Choose a ${extension} filename for this notebook format.`);
      const before=await handle.getFile(),disk=await before.text();
      const same=current && await handle.isSameEntry(current.handle);
      if(same && disk!==current.source)throw new Error('This file changed outside Roclet. Open it again to load those changes, or use Save as to keep your version in a different file.');
      if(handle.queryPermission && await handle.queryPermission({mode:'readwrite'})!=='granted') {
        if(await handle.requestPermission({mode:'readwrite'})!=='granted')throw new Error('File write permission was not granted. Your browser draft is still available.');
      }
      const result=await notebook.inspect('export');
      unchanged();
      if(format==='roc' && result.status!=='ok')throw new Error('Fix the errors before saving runnable Roc, or switch to Markdown to save unfinished source.');
      if(await (await handle.getFile()).text()!==disk)throw new Error('The file changed while preparing the save. No changes were written; try Save as.');
      unchanged();
      writable=await handle.createWritable();
      unchanged();
      await writable.write(result.source);
      await writable.close();writable=null;
      this.bindings.set(id,{handle,source:result.source,revision,format});
      // A completed disk write is also a recovery copy if browser storage fails.
      if(notebook.state.id===id && notebook.state.revision===revision)notebook.markDownloaded?.();
      return handle.name;
    } finally {
      if(writable)await writable.abort().catch(()=>{});
      this.saving=false;
    }
  }
}
export const localFiles=new LocalFiles();
