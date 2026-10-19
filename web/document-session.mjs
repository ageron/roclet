import {fileChanges} from './workspace.mjs';
const compiledModules=new WeakMap();
function prepareCompiler(bytes) {
  let prepared=compiledModules.get(bytes);
  if(!prepared) {
    prepared=Promise.all([WebAssembly.compile(bytes),crypto.subtle.digest('SHA-256',bytes)]).then(([module,hash])=>({module,compilerDigest:[...new Uint8Array(hash)].map(b=>b.toString(16).padStart(2,'0')).join('')}));
    compiledModules.set(bytes,prepared);
  }
  return prepared;
}
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
    this.files = new Map();
    this.graph = null;
    this.engineBaseline = false;
    this.pending?.reject(new DOMException('Stopped', 'AbortError'));
    this.pending = null;
  }
  invalidate() { if (this.pending) this.stop(); }
  request(request) {
    this.invalidate();
    const fresh = !this.worker;
    const worker = this.worker ??= new this.WorkerType(new URL('./format-worker.mjs', import.meta.url), { type: 'module' });
    let workspace;
    if(request.files || this.files?.size) {
      const changes=fileChanges(fresh?new Map():this.files??new Map(),request.files??[]);
      this.files=changes.next;workspace=changes.patch;
      request={...request};delete request.files;
    }
    if(!fresh && this.engineBaseline && this.graph && request.reactivity) {
      const {previous,current,...reactivity}=request.reactivity;
      const placeholder=current?.context==='' && current.scope==='module' && current.definitions?.length===0;
      if(previous && JSON.stringify(previous)===this.graph && (!current || placeholder || JSON.stringify(current)===this.graph)) request={...request,reactivity};
    }
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      worker.onmessage = ({ data }) => {
        if (this.worker !== worker || this.pending?.resolve !== resolve) return;
        this.pending = null;
        if (data.error) {
          this.stop();
          reject(new Error(data.error));
        } else {
          this.engineBaseline=!!data.result.workspaceCache;
          if(data.result.graph && ['ok','partial'].includes(data.result.status)) this.graph=JSON.stringify(data.result.graph);
          resolve({...data.result,workerMs:data.workerMs,...(data.transportMetrics?{transportMetrics:data.transportMetrics}:{})});
        }
      };
      worker.onerror = error => {
        if (this.worker !== worker) return;
        this.pending = null;
        this.stop();
        reject(new Error(error.message));
      };
      const message={bytes:fresh?this.bytes:undefined,request,...(workspace?{workspace}:{})};
      if(fresh && this.WorkerType===globalThis.Worker) {
        // Structured cloning a compiled Module shares browser-managed code,
        // avoiding another copy of the compiler binary on every worker restart.
        prepareCompiler(this.bytes).then(prepared=>{
          if(this.worker===worker && this.pending?.resolve===resolve) worker.postMessage({...message,bytes:undefined,...prepared});
        },error=>{
          if(this.worker!==worker || this.pending?.resolve!==resolve) return;
          this.pending=null;this.stop();reject(error);
        });
      } else worker.postMessage(message);
    });
  }
}
