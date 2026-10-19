export const workerSource = release => `import {installOffline} from './offline-runtime.mjs';\ninstallOffline(${JSON.stringify(release)});\n`;
const base=new URL('./',import.meta.url);
function verify(worker,repair=false) {
  return new Promise((resolve,reject)=>{
    const channel=new MessageChannel(),timer=setTimeout(()=>{channel.port1.close();reject(new Error('Offline verification timed out.'));},30000);
    channel.port1.onmessage=({data})=>{clearTimeout(timer);channel.port1.close();data.ok?resolve(data):reject(new Error(data.error));};
    worker.postMessage({type:repair?'REPAIR_OFFLINE':'VERIFY_OFFLINE'},[channel.port2]);
  });
}
export async function offlineStatus() {
  if(!('serviceWorker' in navigator)) return {label:'Offline installation is unavailable in this browser.'};
  const reg=await navigator.serviceWorker.getRegistration(base.href);
  if(!reg?.active) return {label:'Not prepared for offline use'};
  const status=await verify(reg.active);
  return {...status,label:reg.waiting?'Ready offline · update prepared; close all Roclet tabs and reopen to update':'Ready offline'};
}
export async function prepareOffline() {
  if(!('serviceWorker' in navigator) || !isSecureContext) throw new Error('Offline installation needs HTTPS or localhost and a browser with service workers.');
  const reg=await navigator.serviceWorker.register(new URL('offline-worker.mjs',base),{type:'module',scope:base.href,updateViaCache:'none'});
  // register() may return the existing registration without fetching an update.
  // Do not update during the initial install (it has no active worker yet).
  if(reg.active && !reg.installing) await reg.update();
  const worker=reg.installing;
  if(worker) await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error('Offline preparation timed out. The previous installation is still available.')),60000);
    const changed=()=>{if(['installed','activated'].includes(worker.state)) {clearTimeout(timer);resolve();}else if(worker.state==='redundant') {clearTimeout(timer);reject(new Error('Offline preparation failed (network, storage, or asset integrity). The previous installation is unchanged.'));}};
    worker.addEventListener('statechange',changed);changed();
  });
  const candidate=reg.waiting??reg.active;
  if(!candidate) throw new Error('Offline installation did not complete.');
  const status=await verify(candidate,true);
  return {...status,label:reg.waiting?'Update prepared · close all Roclet tabs and reopen to update':'Ready offline · reopen this same address without a network connection'};
}
export async function storageStatus(request=false) {
  const persistent=request?await navigator.storage?.persist?.():await navigator.storage?.persisted?.();
  const estimate=await navigator.storage?.estimate?.();
  const mb=n=>`${(n/1048576).toFixed(1)} MB`;
  return `${persistent?'Persistent storage granted':'Browser storage may be evicted'}${estimate?` · ${mb(estimate.usage??0)} used of ${mb(estimate.quota??0)}`:''}`;
}
