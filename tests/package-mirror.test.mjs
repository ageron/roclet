import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {configuredPackageFetch} from '../web/package-download.mjs';

const manifestUrl=new URL('../web/vendor/roc-packages/manifest.json',import.meta.url);
const manifest=JSON.parse(await readFile(manifestUrl));

test('pinned mirror archives and licenses exist, with complete dependency closure',async()=>{
  const urls=new Set(manifest.packages.map(entry=>entry.url));
  assert.equal(urls.size,manifest.packages.length);
  for(const entry of manifest.packages) {
    const bytes=await readFile(new URL(entry.file,manifestUrl));
    assert.equal(bytes.length,entry.bytes,entry.url);
    assert.equal(createHash('sha256').update(bytes).digest('hex'),entry.sha256,entry.url);
    assert((await readFile(new URL(entry.licenseFile,manifestUrl),'utf8')).trim());
    for(const dependency of entry.dependencies)assert(urls.has(dependency),dependency);
  }
});

test('mirror preserves URL identity and works below a deployment prefix before trying a proxy',async()=>{
  const entry=manifest.packages.find(entry=>entry.package.endsWith('/roc-parser') && entry.version==='3.0.0');
  const configUrl=new URL('https://example.org/roclet/web/package-config.json'),requested=[];
  const fetch=async(url,options)=>{
    requested.push({url:String(url),options});
    if(String(url)===configUrl.href)return Response.json({endpoint:'https://proxy.example/api/packages/'});
    if(String(url).endsWith('/manifest.json'))return Response.json(manifest);
    return new Response('mirror archive');
  };
  const download=await configuredPackageFetch({fetch,configUrl});
  const response=await download(entry.url,{credentials:'include'});
  assert.equal(await response.text(),'mirror archive');
  assert.equal(requested.at(-1).url,new URL('vendor/roc-packages/'+entry.file,configUrl).href);
  assert.equal(requested.at(-1).options.credentials,'omit');
  assert(requested.every(request=>request.url.startsWith('https://example.org/roclet/')));
});

test('missing or unavailable mirror falls through to original transport',async()=>{
  const source=manifest.packages[0].url;
  const configUrl=new URL('https://example.org/roclet/web/package-config.json');
  for(const failure of ['manifest','archive','network','malformed']) {
    const requested=[];
    const fetch=async url=>{
      const address=String(url);requested.push(address);
      if(address===configUrl.href)return Response.json({endpoint:null});
      if(address.endsWith('/manifest.json'))return failure==='manifest'?new Response('',{status:404}):Response.json(failure==='malformed'?{schema:1,packages:[{url:source,file:'../../private.tar.zst'}]}:manifest);
      if(address===source)return new Response('upstream archive');
      if(failure==='network')throw new TypeError('Failed to fetch');
      return new Response('',{status:404});
    };
    const download=await configuredPackageFetch({fetch,configUrl});
    assert.equal(await (await download(source,{})).text(),'upstream archive',failure);
    assert.equal(requested.at(-1),source);
  }
});
