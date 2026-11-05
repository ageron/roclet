import {blake3} from '@noble/hashes/blake3.js';

export const PREFIX='/api/packages/',MAX_BYTES=32*1024*1024;
const ALPHABET='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const HEADERS={
  'Access-Control-Allow-Origin':'*',
  'Access-Control-Allow-Methods':'GET, HEAD, OPTIONS',
  'Access-Control-Expose-Headers':'X-Roclet-Package-Cache, Retry-After',
  'X-Content-Type-Options':'nosniff',
};
class DownloadError extends Error {
  constructor(message,status=502) {super(message);this.status=status;}
}

export function parsePackage(url) {
  if(url.search || url.hash || url.pathname.length>2048 || !url.pathname.startsWith(PREFIX))return null;
  const parts=url.pathname.slice(PREFIX.length).split('/');
  if(parts.length!==4 || parts.some(part=>!part || part==='.' || part==='..' || !/^[A-Za-z0-9_.+-]+$/.test(part)))return null;
  const [owner,repo,version,name]=parts;
  if(!name.endsWith('.tar.zst'))return null;
  const stem=name.slice(0,-8);
  let start=stem.length;
  while(start>0 && ALPHABET.includes(stem[start-1]))start--;
  const encoded=stem.slice(start);
  if(encoded.length<32 || encoded.length>44)return null;
  let number=0n;
  for(const char of encoded)number=number*58n+BigInt(ALPHABET.indexOf(char));
  if(number>=(1n<<256n))return null;
  const hash=new Uint8Array(32);
  for(let i=31;i>=0;i--){hash[i]=Number(number&255n);number>>=8n;}
  let leading=0,zeros=0;
  while(encoded[leading]==='1')leading++;
  while(hash[zeros]===0)zeros++;
  if(leading+32-zeros!==32)return null;
  return {source:`https://github.com/${owner}/${repo}/releases/download/${version}/${name}`,hash,
    key:[...hash].map(byte=>byte.toString(16).padStart(2,'0')).join('')};
}

export function allowedUpstream(url) {
  return url.protocol==='https:' && !url.username && !url.password && !url.port &&
    ['github.com','release-assets.githubusercontent.com','objects.githubusercontent.com'].includes(url.hostname);
}

function message(text,status,extra={}) {
  return new Response(text,{status,headers:{...HEADERS,'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store',...extra}});
}
function archive(bytes,hit,head=false) {
  // Distinct streams share immutable verified bytes when several requests join
  // one download, avoiding a full archive copy per waiting browser.
  const body=head?null:new ReadableStream({start(controller){controller.enqueue(bytes);controller.close();}});
  return new Response(body,{headers:{...HEADERS,'Content-Type':'application/octet-stream',
    'Content-Length':String(bytes.length),'Cache-Control':'public, max-age=31536000, immutable',
    'X-Roclet-Package-Cache':hit}});
}

