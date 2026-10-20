import { DocumentSession } from './document-session.mjs';
import { renameEdits } from './compiler-tools.mjs';
import { projectFiles, projectPath } from './project-files.mjs';

const clone = value => structuredClone(value);
const key = () => crypto.randomUUID();
export const makeCell = (kind = 'code', source = '') => ({ key: key(), kind, source, attributes: '', outputs: [], collapsed: false });
export function newDraft(title = 'Untitled', demo = false) {
  const cells = demo ? [
    makeCell('markdown', '# Wall area\nChange the dimensions below. Both results update, wherever their cells are placed.'),
    makeCell('code', 'area'),
    makeCell('code', 'width = 5\nheight = 3'),
    makeCell('code', 'area = width * height\nout_dimensions = {\n    dbg area\n    area\n}'),
  ] : [makeCell()];
  return { schema: 1, id: key(), title, format: 'roc', preamble: 'app [main!] {}', metadata: '', cells,
    source: '', sourceCurrent: false, files: [], mode: 'notebook', revision: 1, autoRun: true, updatedAt: Date.now() };
}
export function validDraft(record) {
  try { projectFiles(record?.files); } catch { return false; }
  return record?.schema === 1 && typeof record.id === 'string' && typeof record.title === 'string'
    && ['roc', 'markdown'].includes(record.format) && typeof record.source === 'string'
    && Array.isArray(record.cells) && record.cells.every(c => typeof c.key === 'string' && typeof c.source === 'string' && ['code','markdown','generated'].includes(c.kind));
}
export function requestFor(state, action, target = state.format) {
  const request = { operation: 'document', action, format: state.format, target, source: state.sourceCurrent ? state.source : '', render: true };
  request.files = projectFiles(state.files).map(file => ({...file, path:`/workspace/${file.path}`}));
  if (state.sourceCurrent) request.context = { preamble: state.preamble, metadata: state.metadata };
  else request.draft = { preamble: state.preamble, metadata: state.metadata, cells: state.cells.map(({ kind, source, attributes, outputs }) => ({ kind, source, attributes, outputs })) };
  return request;
}
export function cellsFrom(result, previous = []) {
  return (result.draft?.cells ?? result.model.cells).map((cell, i) => ({ key: previous[i]?.key ?? key(), kind: cell.kind, source: cell.source,
    attributes: cell.attributes, outputs: cell.outputs, collapsed: previous[i]?.collapsed ?? false }));
}

// Presentation reuse only: these strings never enter compiler evaluation.
function mergeCheckedResults(previous, result, state) {
  if (!result.graph || !result.evaluation) return result;
  const reused = new Set(result.plan?.reused ?? []);
  const old = previous?.evaluation;
  const positions = new Map(result.model.cells.flatMap((cell, i) => [cell.output,...(cell.expectations ?? [])].map(root=>[root,i])));
  const values = [...(old?.values ?? []).filter(v => reused.has(v.root)), ...(result.evaluation.values ?? [])];
  values.sort((a,b) => positions.get(a.root) - positions.get(b.root));
  const events = [...(old?.events ?? []).filter(e => reused.has(e.root)), ...result.evaluation.events]
    .map(e => ({...e, cell:positions.get(e.root) ?? null})).sort((a,b) => (a.cell ?? -1) - (b.cell ?? -1));
  const tests = [...(old?.tests ?? []).filter(t=>reused.has(t.root)), ...(result.evaluation.tests ?? [])]
    .map(test=>{
      const cell=positions.get(test.root) ?? null;
      if(!reused.has(test.root)) return {...test,cell};
      // Reused statuses still use this revision's compiler-provided source map.
      const expectation=result.expectations?.find(e=>e.root===test.root);
      const mapping=result.mappings?.find(m=>m.cell===cell && m.generated_start<=expectation?.start && expectation.start<m.generated_end);
      if(!mapping) return {...test,cell};
      const absolute=mapping.source_start+expectation.start-mapping.generated_start;
      const raw=state.sourceCurrent, start=raw?absolute:absolute-result.model.cells[cell].body_start;
      const source=raw?state.source:result.model.cells[cell].source;
      const prefix=new TextDecoder().decode(new TextEncoder().encode(source).subarray(0,start));
      const lines=prefix.split('\n'),location={line:lines.length,column:new TextEncoder().encode(lines.at(-1)).length+1};
      return {...test,cell,start,end:start+expectation.end-expectation.start,location,scope:raw?'source':'cell'};
    });
  return {...result, evaluation:{...result.evaluation, values, tests, events:events.map((e,sequence) => ({...e,sequence}))}};
}

