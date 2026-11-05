import {serverProjectReady} from './server-project.mjs';
// Site configuration selects transport; compiler identities remain original URLs.
export function githubPackagePath(source) {
  const match=/^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/releases\/download\/([A-Za-z0-9_.+-]+)\/([A-Za-z0-9_.+-]+\.tar\.zst)$/.exec(source);
  if(!match || match.slice(1).some(segment=>segment==='.' || segment==='..')) return null;
  return match.slice(1).join('/');
}
export async function configuredPackageFetch({fetch=globalThis.fetch.bind(globalThis),configUrl=new URL('./package-config.json',import.meta.url),mirrorUrl=new URL('./vendor/roc-packages/manifest.json',configUrl)}={}) {
  // Older/self-hosted sites may omit the optional mirror. Its absence must not
  // disable direct downloads, a configured proxy, or the manual file fallback.
  const mirrorReady=(async()=>{
    try {
      const response=await fetch(mirrorUrl,{credentials:'same-origin'});
      if(!response.ok)return new Map();
      const manifest=await response.json();
      if(manifest.schema!==1 || !Array.isArray(manifest.packages))return new Map();
      return new Map(manifest.packages.filter(entry=>typeof entry.url==='string' && /^archives\/[A-Za-z0-9_.+-]+\.tar\.zst$/.test(entry.file)).map(entry=>[entry.url,new URL(entry.file,mirrorUrl).href]));
    } catch {return new Map();}
  })();
  const response=await fetch(configUrl,{credentials:'same-origin'});
  if(!response.ok)throw new Error(`Cannot load package download configuration: HTTP ${response.status}`);
  const config=await response.json();
  if(config.endpoint!==null && typeof config.endpoint!=='string')throw new Error('Package endpoint must be a URL or null');
  const local=await serverProjectReady;
  const endpoint=local?new URL('/api/packages/',configUrl):config.endpoint===null?null:new URL(config.endpoint,configUrl);
  if(endpoint && (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !endpoint.pathname.endsWith('/') || !(endpoint.protocol==='https:' || (endpoint.protocol==='http:' && (local || ['localhost','127.0.0.1','[::1]'].includes(endpoint.hostname))))))throw new Error('Package endpoint requires HTTPS (or localhost HTTP) and a trailing slash');
  const mirror=await mirrorReady;
  return async(url,options)=>{
    const mirrored=mirror.get(url);
    if(mirrored) {
      try {
        const response=await fetch(mirrored,{...options,credentials:local?'same-origin':'omit'});
        if(response.ok)return response;
      } catch(error) {if(options?.signal?.aborted)throw error;}
    }
    const path=githubPackagePath(url);
    // Only the authenticated local proxy receives the browser's session cookie.
    // External package hosts and configured remote proxies never receive it.
    return fetch(endpoint && path?new URL(path,endpoint).href:url,{...options,credentials:local && endpoint && path?'same-origin':'omit'});
  };
}