export async function downloadPackage(pkg,{fetch=globalThis.fetch,signal,maxBytes=MAX_BYTES}={}) {
  let url=new URL(pkg.source);
  for(let redirects=0;;redirects++) {
    if(!allowedUpstream(url))throw new DownloadError('Package redirect is not a permitted GitHub host');
    // Forward no browser cookies, tokens, headers or upstream authentication.
    const response=await fetch(url.href,{redirect:'manual',credentials:'omit',signal,
      headers:{'Accept-Encoding':'identity','User-Agent':'Roclet package fetcher'}});
    if([301,302,303,307,308].includes(response.status)) {
      await response.body?.cancel();
      const location=response.headers.get('Location');
      if(redirects>=3 || !location)throw new DownloadError('Invalid package redirect');
      url=new URL(location,url);continue;
    }
    if(response.status!==200) {
      await response.body?.cancel();
      throw new DownloadError('Package host could not provide this archive',response.status===404?404:502);
    }
    const encoding=response.headers.get('Content-Encoding');
    if(encoding && encoding!=='identity') {
      await response.body?.cancel();throw new DownloadError('Unexpected package encoding');
    }
    if(Number(response.headers.get('Content-Length'))>maxBytes) {
      await response.body?.cancel();throw new DownloadError('Package exceeds the download limit',413);
    }
    if(!response.body)throw new DownloadError('Empty package response');
    const reader=response.body.getReader(),chunks=[],hasher=blake3.create();let size=0;
    try {
      for(;;) {
        const {value,done}=await reader.read();if(done)break;
        size+=value.length;
        if(size>maxBytes)throw new DownloadError('Package exceeds the download limit',413);
        hasher.update(value);chunks.push(value);
      }
      const hash=hasher.digest();
      if(hash.some((byte,index)=>byte!==pkg.hash[index]))throw new DownloadError('Package content hash does not match its URL');
      // Roc verifies and unbundles the bytes independently in the browser.
      const bytes=new Uint8Array(size);let offset=0;
      for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
      return bytes;
    } catch(error) {await reader.cancel().catch(()=>{});throw error;}
    finally {hasher.destroy();reader.releaseLock();}
  }
}

export function createFetcher({fetch=globalThis.fetch,cache=globalThis.caches?.default,timeoutMs=30000,maxBytes=MAX_BYTES}={}) {
  const pending=new Map();
  return {async fetch(request,env={},ctx={waitUntil(){}}) {
    const url=new URL(request.url);
    if(url.pathname==='/health' && request.method==='GET')return message('Roclet package fetcher ready\n',200);
    const pkg=parsePackage(url);
    if(!pkg)return message('Expected a GitHub release archive with a Roc content hash',400);
    if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{...HEADERS,'Cache-Control':'no-store','Access-Control-Max-Age':'86400'}});
    if(!['GET','HEAD'].includes(request.method))return message('Use GET, HEAD or OPTIONS',405,{Allow:'GET, HEAD, OPTIONS'});
    try {
      // Missing bindings fail closed, including a mistakenly incomplete deployment.
      if(!env.PACKAGE_RATE_LIMITER)return message('Package service is not configured',503);
      const {success}=await env.PACKAGE_RATE_LIMITER.limit({key:request.headers.get('CF-Connecting-IP')??'local'});
      if(!success)return message('Package request limit reached; retry later',429,{'Retry-After':'60'});
      const key=new Request(new URL(`/verified-v1/${pkg.key}`,url.origin));
      let cached;
      try {cached=await cache?.match(key);} catch { /* Cache failure must not disable downloads. */ }
      if(cached) {
        const headers=new Headers(cached.headers);headers.set('X-Roclet-Package-Cache','hit');
        return new Response(request.method==='HEAD'?null:cached.body,{headers});
      }
      let download=pending.get(pkg.key);
      if(!download) {
        // One cold download per isolate bounds memory; Cloudflare can create
        // more isolates. This is not a global traffic or billing limit.
        if(pending.size>=1)return message('Package service is busy; retry shortly',503,{'Retry-After':'2'});
        download=(async()=>{
          const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs);
          try {return await downloadPackage(pkg,{fetch,signal:controller.signal,maxBytes});}
          catch(error) {if(controller.signal.aborted)throw new DownloadError('Package download timed out',504);throw error;}
          finally {clearTimeout(timer);}
        })();
        pending.set(pkg.key,download);
        // Avoid an unhandled rejection from a discarded finally() promise.
        download.then(()=>pending.delete(pkg.key),()=>pending.delete(pkg.key));
        ctx.waitUntil(download.then(bytes=>cache?.put(key,archive(bytes,'miss'))).catch(()=>{}));
      }
      const bytes=await download;
      return archive(bytes,'miss',request.method==='HEAD');
    } catch(error) {
      return message(error instanceof DownloadError?error.message:'Package download failed',error instanceof DownloadError?error.status:502);
    }
  }};
}
