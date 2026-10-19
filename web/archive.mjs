// Small ZIP32 writer/reader for portable documents. Exports use STORE, so no
// compression library is needed. Imports also accept DEFLATE when the browser
// provides DecompressionStream. Paths are never used for filesystem extraction.
const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
export const utf8=value=>encoder.encode(value);
export const text=bytes=>decoder.decode(bytes);
export function safePath(path) {
  return typeof path==='string' && path.length>0 && path.length<512 && !/[\\\x00-\x1f\x7f:]/.test(path) && path.split('/').every(p=>p && p!=='.' && p!=='..');
}
export function crc32(bytes) {let crc=0xffffffff;for(const byte of bytes) {crc^=byte;for(let bit=0;bit<8;bit++) crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
const header=n=>{const bytes=new Uint8Array(n);return {bytes,view:new DataView(bytes.buffer)};};
export function zip(files) {
  const parts=[],directory=[];let offset=0;
  for(const [name,input] of files) {
    if(!safePath(name)) throw new Error('Invalid archive path.');
    const body=typeof input==='string'?utf8(input):new Uint8Array(input),path=utf8(name),crc=crc32(body),local=header(30),central=header(46);
    const l=local.view,c=central.view;
    l.setUint32(0,0x04034b50,true);l.setUint16(4,20,true);l.setUint16(6,0x800,true);l.setUint32(14,crc,true);l.setUint32(18,body.length,true);l.setUint32(22,body.length,true);l.setUint16(26,path.length,true);
    c.setUint32(0,0x02014b50,true);c.setUint16(4,20,true);c.setUint16(6,20,true);c.setUint16(8,0x800,true);c.setUint32(16,crc,true);c.setUint32(20,body.length,true);c.setUint32(24,body.length,true);c.setUint16(28,path.length,true);c.setUint32(42,offset,true);
    parts.push(local.bytes,path,body);directory.push(central.bytes,path);offset+=30+path.length+body.length;
  }
  if(files.size>2048 || offset>128*1024*1024) throw new Error('Archive exceeds the supported size.');
  const size=directory.reduce((n,p)=>n+p.length,0),end=header(22);end.view.setUint32(0,0x06054b50,true);end.view.setUint16(8,files.size,true);end.view.setUint16(10,files.size,true);end.view.setUint32(12,size,true);end.view.setUint32(16,offset,true);
  return new Blob([...parts,...directory,end.bytes],{type:'application/zip'});
}
export async function unzip(input,{maxBytes=8*1024*1024,maxEntries=256}={}) {
  const bytes=new Uint8Array(input);if(bytes.length>maxBytes) throw new Error('Bundle exceeds the supported size.');
  const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),u16=p=>d.getUint16(p,true),u32=p=>d.getUint32(p,true);
  let end=-1;for(let p=bytes.length-22;p>=Math.max(0,bytes.length-65557);p--) if(u32(p)===0x06054b50 && p+22+u16(p+20)===bytes.length) {end=p;break;}
  if(end<0 || u16(end+4)!==0 || u16(end+6)!==0 || u16(end+8)!==u16(end+10)) throw new Error('Invalid or unsupported ZIP directory.');
  const count=u16(end+10),start=u32(end+16),size=u32(end+12);
  if(count>maxEntries || start+size!==end) throw new Error('Invalid or oversized ZIP directory.');
  const files=new Map(),ranges=[];let at=start,total=0;
  for(let i=0;i<count;i++) {
    if(at+46>end || u32(at)!==0x02014b50) throw new Error('Malformed ZIP entry.');
    const flags=u16(at+8),method=u16(at+10),crc=u32(at+16),packed=u32(at+20),length=u32(at+24),nameLength=u16(at+28),extra=u16(at+30),comment=u16(at+32),local=u32(at+42);
    const next=at+46+nameLength+extra+comment;
    if(next>end || flags&~0x808 || ![0,8].includes(method) || u16(at+34)!==0) throw new Error('Unsupported ZIP entry.');
    const name=text(bytes.subarray(at+46,at+46+nameLength));
    if(!safePath(name) || files.has(name)) throw new Error('Unsafe or duplicate ZIP path.');
    total+=length;if(total>maxBytes || local+30>start || u32(local)!==0x04034b50) throw new Error('Invalid or oversized ZIP entry.');
    const body=local+30+u16(local+26)+u16(local+28),finish=body+packed;
    if(finish>start || u16(local+8)!==method || u16(local+6)!==flags || text(bytes.subarray(local+30,local+30+u16(local+26)))!==name || ranges.some(([a,b])=>local<b&&finish>a)) throw new Error('Inconsistent or overlapping ZIP entry.');
    if(!(flags&8) && (u32(local+14)!==crc || u32(local+18)!==packed || u32(local+22)!==length)) throw new Error('Inconsistent ZIP sizes.');
    ranges.push([local,finish]);let decoded=bytes.slice(body,finish);
    if(method===8) {
      let stream;try {stream=new Blob([decoded]).stream().pipeThrough(new DecompressionStream('deflate-raw'));}catch {throw new Error('This browser cannot open compressed ZIPs. Export a bundle from Roclet.');}
      const reader=stream.getReader(),chunks=[];let written=0;
      while(true) {const {done,value}=await reader.read();if(done) break;written+=value.length;if(written>length) {await reader.cancel();throw new Error('ZIP decompression exceeds its declared size.');}chunks.push(value);}
      decoded=new Uint8Array(written);let p=0;for(const chunk of chunks) {decoded.set(chunk,p);p+=chunk.length;}
    }
    if(decoded.length!==length || crc32(decoded)!==crc) throw new Error(`Corrupt ZIP entry: ${name}`);
    files.set(name,decoded);at=next;
  }
  if(at!==end) throw new Error('Trailing ZIP directory data.');return files;
}
