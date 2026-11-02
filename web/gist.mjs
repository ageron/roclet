import {openedDraft} from './edit-model.mjs';
import {projectFiles} from './project-files.mjs';
import {attachment, attachments} from './attachments.mjs';

const encoder = new TextEncoder();
const hex = /^[a-f0-9]{5,40}$/i;
// Accept only gist identifiers and GitHub's canonical Gist page URLs.
export function gistReference(value) {
  const input = String(value ?? '').trim();
  if (hex.test(input)) return {id:input};
  let url;
  try { url = new URL(input); } catch { /* Report the same helpful error below. */ }
  if (url?.protocol === 'https:' && url.hostname === 'gist.github.com' && !url.port && !url.username && !url.password) {
    const parts = url.pathname.replace(/\/$/, '').split('/').slice(1);
    const offset = parts.length >= 2 ? 1 : 0;
    const id = parts[offset], revision = parts[offset + 1];
    if (hex.test(id ?? '') && parts.length <= offset + 2 && (!revision || /^[a-f0-9]{40}$/i.test(revision))) return {id, ...(revision ? {revision} : {})};
  }
  throw new Error('Enter a GitHub Gist URL or Gist ID, optionally with a revision in the URL.');
}

// Bound the response before JSON parsing, including metadata and escaped text.
async function gistJSON(response) {
  const reader = response.body.getReader(), chunks = [];
  let size = 0;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 40 * 1024 * 1024) throw new Error('This Gist is too large to import.');
      chunks.push(value);
    }
  } finally { await reader.cancel(); reader.releaseLock(); }
  return JSON.parse(await new Blob(chunks).text());
}

export async function loadGist(value, {filename, fetch:request = globalThis.fetch} = {}) {
  const {id, revision} = gistReference(value);
  const response = await request(`https://api.github.com/gists/${id}${revision ? `/${revision}` : ''}`, {
    credentials:'omit', headers:{Accept:'application/vnd.github+json'}, signal:AbortSignal.timeout(30000),
  });
  if (!response.ok) {
    if (response.status === 403 || response.status === 429) throw new Error('GitHub refused the request or its API rate limit was reached. Try again later.');
    if (response.status === 404) throw new Error('Gist or revision not found. Check the link.');
    throw new Error(`GitHub could not load this Gist (HTTP ${response.status}).`);
  }
  const gist = await gistJSON(response);
  if (gist.truncated || !gist.files || typeof gist.files !== 'object' || Array.isArray(gist.files)) throw new Error('GitHub returned an incomplete Gist.');
  const files = Object.entries(gist.files).map(([path, file]) => {
    if (file?.truncated || typeof file?.content !== 'string') throw new Error(`GitHub did not return the full contents of “${path}”. Use smaller files or a Roclet bundle.`);
    return {path, source:file.content};
  });
  if (files.length > 256) throw new Error('A Gist supports up to 256 imported files.');
  let main;
  if (filename) main = files.find(file => file.path === filename && /\.(roc|md)$/i.test(file.path));
  else {
    for (const name of ['notebook.roc', 'notebook.md', 'Main.roc', 'main.roc']) {
      main = files.find(file => file.path === name);
      if (main) break;
    }
    if (!main) {
      const candidates = files.filter(file => /\.(roc|md)$/i.test(file.path));
      if (candidates.length === 1) [main] = candidates;
    }
  }
  if (!main) throw new Error('Choose a .roc or .md notebook using gistFile in the link, or name it notebook.roc or notebook.md.');
  if (encoder.encode(main.source).length > 256 * 1024) throw new Error('Roclet notebooks are limited to 256 KiB.');
  const record = openedDraft(main.source, main.path);
  const supporting = files.filter(file => file !== main);
  record.files = projectFiles(supporting.filter(file => /\.roc$/i.test(file.path)));
  // Validate all paths and aggregate attachment size before copying their data.
  const data = supporting.filter(file => !/\.roc$/i.test(file.path));
  const blobs = data.map(file => ({path:file.path, blob:new Blob([file.source], {type:'text/plain;charset=utf-8'}), sha256:'0'.repeat(64)}));
  attachments(blobs, record.files);
  record.attachments = await Promise.all(blobs.map(file => attachment(file.path, file.blob)));
  record.autoRun = false;
  return record;
}
