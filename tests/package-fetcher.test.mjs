import {test} from 'node:test';
import assert from 'node:assert/strict';
import {configuredPackageFetch} from '../web/package-download.mjs';
import {BrowserPackages} from '../web/packages.mjs';
import {BuildCache} from '../web/build-cache.mjs';
import {DocumentSession} from '../web/document-session.mjs';

const source='https://github.com/ageron/roc-ascii/releases/download/v0.5.1/3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst';
const endpoint='https://packages.example/api/packages/';
function configured(fetch,extra={}) {
  return configuredPackageFetch({...extra,configUrl:new URL('https://app.example/web/package-config.json'),fetch:(url,options)=>{
    if(String(url).endsWith('/package-config.json'))return Promise.resolve(Response.json({endpoint}));
    if(String(url).endsWith('/manifest.json'))return Promise.resolve(Response.json({schema:1,packages:[]}));
    return fetch(String(url),options);
  }});
}

test('public quota exhaustion falls through to upstream and bypasses the service for subsequent dependencies',async()=>{
  const requests=[];
  const download=await configured(async(url,options)=>{requests.push(url);assert.equal(options.credentials,'omit');return url.startsWith(endpoint)?new Response('quota',{status:429,headers:{'Retry-After':'60'}}):new Response('direct');});
  assert.equal(await (await download(source,{})).text(),'direct');
  const next=source.replace('/ageron/roc-ascii/','/another/package/');
  assert.equal(await (await download(next,{})).text(),'direct');
  assert.equal(requests.filter(url=>url.startsWith(endpoint)).length,1);
  assert.deepEqual(requests.slice(1),[source,next]);
});

test('public service network errors and deadlines fall back; caller cancellation stays cancelled',async()=>{
  for(const failure of ['network','deadline']) {
    const download=await configured(async(url,{signal})=>{
      if(!url.startsWith(endpoint))return new Response('direct');
      if(failure==='network')throw new TypeError('Failed to fetch');
      return new Promise((_,reject)=>{
        // Node's AbortSignal.timeout timer is unref'ed, unlike browser timers.
        const keepAlive=setTimeout(()=>reject(Error('Deadline did not fire')),1000);
        signal.addEventListener('abort',()=>{clearTimeout(keepAlive);reject(signal.reason);},{once:true});
      });
    },{proxyTimeout:5});
    assert.equal(await (await download(source,{})).text(),'direct');
  }
  const controller=new AbortController();let calls=0;
  const download=await configured(async()=>{calls++;controller.abort();throw controller.signal.reason;});
  await assert.rejects(download(source,{signal:controller.signal}),{name:'AbortError'});assert.equal(calls,1);
});

test('automatic package waits cover byte reading and verification, with a balanced end notification on failure',async()=>{
  const cache=new BuildCache('download-wait-test',{indexedDB:null});await cache.clear();const waiting=[];
  const transport=()=>({});transport.installPackage=()=>{assert.deepEqual(waiting,[true]);return true;};
  const packages=new BrowserPackages(cache,{fetch:async()=>new Response(new Uint8Array([1])),onDownload:value=>waiting.push(value)});
  await packages.install(transport,source);assert.deepEqual(waiting,[true,false]);
  waiting.length=0;
  const failed=new BrowserPackages(new BuildCache('download-wait-failure',{indexedDB:null}),{fetch:async()=>{throw Error('Offline');},onDownload:value=>waiting.push(value)});
  await assert.rejects(failed.install(transport,source),/Offline/);assert.deepEqual(waiting,[true,false]);
  await cache.clear();
});

test('download progress pauses execution budget without opening the manual picker and ignores stopped workers',async()=>{
  const workers=[];class Worker {constructor(){workers.push(this);}postMessage(){}terminate(){}}
  const session=new DocumentSession(new ArrayBuffer(1),Worker),waiting=[];let prompts=0;
  const result=session.request({source:'out = 42'},{onPackageWaiting:value=>waiting.push(value),loadPackage:()=>{prompts++;}});
  workers[0].onmessage({data:{packageDownloading:true}});assert.equal(session.waiting,true);
  workers[0].onmessage({data:{packageDownloading:false}});assert.equal(session.waiting,false);
  workers[0].onmessage({data:{result:{status:'ok'}}});assert.equal((await result).status,'ok');
  assert.deepEqual(waiting,[true,false]);assert.equal(prompts,0);
  session.stop();workers[0].onmessage({data:{packageDownloading:true}});assert.deepEqual(waiting,[true,false]);
});

test('pausing execution time does not allow an indefinitely stalled original host',async()=>{
  const waiting=[];
  const packages=new BrowserPackages(new BuildCache('stalled-package-test',{indexedDB:null}),{
    downloadTimeout:5,onDownload:value=>waiting.push(value),
    fetch:async(_url,{signal})=>new Promise((_,reject)=>{
      const keepAlive=setTimeout(()=>reject(Error('Download did not time out')),1000);
      signal.addEventListener('abort',()=>{clearTimeout(keepAlive);reject(signal.reason);},{once:true});
    }),
  });
  await assert.rejects(packages.install({installPackage(){throw Error('No archive downloaded');}},source),/timeout/);
  assert.deepEqual(waiting,[true,false]);
});
