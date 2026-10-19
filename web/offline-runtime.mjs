import {prepareRelease,verifyRelease,cacheName,verified,repairRelease} from './offline-cache.mjs';
export function installOffline(release) {
  const base=new URL('./',self.location.href).href, name=cacheName(release,base);
  const paths=new Map(release.assets.map(a=>[new URL(a.path,base).href,a]));
  self.addEventListener('install',event=>event.waitUntil(prepareRelease(release,base)));
  // Updates wait until all clients of the previous release have closed. No
  // skipWaiting: a running editor and its worker must use one coherent release.
  self.addEventListener('activate',event=>event.waitUntil((async()=>{
    await verifyRelease(release,base);
    // First installation also takes effect on a new navigation, never midway
    // through an already loaded editor.
    for(const key of await caches.keys()) if(key.startsWith(`roclet-release-${encodeURIComponent(new URL(base).pathname)}-`) && key!==name) await caches.delete(key);
  })()));
  self.addEventListener('fetch',event=>{
    if(event.request.method!=='GET') return;
    const url=new URL(event.request.url);url.search='';url.hash='';
    if(url.href===new URL('./offline-release.json',base).href) {event.respondWith(Promise.resolve(Response.json(release)));return;}
    const asset=paths.get(url.href);if(!asset) return;
    event.respondWith((async()=>{
      const cache=await caches.open(name),cached=await cache.match(url.href);
      if(cached) return cached;
      // Repair an evicted individual file only if it still matches this release.
      try {const response=await fetch(url.href,{cache:'no-store'}),bytes=await verified(response,asset);const repaired=new Response(bytes,{headers:response.headers});await cache.put(url.href,repaired.clone());return repaired;}
      catch {return new Response('This offline installation is incomplete. Reconnect and prepare Roclet again.',{status:503,headers:{'Content-Type':'text/plain'}});}
    })());
  });
  self.addEventListener('message',event=>{
    if(!['VERIFY_OFFLINE','REPAIR_OFFLINE'].includes(event.data?.type) || !event.ports[0]) return;
    event.waitUntil((event.data.type==='REPAIR_OFFLINE'?repairRelease(release,base):verifyRelease(release,base)).then(result=>event.ports[0].postMessage({ok:true,...result}),error=>event.ports[0].postMessage({ok:false,error:error.message})));
  });
}
