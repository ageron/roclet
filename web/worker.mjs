import { CompilerAdapter } from '../compiler-adapter/adapter.mjs';
import { createWasmTransport } from '../compiler-adapter/wasm.mjs';
let adapter;
self.onmessage = async ({ data }) => {
  try {
    if (data.type === 'initialize') {
      adapter = new CompilerAdapter(await createWasmTransport(data.bytes));
      self.postMessage({ type: 'ready' });
    } else if (data.type === 'evaluate') {
      if (!adapter) throw new Error('Worker has not initialized');
      self.postMessage({ type: 'result', result: await adapter.evaluate(data.snapshot) });
    }
  } catch (error) {
    self.postMessage({ type: 'error', message: String(error?.message ?? error) });
  }
};
