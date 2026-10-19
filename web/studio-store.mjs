// Transactional browser recovery with optimistic concurrency: a stale tab cannot
// overwrite a draft saved by another tab. Export/fork preserves its local edits.
export class DraftStore {
  constructor(name = 'roclet-studio-v1') { this.name = name; this.versions=new Map(); }
  async open() {
    if (!this.db) this.db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(this.name, 1);
      request.onupgradeneeded = () => request.result.createObjectStore('drafts', { keyPath: 'id' });
      request.onsuccess = () => {request.result.onversionchange=()=>{request.result.close();this.db=null;};resolve(request.result);};
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error('Close another Roclet tab to finish opening storage.'));
    });
    return this.db;
  }
  async transact(mode, operation) {
    const db = await this.open();
    return new Promise((resolve, reject) => {
      const transaction = db.transaction('drafts', mode);
      const request = operation(transaction.objectStore('drafts'));
      transaction.oncomplete = () => resolve(request.result);
      transaction.onerror = () => reject(transaction.error ?? request.error);
      transaction.onabort = () => reject(transaction.error ?? new Error('Draft save was interrupted.'));
    });
  }
  async save(record) {
    const db=await this.open(),version=crypto.randomUUID();
    await new Promise((resolve,reject)=>{
      const tx=db.transaction('drafts','readwrite'),store=tx.objectStore('drafts'),read=store.get(record.id);let conflict;
      read.onsuccess=()=>{
        const existing=read.result,expected=this.versions.get(record.id);
        if(existing && (!this.versions.has(record.id) || (existing._storageVersion??null)!==expected)) {
          conflict=new Error('Another tab changed this draft. Download your edits or save a recovery copy before reopening it.');tx.abort();return;
        }
        store.put({...record,_storageVersion:version});
      };
      tx.oncomplete=()=>{this.versions.set(record.id,version);resolve();};
      tx.onerror=()=>reject(tx.error??read.error);
      tx.onabort=()=>reject(conflict??tx.error??new Error('Draft save was interrupted.'));
    });
  }
  async get(id) {const record=await this.transact('readonly',store=>store.get(id));if(record) this.versions.set(id,record._storageVersion??null);return record;}
  async list() {
    const records = await this.transact('readonly', store => store.getAll());
    for(const record of records) if(!this.versions.has(record.id)) this.versions.set(record.id,record._storageVersion??null);
    return records.sort((a, b) => b.updatedAt - a.updatedAt);
  }
  close() { this.db?.close(); this.db = null; }
}
