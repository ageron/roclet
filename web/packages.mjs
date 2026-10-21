import {decodeCacheStream,encodeCacheStream} from './build-cache.mjs';
const encoder=new TextEncoder(), LIMIT=32*1024*1024;
const packageKey=async url=>'/cache/package/'+[...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(url)))].map(b=>b.toString(16).padStart(2,'0')).join('');
// URLs and extraction destinations come exclusively from Roc's resolver. The
// compiler verifies Roc package hashes and unbundles archives; JS stores bytes.
export class BrowserPackages {
  constructor(cache,{fetch=globalThis.fetch.bind(globalThis),loadBundle}={}) {this.cache=cache;this.fetch=fetch;this.loadBundle=loadBundle;this.loaded=null;}
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
  async install(transport,url) {
    const path=await packageKey(url);
    let entries=await (this.loaded??this.load()),cached=entries.get(path);
    // Another worker (another notebook panel or tab) may have verified and
    // stored this archive since this worker read the persistent cache.
    if(!cached) {entries=await this.load();cached=entries.get(path);}
    if(cached && transport.installPackage(url,cached)) return 'cached';
    entries.delete(path);
    if(cached) await this.cache.remove(path);
    let failure;
    try {
      const response=await this.fetch(url,{mode:'cors',credentials:'omit'});
      if(!response.ok) throw new Error(`HTTP ${response.status}`);
      if(Number(response.headers.get('content-length'))>LIMIT) throw new Error('Roc package exceeds the 32 MiB browser cache limit');
      await this.remember(transport,url,new Uint8Array(await response.arrayBuffer()));
      return 'downloaded';
    } catch(error) {failure=error;}
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
