import {serverProjectReady} from './server-project.mjs';
// Site configuration selects transport; compiler identities remain original URLs.
export function githubPackagePath(source) {
  const match=/^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/releases\/download\/([A-Za-z0-9_.+-]+)\/([A-Za-z0-9_.+-]+\.tar\.zst)$/.exec(source);
  if(!match || match.slice(1).some(segment=>segment==='.' || segment==='..')) return null;
  return match.slice(1).join('/');
}
export function waitForRetry(ms,signal) {
  return new Promise((resolve,reject)=>{
    if(signal?.aborted){reject(signal.reason);return;}
    const abort=()=>{clearTimeout(timer);reject(signal.reason);};
    const timer=setTimeout(()=>{signal?.removeEventListener('abort',abort);resolve();},ms);
    signal?.addEventListener('abort',abort,{once:true});
  });
}
export function retryDelay(response,attempt,{random=Math.random,now=Date.now}={}) {
  // Hash/encoding failures currently use 502; do not blindly retry them.
  if(response && ![408,425,429,500,503,504].includes(response.status))return null;
  const header=response?.headers.get('Retry-After');
  if(header) {
    const seconds=Number(header),delay=Number.isFinite(seconds)?seconds*1000:Date.parse(header)-now();
    if(Number.isFinite(delay))return delay>5000?null:Math.max(0,delay);
  }
  return Math.min(4000,500*(2**attempt))*(1+random()*0.5);
}
export async function configuredPackageFetch({fetch=globalThis.fetch.bind(globalThis),configUrl=new URL('./package-config.json',import.meta.url),mirrorUrl=new URL('./vendor/roc-packages/manifest.json',configUrl),proxyTimeout=35000,sleep=waitForRetry,random=Math.random}={}) {
  // Older/self-hosted sites may omit the optional mirror. Its absence must not
  // disable direct downloads, a configured proxy, or the manual file fallback.
  const mirrorReady=(async()=>{
    try {
      const response=await fetch(mirrorUrl,{credentials:'same-origin',signal:AbortSignal.timeout(10000)});
      if(!response.ok)return new Map();
      const manifest=await response.json();
      if(manifest.schema!==1 || !Array.isArray(manifest.packages))return new Map();
      return new Map(manifest.packages.filter(entry=>typeof entry.url==='string' && /^archives\/[A-Za-z0-9_.+-]+\.tar\.zst$/.test(entry.file)).map(entry=>[entry.url,new URL(entry.file,mirrorUrl).href]));
    } catch {return new Map();}
  })();
  const response=await fetch(configUrl,{credentials:'same-origin',signal:AbortSignal.timeout(10000)});
  if(!response.ok)throw new Error(`Cannot load package download configuration: HTTP ${response.status}`);
  const config=await response.json();
  if(config.endpoint!==null && typeof config.endpoint!=='string')throw new Error('Package endpoint must be a URL or null');
  const local=await serverProjectReady;
  const endpoint=local?new URL('/api/packages/',configUrl):config.endpoint===null?null:new URL(config.endpoint,configUrl);
  if(endpoint && (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !endpoint.pathname.endsWith('/') || !(endpoint.protocol==='https:' || (endpoint.protocol==='http:' && (local || ['localhost','127.0.0.1','[::1]'].includes(endpoint.hostname))))))throw new Error('Package endpoint requires HTTPS (or localhost HTTP) and a trailing slash');
  const mirror=await mirrorReady;
  let unavailableUntil=0;
  return async(url,options)=>{
    const {onProgress,...requestOptions}=options??{};options=requestOptions;
    const mirrored=mirror.get(url);
    if(mirrored) {
      try {
        const response=await fetch(mirrored,{...options,credentials:local?'same-origin':'omit'});
        if(response.ok)return response;
      } catch(error) {if(options?.signal?.aborted)throw error;}
    }
    const path=githubPackagePath(url);
    if(endpoint && path && !local) {
      if(Date.now()>=unavailableUntil) {
        const deadline=AbortSignal.timeout(proxyTimeout);
        const signal=options.signal?AbortSignal.any([options.signal,deadline]):deadline;
        const attempts=3;
        for(let attempt=0;attempt<attempts;attempt++) {
          let response,delay;
          try {
            response=await fetch(new URL(path,endpoint).href,{...options,signal,credentials:'omit'});
            if(response.ok)return response;
            delay=retryDelay(response,attempt,{random});
            await response.body?.cancel();
          } catch(error) {
            if(options.signal?.aborted)throw error;
            if(signal.aborted){unavailableUntil=Date.now()+60000;break;}
            delay=retryDelay(null,attempt,{random});
          }
          if(delay!==null && attempt+1<attempts) {
            onProgress?.({phase:'retrying',url,attempt:attempt+2,attempts,waitMs:delay});
            try {await sleep(delay,signal);}
            catch(error) {if(options.signal?.aborted)throw error;unavailableUntil=Date.now()+60000;break;}
            onProgress?.({phase:'downloading',url});
            continue;
          }
          if(response?.status===503 && delay!==null)break; // Busy, not an account-wide outage.
          if(!response || response.status===429 || response.status>=500)unavailableUntil=Date.now()+60000;
          break;
        }
      }
      // A quota-exhausted or unavailable public service must not impose a long
      // wait for every transitive dependency. Try the original host, then let
      // BrowserPackages offer its existing verified file-loading fallback.
      return fetch(url,{...options,credentials:'omit'});
    }
    // Only the authenticated local proxy receives the browser's session cookie.
    // External package hosts and configured remote proxies never receive it.
    return fetch(endpoint && path?new URL(path,endpoint).href:url,{...options,credentials:local && endpoint && path?'same-origin':'omit'});
  };
}
