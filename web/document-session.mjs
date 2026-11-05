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
  clearQueued() {
    this.queued?.reject(new DOMException("Superseded", "AbortError"));
    this.queued = null; clearTimeout(this.budgetTimer);
  }
  stop() {
    this.clearQueued();
    this.worker?.terminate();
    this.worker = null;
    this.files = new Map();
    this.pending?.controller.abort();
    this.pending?.reject(new DOMException('Stopped', 'AbortError'));
    this.pending = null;
  }
  invalidate() { if (this.pending) this.stop(); }
  request(request, options={}) {
    const snapshot=structuredClone(request);
    if(!options.queue) this.invalidate();
    if(!this.pending) return this.dispatch(snapshot,options);
    this.clearQueued();
    const result=new Promise((resolve,reject)=>{this.queued={snapshot,options,resolve,reject};});
    this.armBudget();
    return result;
  }
  armBudget() {
    clearTimeout(this.budgetTimer);
    if(!this.queued || !this.pending || this.waiting)return;
    const budget=Math.min(250,Math.max(100,4*(this.lastDuration??250)));
    const preempt=()=>{
      if(!this.queued || !this.pending || this.waiting) return;
      const next=this.queued;this.queued=null;
      this.stop();
      this.dispatch(next.snapshot,next.options).then(next.resolve,next.reject);
    };
    this.budgetTimer=setTimeout(preempt,Math.max(0,budget-(performance.now()-this.started)));
  }
  drain() {
    clearTimeout(this.budgetTimer);
    const next=this.queued;this.queued=null;
    if(next) this.dispatch(next.snapshot,next.options).then(next.resolve,next.reject);
  }
  dispatch(request,{loadPackage,onPackageWaiting,onPackageProgress,onDispatch}={}) {
    this.started=performance.now();this.waiting=false;
    onDispatch?.();
    const fresh = !this.worker;
    const worker = this.worker ??= new this.WorkerType(new URL('./format-worker.mjs', import.meta.url), { type: 'module' });
    let workspace;
    if(request.files || this.files?.size) {
      const changes=fileChanges(fresh?new Map():this.files??new Map(),request.files??[]);
      this.files=changes.next;workspace=changes.patch;
      request={...request};delete request.files;
    }
    return new Promise((resolve, reject) => {
      const controller=new AbortController();
      this.pending = { resolve, reject, controller };
      worker.onmessage = ({ data }) => {
        if (this.worker !== worker || this.pending?.resolve !== resolve) return;
        if(data.packageProgress) {onPackageProgress?.(data.packageProgress);return;}
        if(typeof data.packageDownloading==='boolean') {
          this.waiting=data.packageDownloading;
          if(this.waiting)clearTimeout(this.budgetTimer);
          else {this.started=performance.now();this.armBudget();}
          onPackageWaiting?.(this.waiting,{kind:'download'});
          return;
        }
        if(data.packageNeeded) {
          if(!loadPackage) {
            this.pending=null;this.stop();controller.abort();reject(new Error(`Cannot download Roc package ${data.packageNeeded.url}: ${data.packageNeeded.error}`));return;
          }
          this.waiting=true;clearTimeout(this.budgetTimer);
          onPackageWaiting?.(true);
          Promise.resolve().then(()=>loadPackage({...data.packageNeeded,signal:controller.signal})).then(bytes=>{
            if(this.worker!==worker || this.pending?.resolve!==resolve) return;
            this.waiting=false;this.started=performance.now();
            this.armBudget();onPackageWaiting?.(false);
            worker.postMessage({packageBundle:{bytes}},[bytes.buffer]);
          }).catch(error=>{
            if(this.worker!==worker || this.pending?.resolve!==resolve) return;
            this.pending=null;this.stop();controller.abort();reject(error);
          });
          return;
        }
        this.pending = null;
        controller.abort();
        if (data.error) {
          this.stop();
          const error=new Error(data.error);error.name=data.errorName??'Error';reject(error);
        } else {
          this.lastDuration=performance.now()-this.started;
          resolve({...data.result,workerMs:data.workerMs,...(data.transportMetrics?{transportMetrics:data.transportMetrics}:{})});
          this.drain();
        }
      };
      worker.onerror = error => {
        if (this.worker !== worker) return;
        this.pending = null;
        controller.abort();
        this.stop();
        reject(new Error(error.message));
      };
      const message={bytes:fresh?this.bytes:undefined,request,...(workspace?{workspace}:{})};
      if(fresh && this.WorkerType===globalThis.Worker) {
        // Structured cloning a compiled Module shares browser-managed code,
        // avoiding another copy of the compiler binary on every worker restart.
        // The post waits for compilation, so take the request's snapshot now.
        const owned=structuredClone({...message,bytes:undefined});
        prepareCompiler(this.bytes).then(prepared=>{
          if(this.worker===worker && this.pending?.resolve===resolve) worker.postMessage({...owned,...prepared});
        },error=>{
          if(this.worker!==worker || this.pending?.resolve!==resolve) return;
          this.pending=null;this.stop();reject(error);
        });
      } else worker.postMessage(message);
    });
  }
}
