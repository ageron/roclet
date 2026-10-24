import {inputValues, inputModule} from './input-values.mjs';
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
    source: '', sourceCurrent: false, inputValues: {}, files: [], mode: 'notebook', revision: 1, autoRun: true, updatedAt: Date.now() };
}
// A new draft with the same content as another: new id, fresh cell keys, so it
// can be open and saved beside the original without sharing anything.
export function independentCopy(record) {
  const copy = clone(record);
  delete copy._storageVersion;
  return { ...copy, id: key(), title: `${(record.title || 'Untitled').slice(0, 113)} (copy)`, cells: copy.cells.map(cell => ({ ...cell, key: key() })), revision: 1, updatedAt: Date.now() };
}
// The draft that opening a Roc or Markdown file creates; it starts in source
// mode until the document engine has split it into cells.
export function openedDraft(source, filename) {
  const record = newDraft(filename.replace(/\.(roc|md)$/i, ''));
  record.source = source; record.sourceCurrent = true; record.format = filename.toLowerCase().endsWith('.md') ? 'markdown' : 'roc'; record.mode = 'source';
  return record;
}
export function validDraft(record) {
  try { projectFiles(record?.files); inputValues(record?.inputValues); } catch { return false; }
  return record?.schema === 1 && typeof record.id === 'string' && typeof record.title === 'string'
    && ['roc', 'markdown'].includes(record.format) && typeof record.source === 'string'
    && Array.isArray(record.cells) && record.cells.every(c => typeof c.key === 'string' && typeof c.source === 'string' && ['code','markdown','generated'].includes(c.kind));
}
export function requestFor(state, action, target = state.format) {
  const request = { operation: 'document', action, format: state.format, target, source: state.sourceCurrent ? state.source : '', render: true };
  request.files = projectFiles(state.files).map(file => ({...file, path:`/workspace/${file.path}`}));
  if (state.sourceCurrent) request.context = { preamble: state.preamble, metadata: state.metadata };
  else request.draft = { preamble: state.preamble, metadata: state.metadata, cells: state.cells.map(({ kind, source, attributes, outputs }) => ({ kind, source, attributes, outputs })) };
  if(['evaluate','analyze','check'].includes(action)) request.modules=[inputModule(state.inputValues)];
  return request;
}
export function cellsFrom(result, previous = []) {
  return (result.draft?.cells ?? result.model.cells).map((cell, i) => ({ key: previous[i]?.key ?? key(), kind: cell.kind, source: cell.source,
    attributes: cell.attributes, outputs: cell.outputs, collapsed: previous[i]?.collapsed ?? false }));
}

