// Panel layout for the notebook editor: one or two notebook panels, which one
// is active, the URL that restores them, and the rule that a draft is open in
// at most one panel. Everything here is plain logic over the DOM or the panel
// objects it is given, so Node tests can import it.
import { newDraft, validDraft, independentCopy, openedDraft } from './edit-model.mjs';

// Bundled examples only, never arbitrary URLs supplied by a query parameter.
export const examples = new Map([
  ['coding-puzzle', ['../demos/02-coding-puzzle.roc', 'Coding puzzle: longest streak.roc']],
  ['reactivity', ['../demos/01-reactivity.roc', 'A result before its ingredients.roc']],
  ['meeting-windows', ['../demos/04-meeting-windows.roc', 'Finding room for a design review.roc']],
  ['rich-outputs', ['../fixtures/documents/rich-outputs.roc', 'Rich Outputs and Widgets.roc']],
]);
export const exampleTitle = name => examples.get(name)?.[1].replace(/\.roc$/, '');

// The right slot is named in the URL: a draft id, `new`, or `example:<name>`.
// One-panel URLs (`notebook`, `new`, `example`, `publication`) are unchanged.
export function parseSlot(value) {
  if (value == null || value === '') return null;
  if (value === 'new') return { fresh: true };
  if (value.startsWith('example:')) {
    const name = value.slice('example:'.length);
    return examples.has(name) ? { example: name } : { error: `Unknown example “${name}”.` };
  }
  return { id: value };
}
export function parseLayout(href) {
  const params = new URL(href).searchParams;
  return {
    left: { id: params.get('notebook'), fresh: params.get('new') === '1', example: params.get('example'), publication: params.get('publication') },
    right: parseSlot(params.get('right')),
  };
}
// While two panels are open the URL names both drafts, so a reload restores
// them; with one panel the slot parameters are removed, as before.
export function layoutUrl(href, { left = null, right = null } = {}) {
  const url = new URL(href);
  for (const name of ['notebook', 'new', 'example', 'publication', 'right']) url.searchParams.delete(name);
  if (left && right) { url.searchParams.set('notebook', left); url.searchParams.set('right', right); }
  return url.pathname + url.search + url.hash;
}
// A draft may be open in at most one panel: two editable copies of one record
// would either overwrite each other or fail each other's saves.
export function openDecision(openIds, slot, id) {
  const other = slot === 'left' ? 'right' : 'left';
  if (id != null && openIds[slot] === id) return { action: 'noop' };
  if (id != null && openIds[other] === id) return { action: 'refuse', other };
  return { action: 'open' };
}
// Tabs read “Roclet: <title>”, naming both notebooks while two are open.
export function documentTitle(titles) {
  return titles.length ? `Roclet: ${titles.map(title => title || 'Untitled').join(' | ')}` : 'Roclet';
}
// The compact tab shows a panel's state without its status bar. A Notebook
// reports its current operation as `busy`; plain summaries use the wording.
export function statusDot({ status = '', saveStatus = '', busy } = {}) {
  if (/^Not saved|unavailable/.test(saveStatus)) return { state: 'unsaved', label: 'not saved' };
  if (busy ?? /Running|Saving before|Preparing document|Waiting for package/.test(status)) return { state: 'running', label: 'running' };
  if (/failed|attention|conflict/i.test(status)) return { state: 'attention', label: 'needs attention' };
  return { state: 'idle', label: '' };
}

// Every panel element carries data-part. The primary panel keeps the legacy
// ids (prefix ''), which existing contracts and probes rely on; a second panel
// gets the same names behind its own prefix. Panel code never uses the ids.
export const partId = (prefix, name) => `${prefix}${name}`;
export function assignPanelIds(root, prefix) {
  for (const node of root.querySelectorAll('[data-part]')) node.id = partId(prefix, node.dataset.part);
  for (const node of root.querySelectorAll('[data-for]')) node.htmlFor = partId(prefix, node.dataset.for);
  return root;
}
export function clonePanel(template, prefix) {
  const root = template.content.firstElementChild.cloneNode(true);
  return assignPanelIds(root, prefix);
}

