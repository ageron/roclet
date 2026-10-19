const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

export async function createWasmTransport(bytes) {
  // js_echo is an upstream ABI import, but the embedding observer must capture it.
  const { instance } = await WebAssembly.instantiate(bytes, { env: { js_echo() { throw new Error('Uncaptured output'); } } });
  const wasm = instance.exports;
  return request => {
    const bytes = encoder.encode(JSON.stringify(request));
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
      return JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, response + 4, length)));
    } finally {
      if (response) wasm.roclet_free_response(response);
      wasm.roclet_free(ptr, bytes.length);
    }
  };
}
