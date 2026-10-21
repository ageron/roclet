// Site configuration selects transport; compiler identities remain original URLs.
export function githubPackagePath(source) {
  const match=/^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/releases\/download\/([A-Za-z0-9_.+-]+)\/([A-Za-z0-9_.+-]+\.tar\.zst)$/.exec(source);
  if(!match || match.slice(1).some(segment=>segment==='.' || segment==='..')) return null;
  return match.slice(1).join('/');
}
export async function configuredPackageFetch({fetch=globalThis.fetch.bind(globalThis),configUrl=new URL('./package-config.json',import.meta.url)}={}) {
  const response=await fetch(configUrl,{credentials:'omit'});
  if(!response.ok)throw new Error(`Cannot load package download configuration: HTTP ${response.status}`);
  const config=await response.json();
  if(config.endpoint!==null && typeof config.endpoint!=='string')throw new Error('Package endpoint must be a URL or null');
  const endpoint=config.endpoint===null?null:new URL(config.endpoint,configUrl);
  if(endpoint && (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !endpoint.pathname.endsWith('/') || !(endpoint.protocol==='https:' || (endpoint.protocol==='http:' && ['localhost','127.0.0.1','[::1]'].includes(endpoint.hostname)))))throw new Error('Package endpoint requires HTTPS (or localhost HTTP) and a trailing slash');
  return (url,options)=>{
    const path=githubPackagePath(url);
    return fetch(endpoint && path?new URL(path,endpoint).href:url,options);
  };
}
