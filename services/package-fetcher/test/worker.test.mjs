import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createFetcher,parsePackage,downloadPackage,allowedUpstream} from '../src/fetcher.mjs';

const name='3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst';
const address=`https://packages.example/api/packages/ageron/roc-ascii/v0.5.1/${name}`;
const pkg=parsePackage(new URL(address));
const bytes=new Uint8Array(await readFile(new URL('../../../web/vendor/roc-packages/archives/'+name,import.meta.url)));
const env={PACKAGE_RATE_LIMITER:{limit:async()=>({success:true})}};
const request=(url=address,method='GET')=>new Request(url,{method});
function context(){const jobs=[];return {waitUntil(job){jobs.push(job);},async done(){await Promise.all(jobs);}};}
function cacheFixture(){const entries=new Map();return {match:async key=>entries.get(key.url)?.clone(),put:async(key,response)=>{entries.set(key.url,response.clone());}};}

test('only canonical GitHub release paths with 32-byte Roc hashes are accepted',()=>{
  assert.equal(pkg.source,`https://github.com/ageron/roc-ascii/releases/download/v0.5.1/${name}`);
  for(const suffix of ['?url=https://evil.example','/extra','%2fother'])assert.equal(parsePackage(new URL(address+suffix)),null);
  for(const url of ['https://packages.example/api/packages/a/b/v/file.zip','https://packages.example/api/packages/a/b/v/nohash.tar.zst','https://packages.example/api/packages/a/b/v/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.tar.zst'])assert.equal(parsePackage(new URL(url)),null);
  for(const url of ['http://github.com/x','https://github.com.evil.example/x','https://127.0.0.1/x','https://github.com:444/x','https://user@github.com/x'])assert.equal(allowedUpstream(new URL(url)),false);
});

test('download follows approved redirects without forwarding browser authentication and verifies real bytes',async()=>{
  const calls=[];
  const downloaded=await downloadPackage(pkg,{fetch:async(url,options)=>{
    calls.push({url,options});
    return calls.length===1?new Response(null,{status:302,headers:{Location:'https://release-assets.githubusercontent.com/asset?signature=public'}}):new Response(bytes);
  }});
  assert.deepEqual(downloaded,bytes);assert.equal(calls.length,2);
  for(const call of calls){assert.equal(call.options.redirect,'manual');assert.equal(call.options.credentials,'omit');assert.equal(call.options.headers.Authorization,undefined);assert.equal(call.options.headers.Cookie,undefined);}
});

test('hash mismatch, unapproved redirects, encoding, missing assets and bounded streamed bodies fail',async()=>{
  await assert.rejects(downloadPackage(pkg,{fetch:async()=>new Response('corrupt')}),/content hash/);
  await assert.rejects(downloadPackage(pkg,{fetch:async()=>new Response(null,{status:302,headers:{Location:'https://169.254.169.254/latest'}})}),/permitted/);
  await assert.rejects(downloadPackage(pkg,{fetch:async()=>new Response(null,{status:302,headers:{Location:pkg.source}})}),/redirect/);
  await assert.rejects(downloadPackage(pkg,{fetch:async()=>new Response(bytes,{headers:{'Content-Encoding':'gzip'}})}),/encoding/);
  await assert.rejects(downloadPackage(pkg,{fetch:async()=>new Response('',{status:404})}),/could not provide/);
  await assert.rejects(downloadPackage(pkg,{maxBytes:4,fetch:async()=>new Response(bytes,{headers:{'Content-Length':String(bytes.length)}})}),/limit/);
  await assert.rejects(downloadPackage(pkg,{maxBytes:4,fetch:async()=>new Response(new ReadableStream({start(controller){controller.enqueue(bytes);controller.close();}}))}),/limit/);
});

test('successful responses are public and immutable; verified cache deduplicates by content hash',async()=>{
  let downloads=0;const ctx=context();
  const worker=createFetcher({cache:cacheFixture(),fetch:async()=>{downloads++;return new Response(bytes);}});
  const first=await worker.fetch(request(),env,ctx);
  assert.equal(first.headers.get('Access-Control-Allow-Origin'),'*');assert.match(first.headers.get('Cache-Control'),/immutable/);
  assert.deepEqual(new Uint8Array(await first.arrayBuffer()),bytes);await ctx.done();
  const second=await worker.fetch(request(address.replace('/ageron/roc-ascii/','/another/repository/')),env,ctx);
  assert.equal(second.headers.get('X-Roclet-Package-Cache'),'hit');assert.deepEqual(new Uint8Array(await second.arrayBuffer()),bytes);assert.equal(downloads,1);
  const head=await worker.fetch(request(address,'HEAD'),env,ctx);assert.equal(await head.text(),'');assert.equal(head.headers.get('Content-Length'),String(bytes.length));
});

test('concurrent requests share one verified download and other cold packages receive a bounded busy response',async()=>{
  let release;const gate=new Promise(resolve=>{release=resolve;});let downloads=0;
  const worker=createFetcher({fetch:async()=>{downloads++;await gate;return new Response(bytes);}}),ctx=context();
  const a=worker.fetch(request(),env,ctx),b=worker.fetch(request(),env,ctx);
  await new Promise(resolve=>setImmediate(resolve));
  const other='https://packages.example/api/packages/roc-lang/unicode/4.3.1/BNmth7q83JT3Pc2neutkWibVwFwNNNBLhhKfZhmDREeL.tar.zst';
  assert.equal((await worker.fetch(request(other),env,ctx)).status,503);
  release();
  for(const response of await Promise.all([a,b]))assert.deepEqual(new Uint8Array(await response.arrayBuffer()),bytes);
  await ctx.done();assert.equal(downloads,1);
});

test('all failure responses allow CORS, are uncached, and corrupted bytes never enter cache',async()=>{
  let writes=0;
  const worker=createFetcher({cache:{put:async()=>{writes++;}},fetch:async()=>new Response('wrong')}),ctx=context();
  const response=await worker.fetch(request(),env,ctx);await ctx.done();
  assert.equal(response.status,502);assert.equal(response.headers.get('Access-Control-Allow-Origin'),'*');assert.equal(response.headers.get('Cache-Control'),'no-store');assert.equal(writes,0);
});

test('rate limiting, missing binding, methods and preflight do not fetch archives',async()=>{
  const worker=createFetcher({fetch:()=>{throw Error('Unexpected upstream download');}});
  assert.equal((await worker.fetch(request(),{})).status,503);
  const limited=await worker.fetch(request(),{PACKAGE_RATE_LIMITER:{limit:async()=>({success:false})}});
  assert.equal(limited.status,429);assert.equal(limited.headers.get('Retry-After'),'60');
  assert.equal((await worker.fetch(request(address,'POST'),env)).status,405);
  assert.equal((await worker.fetch(request(address,'OPTIONS'))).status,204);
  assert.equal((await worker.fetch(request('https://packages.example/health'))).status,200);
});

test('deadline returns an uncached CORS error and frees the next download slot',async()=>{
  let count=0;
  const worker=createFetcher({timeoutMs:5,fetch:async(_url,{signal})=>{
    if(++count>1)return new Response(bytes);
    return new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}));
  }});
  const timed=await worker.fetch(request(),env);assert.equal(timed.status,504);assert.equal(timed.headers.get('Cache-Control'),'no-store');
  assert.equal((await worker.fetch(request(),env)).status,200);
});
