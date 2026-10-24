export const validInputKey = key => typeof key==='string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(key);
export function inputValues(raw={}) {
  if(!raw || typeof raw!=='object' || Array.isArray(raw) || Object.keys(raw).length>128) throw new Error('Malformed notebook inputs.');
  const entries=Object.entries(raw);
  if(entries.some(([key,value])=>!validInputKey(key) || typeof value!=='number' || !Number.isFinite(value))) throw new Error('Malformed notebook input value.');
  return Object.fromEntries(entries);
}
export function inputModule(raw) {
  const entries=Object.entries(inputValues(raw)).sort(([a],[b])=>a.localeCompare(b));
  const number=n=>Number.isInteger(n) && !String(n).includes('e')?`${n}.0`:String(n);
  const body=entries.reduceRight((rest,[key,value])=>`if key == "${key}" { ${number(value)} } else { ${rest} }`,'default');
  return {name:'InputValues',content:`InputValues := [].{\n    get : Str, F64 -> F64\n    get = |${entries.length?'key':'_key'}, default| ${body}\n}\n`};
}
export function sliderConfig(content, custom=false) {
  try {
    if(typeof content!=='string' || content.length>(custom?131072:4096)) return null;
    const c=JSON.parse(content);
    if(custom) {
      if(typeof c.html!=='string' || new TextEncoder().encode(c.html).length>16384) return null;
      c.step=1;
    }
    for(const key of ['min','max','step','default','value']) {
      if(typeof c[key]==='string' && /^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/.test(c[key])) c[key]=Number(c[key]);
    }
    if(!validInputKey(c.key) || typeof c.label!=='string' || c.label.length>256 ||
      !['min','max','step','default','value'].every(k=>typeof c[k]==='number' && Number.isFinite(c[k])) ||
      c.min>=c.max || c.step<=0 || c.default<c.min || c.default>c.max || c.value<c.min || c.value>c.max) return null;
    return c;
  } catch {return null;}
}