export function unsavedError(message, discardLabel, discard) {
  return Object.assign(new Error(message), { name: 'UnsavedError', discardLabel, discard });
}
// Browser-owned edit history, persistence and worker lifecycle. Parsing, output
// selection, lowering and encoding are exclusively the shared Roc document core.
export class Notebook {
  constructor(bytes, store, { session = new DocumentSession(bytes), debounce = 550, timeout = 15000, onChange = () => {}, loadPackage, deferScheduling = false } = {}) {
    this.store = store; this.session = session; this.debounce = debounce; this.timeout = timeout; this.onChange = onChange;
    this.loadPackage = loadPackage;
    this.schedulingDeferred = deferScheduling;
    this.state = null; this.result = null; this.history = []; this.future = []; this.views = new Map();
    this.diagnosticsDeferred = false; this.lastChecked = null; this.baselineId = null; this.resetBaseline = false;
    this.runId = 0; this.saveVersion = 0; this.status = 'Ready'; this.saveStatus = 'Not saved yet'; this.saveChain = Promise.resolve();
    this.activeOperation = null;
  }
  setInputValue(key, value) {
    const values=inputValues({...this.state.inputValues,[key]:value});
    if(this.state.inputValues?.[key]===value) return;
    this.change(s=>{s.inputValues=values;}, {group:`input:${key}`,source:this.state.sourceCurrent,reason:'input'});
  }
  get busy() { return this.activeOperation === this.runId; }
  finishOperation(token) {
    if (this.activeOperation !== token) return;
    this.activeOperation = null;
    this.emit();
  }
  emit(reason = 'status') { this.onChange(reason); }
  // A given record (a new draft, never one already saved) opens as is; without
  // an id, fresh or record the most recent draft is recovered.
  async initialize({id = null, fresh = false, record: given = null} = {}) {
    let record = given;
    if (!given) {
      try { record = id ? await this.store.get(id) : fresh ? null : (await this.store.list()).find(validDraft); }
      catch (error) { this.saveStatus = `Browser storage unavailable: ${error.message}`; }
    }
    if (id && !validDraft(record)) throw new Error('This notebook is unavailable in this browser. Return home to choose another.');
    this.state = record ? clone(record) : fresh ? newDraft() : newDraft('Wall area', true);
    this.status = record && !given ? 'Recovered draft · results must be recomputed' : 'Ready';
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
      if (this.state.id === id && saveVersion === this.saveVersion) { this.saveStatus = `Not saved: ${error.message.replace(/[.!?]+\s*$/, '')}. Download a copy.`; this.emit(); }
      return false;
    }
  }
  // A draft that cannot be saved (for example after another tab changed it)
  // is still kept when this exact revision was downloaded.
  markDownloaded() { if (this.state) this.downloaded = { id: this.state.id, revision: this.state.revision }; }
  get downloadedCurrent() { return !!this.state && this.downloaded?.id === this.state.id && this.downloaded.revision === this.state.revision; }
  async keep() { return await this.persist() || this.downloadedCurrent; }
  cancelPending() {
    clearTimeout(this.timer); this.timer = null; this.runId++; this.activeOperation = null; this.session.invalidate();
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
    if (this.schedulingDeferred) { this.timer = null; return; }
    this.timer = setTimeout(async () => {
      this.timer = null;
      if (this.state.autoRun) void this.run(undefined, { automatic: true });
      else void this.check();
    }, this.debounce);
  }
  // A notebook without a document (a panel refused one) has nothing to check.
  resumeScheduling() { this.schedulingDeferred = false; if (this.state) this.schedule(); }
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
    // The engine owns the reactive baseline and answers for every root. A
    // different document starts a fresh baseline; forced cells and forceAll
    // are resolved against the new model by the engine.
    request.reactivity = this.resetBaseline || this.baselineId !== this.state.id ? {reset:true} : {};
    request.forceAll = forceAll;
    if (selectedCell != null) request.selectedCell = selectedCell;
    request.isolateErrors = true;
    return request;
  }
  publish(result) {
    this.result = result;
    if (result.graph) this.lastChecked = result;
    return result;
  }
  async request(request,{onPackageWaiting}={}) {
    const runId=this.runId;
    if (request.reactivity) { this.baselineId = this.state.id; this.resetBaseline = false; }
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
    this.activeOperation = runId;
    let timeout;
    const armTimeout=()=>{timeout=setTimeout(() => { if (runId === this.runId) this.stop('Stopped after 15 seconds · automatic execution paused'); }, this.timeout);};
    try {
      const request = this.reactiveRequest('evaluate', selectedCell, !automatic && selectedCell == null);
      this.status = 'Saving before evaluation…'; this.emit();
      await this.persist();
      if (runId !== this.runId) return null;
      this.status = 'Running…'; this.emit();
      const started = performance.now();
      armTimeout();
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
    } finally { clearTimeout(timeout); this.finishOperation(runId); }
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
    this.activeOperation = token;
    this.session.invalidate();
    this.status = 'Preparing document…'; this.emit();
    // Structural edits need spans for the editable cells, not imported source
    // that may still contain markers or saved-output comments.
    try {
      const result = await this.request(action === 'analyze' && !draft ? this.reactiveRequest(action) : requestFor(draft ? {...this.state, sourceCurrent:false} : this.state, action, target));
      if (token !== this.runId || revision !== this.state.revision || id !== this.state.id) throw new DOMException('Document changed', 'AbortError');
      if (!result.model) throw new Error(result.failure ?? 'The document engine could not read this draft.');
      this.status = result.status === 'ok' ? (this.result?.evaluation?.status === 'ok' && Array.isArray(this.result.evaluation.values) ? 'Current' : 'Ready') : 'Needs attention'; this.emit();
      return result;
    } catch (error) {
      if (token === this.runId && error.name !== 'AbortError') { this.status = `Preparation failed: ${error.message}`; this.emit(); }
      throw error;
    } finally { this.finishOperation(token); }
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
    this.invalidate();this.resetBaseline=true;this.state={...clone(this.state),id:key(),title:`${this.state.title.slice(0,100)} (recovery)`,revision:1};delete this.state._storageVersion;this.history=[];this.future=[];this.views.clear();this.emit("document");await this.persist();
  }
  // Switching away from a draft that cannot be kept is refused with an
  // UnsavedError whose `discard` switches anyway, losing this tab's changes.
  async replace(record, { discard = false } = {}) {
    if (!discard && !await this.keep()) throw unsavedError(`The current draft could not be saved, so the other document was not opened. ${this.saveStatus}`, 'Switch without saving (discards unsaved changes in this tab)', () => this.replace(record, { discard: true }));
    this.diagnosticsDeferred = false;
    this.invalidate(); this.resetBaseline = true; this.state = clone(record); this.history = []; this.future = []; this.views.clear(); this.group = null;
    this.emit('document'); await this.persist(); this.schedule();
  }
  async open(source, filename) {
    try { await this.replace(openedDraft(source, filename)); }
    catch (error) {
      if (error.name === 'UnsavedError') { const discard = error.discard; error.discard = async () => { await discard(); await this.mode('notebook'); }; }
      throw error;
    }
    await this.mode('notebook');
  }
  dispose() { clearTimeout(this.timer); this.runId++; this.activeOperation = null; this.session.stop(); }
}
