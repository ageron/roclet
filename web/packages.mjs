import {decodeCacheStream,encodeCacheStream} from './build-cache.mjs';
const encoder=new TextEncoder(), LIMIT=32*1024*1024;
const packageKey=async url=>'/cache/package/'+[...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(url)))].map(b=>b.toString(16).padStart(2,'0')).join('');
// URLs and extraction destinations come exclusively from Roc's resolver. The
// compiler verifies Roc package hashes and unbundles archives; JS stores bytes.
export class BrowserPackages {
  constructor(cache,{fetch=globalThis.fetch}={}) {this.cache=cache;this.fetch=fetch;this.loaded=null;}
  async install(transport,url) {
    this.loaded??=this.cache.load().then(decodeCacheStream).then(entries=>new Map(entries.map(({path,bytes})=>[path,bytes])));
    const entries=await this.loaded,path=await packageKey(url),cached=entries.get(path);
    if(cached && transport.installPackage(url,cached)) return 'cached';
    entries.delete(path);
    if(cached) await this.cache.remove(path);
    let response;
    try {response=await this.fetch(url,{mode:'cors',credentials:'omit'});}
    catch {throw new Error(`Cannot download Roc package ${url}. The package server must be reachable and allow browser CORS requests.`);}
    if(!response.ok) throw new Error(`Cannot download Roc package ${url}: HTTP ${response.status}`);
    if(Number(response.headers.get('content-length'))>LIMIT) throw new Error('Roc package exceeds the 32 MiB browser cache limit');
    const bytes=new Uint8Array(await response.arrayBuffer());
    if(bytes.length>LIMIT) throw new Error('Roc package exceeds the 32 MiB browser cache limit');
    if(!transport.installPackage(url,bytes)) throw new Error(`Roc rejected package ${url}: invalid archive or content hash`);
    entries.set(path,bytes);
    let total=[...entries.values()].reduce((n,value)=>n+value.length,0);
    for(const [key,value] of entries) {if(total<=LIMIT) break;entries.delete(key);total-=value.length;}
    try {await this.cache.save(encodeCacheStream([{path,bytes}]));} catch { /* Verified package remains mounted if storage is unavailable. */ }
    return 'downloaded';
  }
  async evaluate(transport,request) {
    const installed=new Set();
    for(;;) {
      const result=await transport(request),required=result.packagesRequired;
      if(!required?.length) return result;
      for(const {url} of required) {
        if(typeof url!=='string' || installed.has(url)) throw new Error(`Compiler could not resolve installed package: ${url}`);
        await this.install(transport,url);installed.add(url);
      }
    }
  }
}
