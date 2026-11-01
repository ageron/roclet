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
// Blobs are immutable: cloning a draft or undo entry keeps the file data out of
// source JSON and does not duplicate a mutable byte array on every keystroke.
export function attachments(files = [], sources = []) {
  if (!Array.isArray(files) || files.length > 128) throw new Error('A notebook supports up to 128 attachments.');
  const paths = new Set(sources.map(file => file.path));
  let size = 0;
  return files.map(file => {
    const path = attachmentRelativePath(file?.path);
    if (paths.has(path)) throw new Error(`“${path}” is already used. Choose a different attachment path.`);
    if ([...paths].some(other=>other.startsWith(`${path}/`) || path.startsWith(`${other}/`))) throw new Error(`“${path}” overlaps another file path. Choose a different path.`);
    if (!(file.blob instanceof Blob) || !/^[a-f0-9]{64}$/.test(file.sha256)) throw new Error('Malformed attachment.');
    paths.add(path); size += file.blob.size;
    if (size > attachmentLimit) throw new Error('Attachments exceed the 16 MiB limit for this notebook.');
    return {path, blob: file.blob, sha256: file.sha256};
  });
}
export async function attachment(path, blob) {
  attachmentRelativePath(path);
  if (!(blob instanceof Blob)) throw new Error('Choose a file to attach.');
  if (blob.size > attachmentLimit) throw new Error('This file exceeds the 16 MiB attachment limit.');
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
