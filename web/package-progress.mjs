export function packageLabel(url) {
  try {
    const parsed=new URL(url),parts=parsed.pathname.split('/');
    if(parsed.hostname==='github.com' && parts[3]==='releases' && parts[4]==='download')return `${parts[2]} ${parts[5]}`;
    return parsed.pathname.split('/').at(-1)||parsed.hostname;
  } catch {return 'package';}
}
function size(bytes) {
  return bytes<1024?`${bytes} B`:bytes<1024*1024?`${Math.round(bytes/1024)} KB`:`${(bytes/(1024*1024)).toFixed(1)} MB`;
}
export function packageProgressText(details) {
  const label=packageLabel(details.url);
  switch(details.phase) {
    case 'waiting':return `Waiting for ${label} from another notebook…`;
    case 'downloading': {
      const received=Number.isFinite(details.received)?details.received:0,total=Number.isFinite(details.total)&&details.total>=received?details.total:0;
      return `Downloading ${label}${received?` · ${size(received)}${total?` of ${size(total)}`:' received'}`:''}…`;
    }
    case 'verifying':return `Verifying ${label}…`;
    case 'retrying':return `Retrying ${label} · attempt ${details.attempt} of ${details.attempts}${details.waitMs?` in ${Math.ceil(details.waitMs/1000)} s`:''}…`;
    default:return `Loading ${label}…`;
  }
}
