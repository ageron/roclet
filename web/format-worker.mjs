import { createWasmTransport } from '../compiler-adapter/wasm.mjs';
let transport;
onmessage = async ({ data }) => {
  try {
    transport ??= await createWasmTransport(data.bytes);
    const start = performance.now();
    const result = await transport(data.request);
    postMessage({ result, workerMs:performance.now()-start });
  } catch (error) { postMessage({ error: error.stack ?? error.message }); }
};
