import { RevisionGate } from '../compiler-adapter/adapter.mjs';

/** One worker per active evaluation. Termination is the cancellation boundary. */
export class BrowserSession {
  generation = 0;
  sequence = 0;
  gate = new RevisionGate();
  worker = null;
  pending = null;
  constructor(bytes, WorkerClass = Worker) {
    this.bytes = bytes;
    this.WorkerClass = WorkerClass;
  }
  stop() {
    this.worker?.terminate();
    this.worker = null;
    this.generation++;
    this.gate.invalidate();
    this.pending?.reject(new DOMException('Evaluation cancelled', 'AbortError'));
    this.pending = null;
  }
  evaluate(snapshot) {
    this.stop();
    const request = structuredClone({ ...snapshot, requestId: `browser-${++this.sequence}`, workerGeneration: this.generation });
    this.gate.begin(request);
    const worker = new this.WorkerClass(new URL('./worker.mjs', import.meta.url), { type: 'module' });
    this.worker = worker;
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      const fail = message => {
        if (this.worker !== worker) return;
        this.pending = null;
        this.stop();
        reject(new Error(message));
      };
      worker.onerror = event => fail(event.message);
      worker.onmessage = ({ data }) => {
        if (this.worker !== worker) return;
        if (data.type === 'ready') worker.postMessage({ type: 'evaluate', snapshot: request });
        if (data.type === 'error') fail(data.message);
        if (data.type === 'result' && this.gate.accept(data.result)) {
          this.pending = null;
          worker.terminate();
          this.worker = null;
          resolve(data.result);
        }
      };
      worker.postMessage({ type: 'initialize', bytes: this.bytes });
    });
  }
}
