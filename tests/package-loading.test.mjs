import {test} from 'node:test';
import assert from 'node:assert/strict';
import {BrowserPackages} from '../web/packages.mjs';
import {BuildCache,decodeCacheStream} from '../web/build-cache.mjs';
import {configuredPackageFetch,retryDelay,waitForRetry} from '../web/package-download.mjs';
import {packageLabel,packageProgressText} from '../web/package-progress.mjs';

const url='https://github.com/ageron/roc-ascii/releases/download/v0.5.1/3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst';
const endpoint='https://packages.example/api/packages/';
async function configured(fetch,extra={}) {
  return configuredPackageFetch({sleep:async()=>{},random:()=>0,...extra,configUrl:new URL('https://app.example/web/package-config.json'),fetch:(address,options)=>{
    if(String(address).endsWith('/package-config.json'))return Promise.resolve(Response.json({endpoint}));
    if(String(address).endsWith('/manifest.json'))return Promise.resolve(Response.json({schema:1,packages:[]}));
    return fetch(String(address),options);
  }});
}
function locks(){const queues=new Map();return {request(name,_options,run){const result=(queues.get(name)??Promise.resolve()).then(run);queues.set(name,result.catch(()=>{}));return result;}};}
function transport(){return {installPackage(_url,bytes){return bytes[0]===7;}};}

test('busy service is retried within a bound before manual loading and reports the wait',async()=>{
  const waits=[],progress=[];let calls=0;
  const download=await configured(async()=>++calls<3?new Response('busy',{status:503,headers:{'Retry-After':'2'}}):new Response('archive'),{sleep:async ms=>waits.push(ms)});
  assert.equal(await (await download(url,{onProgress:event=>progress.push(event)})).text(),'archive');
  assert.equal(calls,3);assert.deepEqual(waits,[2000,2000]);
  assert.deepEqual(progress.filter(p=>p.phase==='retrying').map(p=>p.attempt),[2,3]);
});

test('retries stop after three attempts and temporary busy responses do not disable the next package',async()=>{
  let calls=0;const requested=[];
  const download=await configured(async address=>{requested.push(address);if(address.startsWith(endpoint)){calls++;return new Response('busy',{status:503,headers:{'Retry-After':'0'}});}return new Response('direct');});
  await download(url,{});assert.equal(calls,3);assert.equal(requested.at(-1),url);
  await download(url,{});assert.equal(calls,6);
});

test('missing and invalid packages are not retried; long quota waits use the fallback',async()=>{
  for(const status of [404,400,502,429]) {
    let calls=0;
    const download=await configured(async address=>{
      if(!address.startsWith(endpoint))return new Response('direct');
      calls++;return new Response('failed',{status,headers:status===429?{'Retry-After':'60'}:{}});
    });
    assert.equal(await (await download(url,{})).text(),'direct');assert.equal(calls,1,status);
  }
  assert.equal(retryDelay(new Response('',{status:503,headers:{'Retry-After':'Thu, 05 Nov 2026 01:00:02 GMT'}}),0,{now:()=>Date.parse('2026-11-05T01:00:00Z')}),2000);
  assert.equal(retryDelay(null,0,{random:()=>0}),500);
});

test('cancelling during retry stops without falling back or making another request',async()=>{
  const controller=new AbortController();let calls=0;
  const download=await configured(async()=>{calls++;return new Response('busy',{status:503});},{sleep:async(_ms,signal)=>{controller.abort();signal.throwIfAborted();}});
  await assert.rejects(download(url,{signal:controller.signal}),{name:'AbortError'});assert.equal(calls,1);
  const other=new AbortController(),waiting=waitForRetry(10000,other.signal);other.abort();await assert.rejects(waiting,{name:'AbortError'});
});

test('concurrent package owners share one verified archive and each compiler installs its own copy',async()=>{
  const cache=new BuildCache('shared-lock-test:packages',{indexedDB:null});await cache.clear();
  const manager=locks();let downloads=0;
  const fetch=async()=>{downloads++;await new Promise(resolve=>setImmediate(resolve));return new Response(new Uint8Array([7,2,3]));};
  const a=new BrowserPackages(cache,{fetch,locks:manager}),b=new BrowserPackages(new BuildCache(cache.namespace,{indexedDB:null}),{fetch,locks:manager});
  const installed=[];
  const make=()=>({installPackage(_url,bytes){installed.push([...bytes]);return bytes[0]===7;}});
  assert.deepEqual(await Promise.all([a.install(make(),url),b.install(make(),url)]),['downloaded','cached']);
  assert.equal(downloads,1);assert.deepEqual(installed,[[7,2,3],[7,2,3]]);await cache.clear();
});

test('a rejected owner releases its lock and never gives corrupt bytes to another compiler',async()=>{
  const cache=new BuildCache('failed-owner-test:packages',{indexedDB:null});await cache.clear();const manager=locks();let calls=0;
  const fetch=async()=>new Response(new Uint8Array([++calls===1?99:7]));
  const a=new BrowserPackages(cache,{fetch,locks:manager}),b=new BrowserPackages(new BuildCache(cache.namespace,{indexedDB:null}),{fetch,locks:manager});
  const result=await Promise.allSettled([a.install(transport(),url),b.install(transport(),url)]);
  assert.equal(result[0].status,'rejected');assert.equal(result[1].value,'downloaded');assert.equal(calls,2);
  assert.deepEqual([...decodeCacheStream(await cache.load())[0].bytes],[7]);await cache.clear();
});

test('download progress includes streamed bytes and verification, with a fallback for unavailable locks',async()=>{
  const events=[],cache=new BuildCache('progress-test:packages',{indexedDB:null});await cache.clear();
  const packages=new BrowserPackages(cache,{locks:{request(){throw new DOMException('Disabled','SecurityError');}},onProgress:event=>events.push(event),fetch:async()=>new Response(new ReadableStream({start(controller){controller.enqueue(new Uint8Array([7]));controller.enqueue(new Uint8Array([2,3]));controller.close();}}),{headers:{'Content-Length':'3'}})});
  assert.equal(await packages.install(transport(),url),'downloaded');
  assert.equal(events.at(-1).phase,'verifying');assert(events.some(event=>event.phase==='downloading' && event.received===3 && event.total===3));
  assert.equal(packageLabel(url),'roc-ascii v0.5.1');
  assert.equal(packageProgressText({phase:'downloading',url,received:2048}),'Downloading roc-ascii v0.5.1 · 2 KB received…');
  assert.match(packageProgressText({phase:'retrying',url,attempt:2,attempts:3,waitMs:2000}),/attempt 2 of 3 in 2 s/);
  await cache.clear();
});

test('streamed archives cannot bypass the size limit when Content-Length is missing',async()=>{
  const cache=new BuildCache('stream-limit-test:packages',{indexedDB:null});await cache.clear();let count=0,cancelled=false,installed=false;
  const chunk=new Uint8Array(1024*1024);
  const packages=new BrowserPackages(cache,{locks:null,fetch:async()=>new Response(new ReadableStream({pull(controller){count++;controller.enqueue(chunk);},cancel(){cancelled=true;}}))});
  await assert.rejects(packages.install({installPackage(){installed=true;return true;}},url),/32 MiB/);
  assert.equal(installed,false);assert.equal(cancelled,true);assert.deepEqual(decodeCacheStream(await cache.load()),[]);
});
