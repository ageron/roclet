import {projectPath} from './project-files.mjs';
import {sha256} from './offline-cache.mjs';

export const attachmentLimit = 16 * 1024 * 1024;
export const bundleLimit = 40 * 1024 * 1024;
export function attachmentRelativePath(path) {
  projectPath(path);
  // File import paths in the pinned compiler are literal StringPart tokens;
  // escaped quotes and interpolation cannot identify the original filename.
  if(path.includes('"') || path.includes('${')) throw new Error('Choose an attachment path without double quotes or ${.');
  return path;
}
// Validate names, sizes and hashes before a bundle importer allocates Blobs or
// reads their contents. Untrusted metadata may repeat a large member many times.
export function attachmentMetadata(files = [], sources = []) {
  if (!Array.isArray(files) || files.length > 128) throw new Error('A notebook supports up to 128 attachments.');
  const paths = new Set(sources.map(file => file.path));
  let size = 0;
  return files.map(file => {
    const path = attachmentRelativePath(file?.path);
    if (paths.has(path)) throw new Error(`“${path}” is already used. Choose a different attachment path.`);
    if ([...paths].some(other=>other.startsWith(`${path}/`) || path.startsWith(`${other}/`))) throw new Error(`“${path}” overlaps another file path. Choose a different path.`);
    if (!Number.isSafeInteger(file.size) || file.size<0 || !/^[a-f0-9]{64}$/.test(file.sha256)
      || typeof file.mime!=='string' || file.mime.length>256) throw new Error('Malformed attachment.');
    paths.add(path); size += file.size;
    if (size > attachmentLimit) throw new Error('Attachments exceed the 16 MiB limit for this notebook.');
    return {path, size:file.size, mime:file.mime, sha256:file.sha256};
  });
}
// Blobs are immutable: cloning a draft or undo entry keeps the file data out of
// source JSON and does not duplicate a mutable byte array on every keystroke.
export function attachments(files = [], sources = []) {
  if (!Array.isArray(files) || files.length>128) throw new Error('A notebook supports up to 128 attachments.');
  attachmentMetadata(files.map(file=>{
    if (!(file?.blob instanceof Blob)) throw new Error('Malformed attachment.');
    return {path:file.path,size:file.blob.size,mime:file.blob.type,sha256:file.sha256};
  }),sources);
  return files.map(({path,blob,sha256})=>({path,blob,sha256}));
}
// Reuse immutable backing data when the same contents are imported again,
// including contents still reachable through undo/redo. A MIME change only
// needs a new Blob view, not another copy of the bytes.
export function shareAttachmentBlobs(files, records) {
  const blobs=new Map();
  for(const record of records) for(const file of record.attachments??[]) if(!blobs.has(file.sha256)) blobs.set(file.sha256,file.blob);
  return files.map(file=>{
    const existing=blobs.get(file.sha256);
    if(!existing) {blobs.set(file.sha256,file.blob);return file;}
    return {...file,blob:existing.type===file.blob.type?existing:existing.slice(0,existing.size,file.blob.type)};
  });
}
export const attachmentHistoryLimit = 64 * 1024 * 1024;
// JSON history bounds cannot see Blob contents. Keep the newest undo entries
// whose distinct attachment data, together with the current revision, fits.
export function trimAttachmentHistory(history, current, limit=attachmentHistoryLimit) {
  const seen=new Set();let size=0;
  const include=record=>{for(const file of record.attachments??[]) if(!seen.has(file.sha256)) {seen.add(file.sha256);size+=file.blob.size;}};
  include(current);
  for(let index=history.length-1;index>=0;index--) {
    include(history[index]);
    if(size>limit) {history.splice(0,index+1);break;}
  }
}
export async function attachment(path, blob) {
  if (!(blob instanceof Blob)) throw new Error('Choose a file to attach.');
  attachmentMetadata([{path,size:blob.size,mime:blob.type,sha256:'0'.repeat(64)}]);
  // Copy the selected File into a Blob snapshot; future changes to the file on
  // disk never change the notebook's data implicitly.
  const bytes = await blob.arrayBuffer();
  return {path, blob: new Blob([bytes], {type: blob.type}), sha256: await sha256(bytes)};
}
export const attachmentPath = file => `data/${file.webkitRelativePath || file.name}`.replaceAll('"','_').replaceAll('${','_');
export const fileSize = size => size < 1024 ? `${size} B` : size < 1024 * 1024 ? `${(size / 1024).toFixed(1)} KiB` : `${(size / (1024 * 1024)).toFixed(1)} MiB`;
export async function attachmentPreview(file) {
  const bytes = new Uint8Array(await file.blob.slice(0, 4096).arrayBuffer());
  try {
    // stream:true tolerates a UTF-8 character split by the preview boundary.
    const text = new TextDecoder('utf-8', {fatal:true}).decode(bytes, {stream:file.blob.size > bytes.length});
    if (!/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(text)) return {kind:'text', text, truncated:file.blob.size > bytes.length};
  } catch { /* Binary data gets a bounded hex preview. */ }
  const lines=[];
  for(let offset=0;offset<Math.min(bytes.length,256);offset+=16) lines.push(`${offset.toString(16).padStart(4,'0')}  ${[...bytes.slice(offset,offset+16)].map(byte=>byte.toString(16).padStart(2,'0')).join(' ')}`);
  return {kind:'bytes', text:lines.join('\n'), truncated:file.blob.size > 256};
}