// Browser-owned edit history, persistence and worker lifecycle. Parsing, output
// selection, lowering and encoding are exclusively the shared Roc document core.
export class Notebook {
  constructor(bytes, store, { session = new DocumentSession(bytes), debounce = 550, timeout = 15000, onChange = () => {}, loadPackage } = {}) {
    this.store = store; this.session = session; this.debounce = debounce; this.timeout = timeout; this.onChange = onChange;
    this.loadPackage = loadPackage;
    this.state = null; this.result = null; this.history = []; this.future = []; this.views = new Map();
    this.diagnosticsDeferred = false; this.baseline = null;
    this.runId = 0; this.saveVersion = 0; this.status = 'Ready'; this.saveStatus = 'Not saved yet'; this.saveChain = Promise.resolve();
  }
  emit(reason = 'status') { this.onChange(reason); }
  async initialize({id = null, fresh = false} = {}) {
    let record;
    try { record = id ? await this.store.get(id) : fresh ? null : (await this.store.list()).find(validDraft); }
    catch (error) { this.saveStatus = `Browser storage unavailable: ${error.message}`; }
    if (id && !validDraft(record)) throw new Error('This notebook is unavailable in this browser. Return home to choose another.');
    this.state = record ? clone(record) : fresh ? newDraft() : newDraft('Wall area', true);
    this.status = record ? 'Recovered draft · results must be recomputed' : 'Ready';
    this.emit('document');
    await this.persist();
    this.schedule();
  }
  async persist() {
    const record = clone(this.state); record.updatedAt = Date.now();
    const revision = record.revision, id = record.id;
    const saveVersion = ++this.saveVersion;
    this.saveStatus = 'Saving in this browser…'; this.emit();
    const saved = this.saveChain.catch(() => {}).then(() => this.store.save(record));
    this.saveChain = saved;
    try {
      await saved;
      if (this.state.id === id && this.state.revision === revision && saveVersion === this.saveVersion) { this.saveStatus = 'Saved in this browser'; this.emit('saved'); }
      return true;
    } catch (error) {
      if (this.state.id === id && saveVersion === this.saveVersion) { this.saveStatus = `Not saved: ${error.message}. Download a copy.`; this.emit(); }
      return false;
    }
  }
  cancelPending() {
    clearTimeout(this.timer); this.timer = null; this.runId++; this.session.invalidate();
  }
  invalidate() {
    this.cancelPending();
    this.result = null; this.status = 'Changed · results need updating';
  }
  change(update, { group = null, source = false, composing = false, reason = 'document' } = {}) {
    const now = Date.now();
    if (!group || this.group !== group || now - this.groupAt > 800) this.history.push(clone(this.state));
    // Bound browser-only undo history without writing IDs into the source.
    while (this.history.length > 100 || (this.history.length > 1 && JSON.stringify(this.history).length > 4 * 1024 * 1024)) this.history.shift();
    this.group = group; this.groupAt = now; this.future = []; this.views.clear();
    this.invalidate(); update(this.state); delete this.state.savedResults; this.state.revision++; this.state.sourceCurrent = source;
    this.emit(reason); void this.persist();
    if (!composing) this.schedule();
  }
  editCell(index, source, composing = false, positions = null) {
    this.diagnosticsDeferred = true;
    this.change(s => { s.cells[index].source = source; s.cells[index].outputs = []; if (positions) s.cells[index].editorSelection = positions; }, { group: this.state.cells[index].key, composing, reason: 'edit' });
  }
  editPreamble(preamble, composing = false, positions = null) {
    this.diagnosticsDeferred = true;
    this.change(s => { s.preamble = preamble; if (positions) s.headerSelection = positions; }, { group: 'app-header', composing, reason: 'edit' });
  }
  editSource(source, composing = false, positions = null) {
    this.diagnosticsDeferred = true;
    this.change(s => { s.source = source; if (positions) s.editorSelection = positions; }, { group: 'raw', source: true, composing, reason: 'edit' });
  }
  setProjectFiles(files) {
    const checked = projectFiles(files);
    this.change(s => { s.files = checked; }, { source:this.state.sourceCurrent, reason:'project' });
  }
  setProjectFile(path, source) {
    projectPath(path);
    const files = (this.state.files ?? []).filter(file => file.path !== path);
    this.setProjectFiles([...files, {path,source}]);
  }
  removeProjectFile(path) {
    this.setProjectFiles((this.state.files ?? []).filter(file => file.path !== path));
  }
  schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(async () => {
      this.timer = null;
      if (this.state.autoRun) void this.run(undefined, { automatic: true });
      else void this.check();
    }, this.debounce);
  }
  finishEditing({ flush = true } = {}) {
    if (!this.diagnosticsDeferred) return;
    this.diagnosticsDeferred = false; this.emit('diagnostics');
    // Flush a pending debounce, but leave an already running check/evaluation
    // alone. Its revision guards still apply if typing resumes before it returns.
    if (flush && this.timer) {
      if (this.state.autoRun) void this.run(undefined, { automatic: true });
      else void this.check();
    }
  }
  reactiveRequest(action, selectedCell, forceAll = false) {
    const request = requestFor(this.state, action);
    request.compact = true;
    const previous = this.baseline?.id === this.state.id ? this.baseline.result : null;
    const roots = previous?.roots ?? [];
    // A forced cell is resolved against the *new* model in the adapter below.
    request.reactivity = {known:!!previous?.graph, previous:previous?.graph ?? {context:'',scope:'module',definitions:[]},
      current:{context:'',scope:'module',definitions:[]}, roots:[], available:[...(previous?.evaluation?.values ?? []),...(previous?.evaluation?.tests ?? []).filter(t=>t.passed)].map(v=>v.root), force:forceAll ? roots : []};
    request.forceAll = forceAll;
    if (selectedCell != null) request.selectedCell = selectedCell;
    request.isolateErrors = true;
    return request;
  }
  publish(result) {
    const previous = this.baseline?.id === this.state.id ? this.baseline.result : null;
    this.result = mergeCheckedResults(previous, result, this.state);
    if (result.graph) this.baseline = {id:this.state.id,result:this.result};
    return this.result;
  }
  async request(request,{onPackageWaiting}={}) {
    const runId=this.runId;
    try {
      return await this.session.request(request,{loadPackage:this.loadPackage,onPackageWaiting:waiting=>{
        if(runId!==this.runId) return;
        this.status=waiting?'Waiting for package bundle…':'Running…';this.emit();onPackageWaiting?.(waiting);
      }});
    } catch(error) {
      if(runId===this.runId && error.name==='AbortError') {this.status='Package loading cancelled · run to retry';this.emit();}
      throw error;
    }
  }
  async check() {
    try {
      const result = await this.inspect('analyze'); this.publish(result);
      this.status = result.status === 'ok' ? 'Ready · run to evaluate' : 'Needs attention'; this.emit('result'); return result;
    } catch (error) { if (error.name !== 'AbortError') { this.status = error.message; this.emit(); } return null; }
  }
  async run(selectedCell, { automatic = false } = {}) {
    if (!automatic) this.diagnosticsDeferred = false;
    this.cancelPending(); const runId = this.runId, revision = this.state.revision, id = this.state.id;
    const request = this.reactiveRequest('evaluate', selectedCell, !automatic && selectedCell == null);
    this.status = 'Saving before evaluation…'; this.emit();
    await this.persist();
    if (runId !== this.runId) return null;
    this.status = 'Running…'; this.emit();
    const started = performance.now();
    let timeout;
    const armTimeout=()=>{timeout=setTimeout(() => { if (runId === this.runId) this.stop('Stopped after 15 seconds · automatic execution paused'); }, this.timeout);};
    armTimeout();
    try {
      const result = await this.request(request,{onPackageWaiting:waiting=>{clearTimeout(timeout);if(!waiting)armTimeout();}});
      if (runId !== this.runId || revision !== this.state.revision || id !== this.state.id) return null;
      this.publish(result);
      const count=this.result.evaluation?.values?.length ?? 0, results=`${count} ${count===1?'result':'results'}`;
      this.status = result.status === 'ok' ? `Current · ${results} · ${Math.round(performance.now() - started)} ms` : result.status === 'partial' ? `Current · ${results} · ${result.evaluation.root_errors.length} failed` : result.status === 'diagnostic' ? 'Needs attention · no current results' : 'Run failed · no current results';
      const tests=this.result.evaluation?.tests ?? [], failed=tests.filter(t=>!t.passed).length;
      if (failed) this.status=`Needs attention · ${failed} failed ${failed===1?'test':'tests'} · ${results}`;
      else if (tests.length && result.status==='ok') this.status+=` · ${tests.length} ${tests.length===1?'test':'tests'} passed`;
      this.emit('result'); return result;
    } catch (error) {
      if (runId === this.runId && error.name !== 'AbortError') { this.result = null; this.status = `Run failed: ${error.message}`; this.emit('result'); }
      return null;
    } finally { clearTimeout(timeout); }
  }
  async rename(cell, position, name) {
    const result = await this.inspect('analyze', this.state.format, {draft:true});
    if (result.status !== 'ok') throw new Error('Fix compiler errors before renaming.');
    const edits = renameEdits(result,cell,position,name);
    if (!edits.length) return;
    const candidate = clone(this.state), revision=this.state.revision, id=this.state.id, token=this.runId;
    for (const edit of edits) {
      const c=candidate.cells[edit.cell]; c.source=c.source.slice(0,edit.from)+edit.insert+c.source.slice(edit.to); c.outputs=[];
    }
    candidate.sourceCurrent=false;
    const checked = await this.request(requestFor(candidate,'analyze'));
    if (token!==this.runId || revision!==this.state.revision || id!==this.state.id) throw new DOMException('Document changed','AbortError');
    if (checked.status!=='ok') throw new Error('The renamed document does not type-check. No changes were applied.');
    const original=edits.find(e=>e.cell===cell && e.from<=position && position<=e.to);
    const oldName=result.model.cells[cell].source.slice(original.from,original.to);
    const expected=result.graph.definitions.map(d=>d.name===oldName?name:d.name).sort();
    const actual=checked.graph.definitions.map(d=>d.name).sort();
    if (JSON.stringify(expected)!==JSON.stringify(actual)) throw new Error('The rename would change other bindings (for example, an annotation). No changes were applied.');
    this.change(s=>{s.cells=candidate.cells;});
  }
  stop(message = 'Stopped · automatic execution paused') {
    this.invalidate(); this.session.stop(); this.state.autoRun = false; this.status = message; this.emit(); void this.persist();
  }
  setAuto(value) { this.state.autoRun = value; void this.persist(); if (value) this.schedule(); else { clearTimeout(this.timer); this.timer = null; } this.emit(); }
  async inspect(action = 'parse', target = this.state.format, { draft = false } = {}) {
    clearTimeout(this.timer); this.timer = null;
    const revision = this.state.revision, id = this.state.id, token = ++this.runId;
    this.session.invalidate();
    this.status = 'Preparing document…'; this.emit();
    // Structural edits need spans for the editable cells, not imported source
    // that may still contain markers or saved-output comments.
    const result = await this.request(action === 'analyze' && !draft ? this.reactiveRequest(action) : requestFor(draft ? {...this.state, sourceCurrent:false} : this.state, action, target));
    if (token !== this.runId || revision !== this.state.revision || id !== this.state.id) throw new DOMException('Document changed', 'AbortError');
    if (!result.model) throw new Error(result.failure ?? 'The document engine could not read this draft.');
    this.status = result.status === 'ok' ? (this.result?.evaluation?.status === 'ok' && Array.isArray(this.result.evaluation.values) ? 'Current' : 'Ready') : 'Needs attention'; this.emit();
    return result;
  }
  async mode(mode) {
    if (mode === this.state.mode) return;
    if (mode === 'source') {
      if (!this.state.sourceCurrent) {
        const result = await this.inspect('view'); this.state.source = result.source; this.state.sourceCurrent = true;
        this.state.preamble = result.model.preamble; this.state.metadata = result.model.metadata;
      }
    } else {
      const result = await this.inspect();
      if (result.model.diagnostics.some(d => ['generated-conflict', 'handwritten-main'].includes(d.code))) {
        this.result = result; this.status = 'Generated code conflict · resolve it in source view'; this.emit('result'); return;
      }
      this.state.cells = cellsFrom(result, this.state.cells);
      this.state.preamble = result.model.preamble; this.state.metadata = result.model.metadata;
      this.result = result;
    }
    this.state.mode = mode; this.emit('document'); void this.persist();
    if (this.state.autoRun) this.schedule();
  }
  async format(format) {
    if (format === this.state.format) return;
    const before = clone(this.state);
    this.views.set(this.state.format, clone(this.state));
    const saved = this.views.get(format);
    if (saved) {
      this.invalidate(); this.state = { ...clone(saved), revision: before.revision + 1, mode: before.mode, title: before.title, autoRun: before.autoRun };
    } else {
      const result = await this.inspect('view', format);
      if (result.status !== 'ok') { this.result = result; this.status = 'Fix diagnostics before switching format'; this.emit('result'); return; }
      this.invalidate();
      this.state = { ...before, format, source: result.source, sourceCurrent: true, preamble: result.model.preamble, metadata: result.model.metadata, revision: before.revision + 1 };
    }
    this.history.push(before); this.future = []; this.group = null;
    this.emit('document'); void this.persist(); if (this.state.autoRun) this.schedule();
  }
  undo(redo = false, { editing = false } = {}) {
    const from = redo ? this.future : this.history, to = redo ? this.history : this.future;
    if (!from.length) return;
    if (editing) this.diagnosticsDeferred = true;
    const revision = this.state.revision + 1; to.push(clone(this.state)); this.invalidate();
    this.state = { ...from.pop(), revision }; this.group = null; this.views.clear();
    this.emit('document'); void this.persist(); this.schedule();
  }
  async recoveryCopy() {
    this.diagnosticsDeferred = false;
    this.invalidate();this.state={...clone(this.state),id:key(),title:`${this.state.title.slice(0,100)} (recovery)`,revision:1};delete this.state._storageVersion;this.history=[];this.future=[];this.views.clear();this.emit("document");await this.persist();
  }
  async replace(record) {
    if (!await this.persist()) throw new Error('The current draft could not be saved. Download a copy before switching documents.');
    this.diagnosticsDeferred = false;
    this.invalidate(); this.state = clone(record); this.history = []; this.future = []; this.views.clear(); this.group = null;
    this.emit('document'); await this.persist(); this.schedule();
  }
  async open(source, filename) {
    const record = newDraft(filename.replace(/\.(roc|md)$/i, ''));
    record.source = source; record.sourceCurrent = true; record.format = filename.toLowerCase().endsWith('.md') ? 'markdown' : 'roc'; record.mode = 'source';
    await this.replace(record);
    await this.mode('notebook');
  }
  dispose() { clearTimeout(this.timer); this.runId++; this.session.stop(); }
}
