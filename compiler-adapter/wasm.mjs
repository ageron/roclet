const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

export async function createWasmTransport(bytes) {
  // js_echo is an upstream ABI import, but the embedding observer must capture it.
  const instantiated = await WebAssembly.instantiate(bytes, { env: { js_echo() { throw new Error('Uncaptured output'); } } });
  const instance = instantiated.instance ?? instantiated;
  const wasm = instance.exports;
  const allocate = bytes => {
    const ptr = wasm.roclet_alloc(Math.max(1, bytes.length)) >>> 0;
    if (!ptr) throw new Error('Compiler allocation failed');
    new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  };
  const readResponse = ptr => {
    ptr >>>= 0;
    if (!ptr) throw new Error('Compiler failed to allocate a response');
    try {
      const length = new DataView(wasm.memory.buffer).getUint32(ptr, true);
      return new Uint8Array(wasm.memory.buffer, ptr + 4, length).slice();
    } finally { wasm.roclet_free_response(ptr); }
  };
  const withBytes = (bytes, run) => {
    const ptr = allocate(bytes);
    try { return run(ptr, bytes.length); }
    finally { wasm.roclet_free(ptr, Math.max(1, bytes.length)); }
  };
  let previousGraph;
  const transport = request => {
    // The compiler owns its previous dependency graph. Preserve callers' explicit
    // alternatives, but do not serialize the same baseline graph on each edit.
    if(transport.workspace && request.operation==='document' && previousGraph && request.reactivity) {
      const {previous,current,...reactivity}=request.reactivity;
      const placeholder=current?.context==='' && current.scope==='module' && current.definitions?.length===0;
      if(previous && JSON.stringify(previous)===previousGraph && (!current || placeholder || JSON.stringify(current)===previousGraph)) request={...request,reactivity};
    }
    const bytes = encoder.encode(JSON.stringify(request));
    transport.lastRequestBytes=bytes.length;
    // WASM i32 exports are signed in JS; linear-memory addresses are unsigned.
    const ptr = wasm.roclet_alloc(bytes.length) >>> 0;
    if (!ptr) throw new Error('Compiler allocation failed');
    let response = 0;
    try {
      new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
      response = wasm.roclet_process(ptr, bytes.length) >>> 0;
      if (!response) throw new Error('Compiler failed to allocate a response');
      // Calls may grow memory: never retain a typed view across a WASM call.
      const length = new DataView(wasm.memory.buffer).getUint32(response, true);
      transport.lastResponseBytes=length;
      const result=JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, response + 4, length)));
      if(result.graph && ['ok','partial'].includes(result.status)) previousGraph=JSON.stringify(result.graph);
      return result;
    } finally {
      if (response) wasm.roclet_free_response(response);
      wasm.roclet_free(ptr, bytes.length);
    }
  };
  transport.workspace = typeof wasm.roclet_file_put === 'function';
  if (transport.workspace) {
    transport.putFile = (path, bytes) => withBytes(encoder.encode(path), (pathPtr, pathLen) =>
      withBytes(typeof bytes === 'string' ? encoder.encode(bytes) : bytes, (ptr, len) => {
        if (wasm.roclet_file_put(pathPtr, pathLen, ptr, len) !== 1) throw new Error(`Cannot mount compiler file: ${path}`);
      }));
    transport.dropFile = path => withBytes(encoder.encode(path), (ptr, len) => {
      if (wasm.roclet_file_drop(ptr, len) !== 1) throw new Error(`Cannot remove compiler file: ${path}`);
    });
    transport.cacheIdentity = () => decoder.decode(readResponse(wasm.roclet_cache_identity()));
    transport.importCache = bytes => withBytes(bytes, (ptr, len) => wasm.roclet_cache_import(ptr, len) === 1);
    transport.takeCacheUpdates = () => readResponse(wasm.roclet_cache_take_updates());
    transport.cacheStats = () => JSON.parse(decoder.decode(readResponse(wasm.roclet_cache_stats())));
    transport.installPackage = (url, bytes) => withBytes(encoder.encode(url), (urlPtr, urlLen) =>
      withBytes(bytes, (ptr, len) => wasm.roclet_package_install(urlPtr, urlLen, ptr, len) === 1));
  }
  return transport;
}
