// Compiler artifacts, never evaluated notebook values. The WASM digest and the
// compiler's cache identity isolate target/ABI/compiler versions.
const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', {fatal:true});
const LIMIT = 32 * 1024 * 1024, MAX_ENTRIES = 512;
const warm = new Map();
// Keep verified source archives when disposable compiler artifacts churn.
// Each family has its own bounded budget across compiler versions/namespaces.
const family = namespace => namespace.endsWith(':packages') ? 'packages' : 'compiler';
const bytesOf = value => value instanceof Uint8Array ? value : new Uint8Array(value);
const checksum = async bytes => [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
const validPath = path => typeof path === 'string' && path.startsWith('/cache/') && !path.split('/').includes('..');
export function decodeCacheStream(input) {
  const bytes=bytesOf(input), entries=[];let total=0;
  if(bytes.length<4 || decoder.decode(bytes.subarray(0,4))!=='RLC1') throw new Error('Invalid compiler cache format');
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  for(let offset=4;offset<bytes.length;) {
    if(offset+8>bytes.length) throw new Error('Truncated compiler cache');
    const pathLength=view.getUint32(offset,true),size=view.getUint32(offset+4,true);offset+=8;
    if(!pathLength || pathLength>4096 || size>LIMIT || offset+pathLength+size>bytes.length) throw new Error('Invalid compiler cache entry');
    const path=decoder.decode(bytes.subarray(offset,offset+pathLength));offset+=pathLength;
    if(!validPath(path)) throw new Error('Invalid compiler cache path');
    entries.push({path,bytes:bytes.slice(offset,offset+size)});offset+=size;
    total+=size;
    if(entries.length>MAX_ENTRIES || total>LIMIT) throw new Error('Compiler cache exceeds storage limit');
  }
  return entries;
}
export function encodeCacheStream(entries) {
  const parts=entries.map(({path,bytes})=>({path:encoder.encode(path),bytes:bytesOf(bytes)}));
  const output=new Uint8Array(4+parts.reduce((n,p)=>n+8+p.path.length+p.bytes.length,0));output.set(encoder.encode('RLC1'));
  const view=new DataView(output.buffer);let offset=4;
  for(const part of parts) {view.setUint32(offset,part.path.length,true);view.setUint32(offset+4,part.bytes.length,true);offset+=8;output.set(part.path,offset);offset+=part.path.length;output.set(part.bytes,offset);offset+=part.bytes.length;}
  return output;
}
export async function compilerNamespace(bytes,identity,digest) {
  return `compiler-v1:${digest??await checksum(bytes)}:${identity}`;
}
function openDatabase(indexedDB) {
  if(!indexedDB) return Promise.resolve(null);
  return new Promise(resolve=>{
    const request=indexedDB.open('roclet-build-cache',2);
    request.onupgradeneeded=()=>{
      const database=request.result,store=database.objectStoreNames.contains('entries')?request.transaction.objectStore('entries'):database.createObjectStore('entries',{keyPath:'key'});
      if(!store.indexNames.contains('namespace')) store.createIndex('namespace','namespace');
      if(!store.indexNames.contains('recency')) store.createIndex('recency',['touched','size']);
      const cursor=store.openCursor();cursor.onsuccess=()=>{const entry=cursor.result;if(entry){const record=entry.value;record.size=record.bytes?.byteLength??0;if(!Number.isFinite(record.touched)) record.touched=0;entry.update(record);entry.continue();}};
    };
    request.onsuccess=()=>resolve(request.result);
    request.onerror=()=>resolve(null);request.onblocked=()=>resolve(null);
  });
}
function transaction(database,mode,run) {
  return new Promise((resolve,reject)=>{
    const tx=database.transaction('entries',mode),store=tx.objectStore('entries');let result;
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
    run(store,value=>{result=value;});
  });
}
function prune(records,maxBytes,maxEntries) {
  const invalid=records.filter(record=>!(record.bytes instanceof Uint8Array) || !Number.isFinite(record.touched));
  records=records.filter(record=>!invalid.includes(record));
  records.sort((a,b)=>b.touched-a.touched);let size=0,count=0;
  return invalid.concat(records.filter(record=>{size+=record.bytes.byteLength;return ++count>maxEntries || size>maxBytes;}));
}
export class BuildCache {
  constructor(namespace,{indexedDB=globalThis.indexedDB,maxBytes=LIMIT,maxEntries=MAX_ENTRIES}={}) {
    this.namespace=namespace;this.maxBytes=maxBytes;this.maxEntries=maxEntries;this.database=openDatabase(indexedDB);
  }
  key(path) {return `${this.namespace}\0${path}`;}
  async load() {
    const database=await this.database;
    if(database) {
      try {
        const records=await transaction(database,'readonly',(store,done)=>{const request=store.index('namespace').getAll(this.namespace);request.onsuccess=()=>done(request.result);});
        for(const record of records) if(record.namespace===this.namespace) {
          if(validPath(record.path) && record.key===this.key(record.path) && record.bytes instanceof Uint8Array && record.bytes.length<=this.maxBytes && Number.isFinite(record.touched) && record.checksum===await checksum(record.bytes)) warm.set(record.key,record);
          else {warm.delete(record.key);await transaction(database,'readwrite',store=>store.delete(record.key));}
        }
      } catch { /* Storage is an optimization; disabled storage still compiles. */ }
    }
    const records=[...warm.values()].filter(r=>r.namespace===this.namespace);
    const excluded=new Set(prune(records,this.maxBytes,this.maxEntries).map(r=>r.key));
    return encodeCacheStream(records.filter(r=>!excluded.has(r.key)));
  }
  async save(stream) {
    const entries=decodeCacheStream(stream),touched=Date.now();
    if(!entries.length) return;
    for(const {path,bytes} of entries) if(bytes.length<=this.maxBytes) warm.set(this.key(path),{key:this.key(path),namespace:this.namespace,path,bytes,size:bytes.length,touched,checksum:await checksum(bytes)});
    for(const record of prune([...warm.values()].filter(record=>family(record.namespace)===family(this.namespace)),this.maxBytes,this.maxEntries)) warm.delete(record.key);
    const database=await this.database;if(!database) return;
    try {
      await transaction(database,'readwrite',store=>{
        for(const {path} of entries) {const record=warm.get(this.key(path));if(record) store.put(record);}
        // Read index keys, not every artifact's bytes, on each edit.
        let size=0,count=0;const cursor=store.index('recency').openKeyCursor(null,'prev');
        cursor.onsuccess=()=>{const entry=cursor.result;if(entry){
          const namespace=String(entry.primaryKey).split('\0',1)[0];
          if(family(namespace)===family(this.namespace)) {
            size+=entry.key[1];if(++count>this.maxEntries || size>this.maxBytes) store.delete(entry.primaryKey);
          }
          entry.continue();
        }};
      });
    } catch { /* Quota/private browsing failures do not discard the live workspace. */ }
  }
  async clear() {
    for(const [key,record] of warm) if(record.namespace===this.namespace) warm.delete(key);
    const database=await this.database;if(!database) return;
    try {await transaction(database,'readwrite',store=>{const request=store.index('namespace').getAllKeys(this.namespace);request.onsuccess=()=>{for(const key of request.result) store.delete(key);};});} catch {}
  }
  async remove(path) {
    warm.delete(this.key(path));const database=await this.database;if(!database) return;
    try {await transaction(database,'readwrite',store=>store.delete(this.key(path)));} catch {}
  }
}
