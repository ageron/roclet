import { BrowserSession } from './session.mjs';
const $ = id => document.getElementById(id);
let session, revision = 0;
try {
  const [fixture, bytes] = await Promise.all([
    fetch('../fixtures/debug.json').then(response => response.json()),
    fetch('../artifacts/roclet.wasm').then(response => { if (!response.ok) throw new Error('Build the adapter first'); return response.arrayBuffer(); }),
  ]);
  $('fixture').value = JSON.stringify(fixture, null, 2);
  session = new BrowserSession(bytes);
  $('run').disabled = false;
  $('status').textContent = 'Ready. Roc runs locally in a browser worker.';
} catch (error) { $('status').textContent = error.message; }
function clear() { $('outputs').replaceChildren(); $('details').textContent = ''; }
$('fixture').addEventListener('input', () => { session?.stop(); revision++; clear(); $('status').textContent = 'Edited — run to evaluate'; $('stop').disabled = true; });
$('run').onclick = async () => {
  clear();
  $('stop').disabled = false;
  const thisRevision = ++revision;
  try {
    const fixture = JSON.parse($('fixture').value);
    $('status').textContent = 'Checking and evaluating…';
    const result = await session.evaluate({ ...fixture, documentRevision: thisRevision, inputRevision: 0 });
    if (thisRevision !== revision) return;
    for (const event of result.events) {
      const pre = document.createElement('pre'); pre.className = 'debug';
      pre.textContent = `${event.kind} while evaluating ${event.root}: ${event.message}`;
      $('outputs').append(pre);
    }
    for (const value of result.values) {
      const pre = document.createElement('pre'); pre.textContent = `${value.root} = ${value.text}`; $('outputs').append(pre);
    }
    $('details').textContent = JSON.stringify(result, null, 2);
    $('status').textContent = result.status === 'ok' ? 'Complete' : `${result.status}: ${result.failure ?? 'See diagnostics'}`;
  } catch (error) { if (thisRevision === revision) $('status').textContent = error.message; }
  finally { if (thisRevision === revision) $('stop').disabled = true; }
};
$('stop').onclick = () => { revision++; session.stop(); clear(); $('status').textContent = 'Stopped — results cleared'; $('stop').disabled = true; };
