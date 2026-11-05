import {decodeCacheStream,encodeCacheStream} from './build-cache.mjs';
const encoder=new TextEncoder(), LIMIT=32*1024*1024;
const packageKey=async url=>'/cache/package/'+[...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(url)))].map(b=>b.toString(16).padStart(2,'0')).join('');
// URLs and extraction destinations come exclusively from Roc's resolver. The
// compiler verifies Roc package hashes and unbundles archives; JS stores bytes.
export class BrowserPackages {
  constructor(cache,{fetch=globalThis.fetch.bind(globalThis),loadBundle,onDownload=()=>{},onProgress=()=>{},locks=globalThis.navigator?.locks,downloadTimeout=45000}={}) {this.cache=cache;this.fetch=fetch;this.loadBundle=loadBundle;this.onDownload=onDownload;this.onProgress=onProgress;this.locks=locks;this.downloadTimeout=downloadTimeout;this.loaded=null;}
  async remember(transport,url,bytes) {
    if(bytes.length>LIMIT) throw new Error('Roc package exceeds the 32 MiB browser cache limit');
    if(!transport.installPackage(url,bytes)) throw new Error('Roc rejected this bundle: invalid archive or content hash. Choose the bundle from the download link.');
    const entries=await this.loaded,path=await packageKey(url);
    entries.set(path,bytes);
    let total=[...entries.values()].reduce((n,value)=>n+value.length,0);
    for(const [key,value] of entries) {if(total<=LIMIT) break;entries.delete(key);total-=value.length;}
    try {await this.cache.save(encodeCacheStream([{path,bytes}]));} catch { /* Verified package remains mounted if storage is unavailable. */ }
  }
  load() {return this.loaded=this.cache.load().then(decodeCacheStream).then(entries=>new Map(entries.map(({path,bytes})=>[path,bytes])));}
  async restore(transport,url,path,refresh=false) {
    if(refresh)await this.load();
    let entries=await (this.loaded??this.load()),cached=entries.get(path);
    // Another worker (another notebook panel or tab) may have verified and
    // stored this archive since this worker read the persistent cache.
    if(!cached) {entries=await this.load();cached=entries.get(path);}
    if(cached && transport.installPackage(url,cached)) return true;
    entries.delete(path);
    if(cached) await this.cache.remove(path);
    return false;
  }
  async read(response,url,signal) {
    const total=Number(response.headers.get('content-length'))||undefined;
    if(total>LIMIT){await response.body?.cancel();throw new Error('Roc package exceeds the 32 MiB browser cache limit');}
    if(!response.body)return new Uint8Array(await response.arrayBuffer());
    const reader=response.body.getReader(),chunks=[];let received=0,lastReport=0;
    try {
      for(;;) {
        signal.throwIfAborted();
        const {done,value}=await reader.read();if(done)break;
        received+=value.length;
        if(received>LIMIT)throw new Error('Roc package exceeds the 32 MiB browser cache limit');
        chunks.push(value);
        const now=performance.now();
        if(now-lastReport>=150){this.onProgress({phase:'downloading',url,received,total});lastReport=now;}
      }
      this.onProgress({phase:'downloading',url,received,total});
      const bytes=new Uint8Array(received);let offset=0;
      for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
      return bytes;
    } catch(error) {await reader.cancel().catch(()=>{});throw error;}
    finally {reader.releaseLock();}
  }
  async install(transport,url) {
    const path=await packageKey(url);
    if(await this.restore(transport,url,path))return 'cached';
    let failure;
    this.onDownload(true);
    try {
      const signal=AbortSignal.timeout(this.downloadTimeout);
      const download=async(recheck=false)=>{
        if(recheck && await this.restore(transport,url,path,true))return 'cached';
        signal.throwIfAborted();
        this.onProgress({phase:'downloading',url});
        const response=await this.fetch(url,{mode:'cors',credentials:'omit',signal,onProgress:this.onProgress});
        if(!response.ok)throw new Error(`HTTP ${response.status}`);
        const bytes=await this.read(response,url,signal);
        this.onProgress({phase:'verifying',url});
        await this.remember(transport,url,bytes);
        return 'downloaded';
      };
      if(this.locks) {
        let entered=false;
        try {
          const name=`roclet:${this.cache.namespace??'packages'}:${path}`;
          const immediate=await this.locks.request(name,{ifAvailable:true},lock=>{if(!lock)return null;entered=true;return download(true);});
          if(immediate!==null)return immediate;
          this.onProgress({phase:'waiting',url});
          return await this.locks.request(name,{signal},()=>{entered=true;return download(true);});
        } catch(error) {
          // Restricted contexts may expose an unusable LockManager. Retain the
          // ordinary verified download path, without retrying a failed owner.
          if(entered || signal.aborted)throw error;
        }
      }
      return await download();
    } catch(error) {failure=error;}
    finally {this.onDownload(false);}
    if(!this.loadBundle) throw new Error(`Cannot download Roc package ${url}: ${failure.message}`);
    let retry=false;
    for(;;) {
      const bytes=await this.loadBundle({url,error:failure.message,retry});
      try {await this.remember(transport,url,bytes);return 'loaded';}
      catch(error) {failure=error;retry=true;}
    }
  }
  async evaluate(transport,request) {
    const installed=new Set();
    for(;;) {
      const result=await transport(request),required=result.packagesRequired;
      if(!required?.length) return result;
      for(const url of new Set(required.map(packageRequest=>packageRequest.url))) {
        if(typeof url!=='string' || installed.has(url)) throw new Error(`Compiler could not resolve installed package: ${url}`);
        await this.install(transport,url);installed.add(url);
      }
    }
  }
}
