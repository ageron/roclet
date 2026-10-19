import { BrowserSession } from './session.mjs';
import { createWasmTransport } from '../compiler-adapter/wasm.mjs';
import { snapshot } from '../tests/fixtures.mjs';
import { assert, runTests } from '../tests/harness.mjs';
import '../tests/unit.test.mjs';
const log = document.getElementById('log');
const status = document.getElementById('status');
const report = message => { log.textContent += `${message}\n`; };
const semantic = result => Object.fromEntries(['protocol', 'status', 'definitions', 'values', 'events', 'diagnostics', 'failure'].filter(key => key in result).map(key => [key, result[key]]));
async function fetchChecked(url, mode = 'json') {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Missing ${url}; run zig build test first`);
  return response[mode]();
}
try {
  const units = await runTests(report);
  const [bytes, native, manifest] = await Promise.all([
    fetchChecked('../artifacts/roclet.wasm', 'arrayBuffer'),
    fetchChecked('../artifacts/native-conformance.json'),
    fetchChecked('../artifacts/manifest.json'),
  ]);
  assert.deepEqual(native.manifest, manifest);
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(value => value.toString(16).padStart(2, '0')).join('');
  assert.equal(hash, manifest.artifacts['roclet.wasm'].sha256);
  const session = new BrowserSession(bytes);
  let raw;
  let count = 0;
  for (const fixture of native.cases) {
    status.textContent = `Running ${fixture.name} — ${count} parity cases passed`;
    let result;
    if (fixture.raw) {
      raw ??= await createWasmTransport(bytes);
      result = await raw(fixture.snapshot);
    } else result = await session.evaluate(fixture.snapshot);
    assert.deepEqual(semantic(result), semantic(fixture.result));
    report(`PASS native/WASM parity: ${fixture.name}`);
    count++;
  }
  const good = snapshot({ cells: [{ key: 'x', source: 'old = 42\nout_1 = old' }], roots: ['out_1'] });
  const cancelled = session.evaluate(good).then(() => { throw new Error('Cancelled request completed'); }, error => assert.equal(error.name, 'AbortError'));
  session.stop();
  await cancelled;
  assert.equal(session.gate.result, null);
  assert.equal((await session.evaluate(good)).status, 'ok');
  const deleted = await session.evaluate({ ...good, documentRevision: 2, cells: [{ key: 'x', source: 'out_1 = old' }] });
  assert(deleted.status !== 'ok' && deleted.values.length === 0, 'Deleted name retained its old value');
  report('PASS real worker cancellation, restart, and deletion');
  const summary = { unitTests: units, parityCases: count, permutations: native.permutations, workerLifecycle: 'pass' };
  document.documentElement.dataset.summary = JSON.stringify(summary);
  status.textContent = `PASS — ${units} browser unit tests, ${count} native/WASM parity cases (${native.permutations} permutations), worker lifecycle`;
  document.documentElement.dataset.result = 'pass';
} catch (error) {
  status.textContent = 'FAIL';
  report(error.stack ?? error.message);
  document.documentElement.dataset.result = 'fail';
}
