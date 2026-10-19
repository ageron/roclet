import { createWasmTransport } from '../compiler-adapter/wasm.mjs';
import { BuildCache, compilerNamespace } from './build-cache.mjs';
import { mountChanges } from './workspace.mjs';
import { BrowserPackages } from './packages.mjs';
import { configuredPackageFetch } from './package-download.mjs';
let transport, cache, packages;
async function initialize({bytes,module,compilerDigest}) {
  const instance=await createWasmTransport(module??bytes);
  if(instance.workspace) {
    const namespace=await compilerNamespace(bytes,instance.cacheIdentity(),compilerDigest);
    cache=new BuildCache(namespace);
    // Load downloader configuration only if an uncached package is requested.
    let downloader;
    packages=new BrowserPackages(new BuildCache(`${namespace}:packages`),{fetch:async(...args)=>(downloader??=await configuredPackageFetch())(...args)});
    if(!instance.importCache(await cache.load())) await cache.clear();
  }
  return instance;
}
onmessage = async ({ data }) => {
  try {
    transport ??= await initialize(data);
    mountChanges(transport,data.workspace);
    const start = performance.now();
    const result = packages?await packages.evaluate(transport,data.request):await transport(data.request);
    const workerMs=performance.now()-start;
    if(cache) {try {await cache.save(transport.takeCacheUpdates());} catch {await cache.clear();}}
    postMessage({ result, workerMs, transportMetrics:{requestBytes:transport.lastRequestBytes,responseBytes:transport.lastResponseBytes,
      fileBytes:(data.workspace?.put??[]).reduce((n,file)=>n+new TextEncoder().encode(file.source).length,0)} });
  } catch (error) { postMessage({ error: error.stack ?? error.message }); }
};