// The numbers the Dependencies & timing dialog and the status bar show for a
// panel's last completed response.
export function engineStats(result) {
  const values = result?.evaluation?.values ?? [];
  return {
    workerMs: result?.workerMs ?? null,
    evaluated: result?.evaluation?.evaluated_roots?.length ?? 0,
    reused: result?.plan?.reused?.length ?? values.filter(value => value.reused).length,
    memoryBytes: result?.transportMetrics?.memoryBytes ?? null,
  };
}
export function engineDetails(result) {
  if (result?.workerMs == null) return '—';
  const stats = engineStats(result);
  const parts = [`worker ${Math.round(stats.workerMs)} ms`, `${stats.evaluated} evaluated`, `${stats.reused} reused`];
  if (stats.memoryBytes) parts.push(`${Math.round(stats.memoryBytes / (1024 * 1024))} MiB`);
  return parts.join(' · ');
}
// Owns the panel slots (panels[0] is the left, primary panel and never moves;
// panels[1] is the optional right panel), the active panel and the URL. The
// page supplies createPanel, which builds a NotebookPanel in the DOM.
export class Workbench {
  constructor({ container = null, createPanel, store, onChange = () => {}, onLayout = () => {}, narrow = null, history = globalThis.history, location = globalThis.location, document: page = globalThis.document, fetch = globalThis.fetch?.bind(globalThis) }) {
    Object.assign(this, { container, createPanel, store, onChange, onLayout, narrow, history, location, page, fetch });
    this.panels = []; this.active = null; this.holdScheduling = false;
    narrow?.addEventListener?.('change', () => this.layout());
  }
  get left() { return this.panels[0] ?? null; }
  get right() { return this.panels[1] ?? null; }
  panel(slot) { return slot === 'left' ? this.left : this.right; }
  slotOf(panel) { return panel === this.left ? 'left' : 'right'; }
  ids() { return { left: this.left?.notebook.state?.id ?? null, right: this.right?.notebook.state?.id ?? null }; }
  get mode() { return this.panels.length < 2 ? 'single' : this.narrow?.matches ? 'tabs' : 'columns'; }
  async addPanel(slot) {
    if (this.panel(slot)) return this.panel(slot);
    if (slot === 'right' && !this.left) throw new Error('Open the left notebook first.');
    // Each panel saves through its own DraftStore instance, so even a bypassed
    // same-notebook check surfaces as the existing conflict message.
    const store = slot === 'left' ? this.store : await this.store.fork();
    const panel = this.createPanel({ slot, prefix: slot === 'left' ? '' : 'right-', store, onActivate: target => this.activate(target), onChange: (target, reason) => this.changed(target, reason) });
    panel.slot = slot; this.panels.push(panel); this.active ??= panel;
    this.layout();
    return panel;
  }
  activate(panel) {
    if (!panel || panel === this.active || !this.panels.includes(panel)) return;
    this.active = panel; this.layout(); this.onChange(panel, 'activate');
  }
  changed(panel, reason) {
    this.layout();
    if (reason === 'document') this.writeUrl();
    if (panel === this.active) this.onChange(panel, reason);
  }
  layout() {
    const two = this.panels.length === 2, mode = this.mode;
    if (this.container) { this.container.dataset.panels = String(this.panels.length); this.container.dataset.layout = mode; }
    for (const panel of this.panels) {
      const name = this.slotOf(panel) === 'left' ? 'Left' : 'Right', active = panel === this.active;
      panel.present?.({ two, mode, active,
        label: two ? `${name} notebook: ${panel.title}${active ? ', active' : ''}` : `Notebook: ${panel.title}`,
        titleLabel: two ? `${name} notebook title` : 'Document title' });
    }
    if (this.page) this.page.title = documentTitle(this.panels.filter(panel => panel.notebook.state).map(panel => panel.title));
    this.onLayout(this);
  }
  writeUrl() {
    const ids = this.ids();
    if (this.panels.length === 2 && ids.left && ids.right) this.replaceUrl(ids);
  }
  // The URL is a convenience for reloading; documents without one (srcdoc
  // test frames) keep theirs.
  replaceUrl(ids) {
    if (!/^(https?|file):/.test(this.location?.href ?? '')) return;
    this.history?.replaceState(null, '', layoutUrl(this.location.href, ids));
  }
  // Every path that opens a document in a panel comes through here. A new
  // panel stays in its loading state until its first document is rendered.
  async open(slot, request, { focus = true } = {}) {
    let panel = this.panel(slot);
    const created = !panel;
    if (request.id != null) {
      const decision = openDecision(this.ids(), slot, request.id);
      if (decision.action === 'noop') { this.activate(panel); return panel; }
      if (decision.action === 'refuse') { panel ??= await this.addPanel(slot); this.refuse(panel, decision.other); await this.reveal(panel); return panel; }
    }
    panel ??= await this.addPanel(slot);
    try { await this.load(panel, request); }
    catch (error) { if (error.name !== 'AbortError') (panel.report ?? (e => panel.notice(e.message))).call(panel, error); }
    await this.reveal(panel);
    this.layout(); this.writeUrl();
    if (created && focus) { this.activate(panel); panel.focus(); }
    return panel;
  }
  async reveal(panel) {
    // While the page itself is starting, evaluation waits for the whole page.
    try { await panel.reveal?.({ schedule: !this.holdScheduling }); }
    catch (error) { if (error.name !== 'AbortError') panel.notice(error.message); }
  }
  async load(panel, request) {
    const notebook = panel.notebook, current = !!notebook.state;
    if (request.id != null) {
      if (!current) return notebook.initialize({ id: request.id });
      const record = await panel.store.get(request.id);
      if (!validDraft(record)) throw new Error('This notebook is unavailable in this browser.');
      return notebook.replace(record);
    }
    if (request.record) return current ? notebook.replace(request.record) : notebook.initialize({ record: request.record });
    if (request.fresh) return current ? notebook.replace(newDraft()) : notebook.initialize({ fresh: true });
    if (request.example) {
      const entry = examples.get(request.example);
      if (!entry) throw new Error('Unknown example.');
      const response = await this.fetch(entry[0]);
      if (!response.ok) throw new Error('Example is unavailable.');
      const source = await response.text();
      if (current) await notebook.open(source, entry[1]);
      else { await notebook.initialize({ record: openedDraft(source, entry[1]) }); await notebook.mode('notebook'); }
      panel.notice('Opened your own editable copy. Download a copy to keep your changes.');
      return;
    }
    throw new Error('Nothing to open.');
  }
  refuse(panel, otherSlot) {
    const other = this.panel(otherSlot);
    panel.notice(`This notebook is already open in the ${otherSlot} panel. A notebook can be open in only one panel at a time.`, [
      ['Go to it', () => { this.activate(other); other.focus(); }],
      ['Open an independent copy here', async () => { await this.load(panel, { record: independentCopy(other.notebook.state) }); this.layout(); this.writeUrl(); }],
    ]);
  }
  // Closing a panel saves it first. A notebook that cannot be saved (another
  // tab changed its draft, or storage failed) keeps the panel open with a
  // notice offering a download, after which closing proceeds, or closing
  // without saving that notebook, named in `discard`. Closing the left panel
  // moves the right document into the left slot (a document switch, so the
  // engine starts a fresh baseline) and loses the right undo history.
  async close(slot, { discard = [] } = {}) {
    const left = this.left, right = this.right;
    if (!right) return false;
    const kept = async panel => !panel.notebook.state || discard.includes(panel) || await panel.notebook.keep();
    if (!await kept(right)) return this.closeRefused(right, slot, discard);
    if (slot === 'left' && right.notebook.state) {
      if (!await kept(left)) return this.closeRefused(left, slot, discard);
      const id = right.notebook.state.id;
      this.remove(right);
      const record = await left.store.get(id);
      if (!validDraft(record)) throw new Error('The right notebook is unavailable in this browser.');
      if (left.notebook.state) await left.notebook.replace(record, { discard: true }); else await left.notebook.initialize({ id });
    } else this.remove(right);
    this.replaceUrl({});
    left.focus();
    return true;
  }
  closeRefused(panel, slot, discard) {
    const name = this.slotOf(panel);
    panel.notice(`The ${name} notebook could not be saved, so the ${slot} panel stays open. ${panel.notebook.saveStatus}`, [
      ['Download a copy', () => panel.download?.()],
      ['Close without saving (discards unsaved changes in this tab)', () => this.close(slot, { discard: [...discard, panel] })],
    ]);
    this.activate(panel);
    return false;
  }
  remove(panel) {
    this.panels = this.panels.filter(item => item !== panel);
    if (this.active === panel) this.active = this.left;
    panel.dispose(); panel.root?.remove();
    if (panel.store !== this.store) panel.store.close?.();
    this.layout(); this.onChange(this.active, 'activate');
  }
  unsaved() { return this.panels.some(panel => panel.notebook.state && panel.notebook.saveStatus !== 'Saved in this browser'); }
  dispose() {
    for (const panel of this.panels) { panel.dispose(); if (panel.store !== this.store) panel.store.close?.(); }
  }
}

// Per-viewer preferences are stored like the theme; storage may be unavailable.
export const engineDetailsKey = 'roclet.engine-details';
export function readPreference(storage, key, fallback = false) {
  try { const value = storage?.getItem(key); return value == null ? fallback : value === 'true'; } catch { return fallback; }
}
export function writePreference(storage, key, value) {
  try { storage?.setItem(key, String(value)); } catch { /* The preference then applies to this page only. */ }
}
