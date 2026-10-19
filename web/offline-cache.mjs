// Immutable, content-addressed releases. A cache is usable only after its final
// commit marker; an interrupted install never replaces the active worker/cache.
export const sha256 = async bytes => [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
export const cacheName = (release,base) => `roclet-release-${encodeURIComponent(new URL(base).pathname)}-${release.version}`;
export async function verified(response,asset) {
  if(!response?.ok) throw new Error(`Missing offline asset: ${asset.path}`);
  const bytes=await response.arrayBuffer();
  if(bytes.byteLength!==asset.bytes || await sha256(bytes)!==asset.sha256) throw new Error(`Integrity check failed: ${asset.path}`);
  return bytes;
}
export async function prepareRelease(release,base,{storage=caches,fetcher=fetch,progress=()=>{}}={}) {
  const name=cacheName(release,base),cache=await storage.open(name),marker=new URL('./offline-complete',base).href;
  await cache.delete(marker);
  try {
    let done=0;
    for(const asset of release.assets) {
      const url=new URL(asset.path,base).href;
      const response=await fetcher(url,{cache:'no-store',credentials:'same-origin',redirect:'error'});
      const bytes=await verified(response,asset);
      await cache.put(url,new Response(bytes,{headers:{'Content-Type':response.headers.get('Content-Type')??'application/octet-stream'}}));
      progress(++done,release.assets.length);
    }
    await cache.put(marker,new Response(release.version));
  } catch(error) { await storage.delete(name);throw error; }
}
export async function verifyRelease(release,base,{storage=caches}={}) {
  const cache=await storage.open(cacheName(release,base));
  if((await (await cache.match(new URL('./offline-complete',base).href))?.text())!==release.version) throw new Error('Offline installation is incomplete. Prepare it again while online.');
  for(const asset of release.assets) await verified(await cache.match(new URL(asset.path,base).href),asset);
  return {version:release.version,files:release.assets.length,bytes:release.assets.reduce((n,a)=>n+a.bytes,0)};
}
export async function repairRelease(release,base,{storage=caches,fetcher=fetch}={}) {
  const cache=await storage.open(cacheName(release,base));
  for(const asset of release.assets) {
    const url=new URL(asset.path,base).href;
    try {await verified(await cache.match(url),asset);continue;}catch { /* Repair only the missing/corrupt member of this version. */ }
    const response=await fetcher(url,{cache:'no-store',redirect:'error'}),bytes=await verified(response,asset);
    await cache.put(url,new Response(bytes,{headers:response.headers}));
  }
  await cache.put(new URL('./offline-complete',base).href,new Response(release.version));
  return verifyRelease(release,base,{storage});
}
