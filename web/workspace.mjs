// The editor owns a desired file set. Only changes cross into the worker and
// WASM; compiler filesystem/cache state survives successful requests.
export function workspacePath(path) {
  if(typeof path!=='string' || !path.startsWith('/workspace/') || path.length>4096 || /[\\\u0000-\u001f\u007f]/u.test(path) || path.split('/').slice(1).some(p=>!p||p==='..'||p==='.')) throw new Error('Project files require an absolute /workspace/ path');
  if(path==='/workspace/Main.roc' || path==='/workspace/main.roc') throw new Error('Main.roc is generated from the notebook');
  return path;
}
export function fileChanges(previous,files) {
  const next=new Map(),put=[],drop=[];
  for(const file of files) {
    const path=workspacePath(file.path);
    const binary=file.blob instanceof Blob && /^[a-f0-9]{64}$/.test(file.sha256);
    if(next.has(path) || (!binary && typeof file.source!=='string')) throw new Error('Invalid or duplicate workspace file');
    const identity=binary?`blob:${file.sha256}`:`text:${file.source}`;
    next.set(path,identity);
    if(previous.get(path)!==identity) put.push(binary?{path,blob:file.blob}:{path,source:file.source});
  }
  for(const path of previous.keys()) if(!next.has(path)) drop.push(path);
  return {next,patch:{put,drop}};
}
export function mountChanges(transport,patch) {
  if(!patch || (!patch.put.length && !patch.drop.length)) return;
  if(!transport.workspace) throw new Error('Rebuild the compiler adapter to enable workspace modules');
  for(const path of patch.drop) transport.dropFile(workspacePath(path));
  for(const file of patch.put) transport.putFile(workspacePath(file.path),file.bytes??file.source);
}
