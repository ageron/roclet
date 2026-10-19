// Owns editing views and the worker, never caches user evaluation results.
export class DocumentDraft {
  constructor(source, format = 'roc') { this.open(source, format); }
  open(source, format) {
    this.source = source;
    this.format = format;
    this.context = null;
    this.views = new Map([[format, { source, context: null }]]);
  }
  edit(source) {
    this.source = source;
    this.views = new Map([[this.format, { source, context: this.context }]]);
  }
  request(action, target = this.format) {
    return { operation: 'document', action, format: this.format, target, source: this.source,
      ...(this.format === 'markdown' && this.context ? { context: this.context } : {}) };
  }
  restore(format) {
    const view = this.views.get(format);
    if (!view) return false;
    this.format = format;
    this.source = view.source;
    this.context = view.context;
    return true;
  }
  converted(format, result) {
    if (result.status !== 'ok') return false;
    this.format = format;
    this.source = result.source;
    this.context = { preamble: result.model.preamble, metadata: result.model.metadata };
    this.views.set(format, { source: this.source, context: this.context });
    return true;
  }
}

export class DocumentSession {
  constructor(bytes, WorkerType = Worker) { this.bytes = bytes; this.WorkerType = WorkerType; }
  stop() {
    this.worker?.terminate();
    this.worker = null;
    this.pending?.reject(new DOMException('Stopped', 'AbortError'));
    this.pending = null;
  }
  invalidate() { if (this.pending) this.stop(); }
  request(request) {
    this.invalidate();
    const fresh = !this.worker;
    const worker = this.worker ??= new this.WorkerType('./format-worker.mjs', { type: 'module' });
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      worker.onmessage = ({ data }) => {
        if (this.worker !== worker || this.pending?.resolve !== resolve) return;
        this.pending = null;
        if (data.error) {
          this.stop();
          reject(new Error(data.error));
        } else resolve({...data.result,workerMs:data.workerMs});
      };
      worker.onerror = error => {
        if (this.worker !== worker) return;
        this.pending = null;
        this.stop();
        reject(new Error(error.message));
      };
      worker.postMessage({ bytes: fresh ? this.bytes : undefined, request });
    });
  }
}
