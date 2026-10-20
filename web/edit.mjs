import { prepareOffline, offlineStatus, storageStatus } from './offline.mjs';
import { captureExport, exportBundle, importBundle, exportReport, exportSite, download, downloadName } from './sharing.mjs';
import { Notebook, newDraft, makeCell, validDraft } from './edit-model.mjs';
import { CellEditor, editorFor } from './cell-editor.mjs';
import { symbolAt, completionOptions } from './compiler-tools.mjs';
import { CompilerHighlighter } from './roc-highlighting.mjs';
import { DraftStore } from './edit-store.mjs';
import { loadPackageBundle } from './package-dialog.mjs';
import { renderMarkdown } from './markdown-view.mjs';
import { renderDisplay } from './display-view.mjs';
import { CellSelection, insertionIndex, commentFinalExpression, cellMime, encodeCells, decodeCells, checkInsertion } from './edit-cells.mjs';
const $ = id => document.getElementById(id);
let store, compilerManifest;
let notebook, highlighter, sourceEditor, headerEditor, headerDocumentId, libraryToken = 0, composing = false;
const cards = new Map();
const notice = message => { $('notice').textContent = message; $('notice').hidden = !message; };
const perform = async work => {
  notice('');
  try { await work(); } catch (error) { if (error.name !== 'AbortError') notice(error.message); }
};
const button = (label, action, name = label) => {
  const node = document.createElement('button'); node.textContent = label; node.setAttribute('aria-label', name); node.onclick = () => perform(action); return node;
};
function outputBlock(label, text, kind = '', display = null) {
  const block = document.createElement('section'); block.className = `result-block ${kind}`;
  const heading = document.createElement('div'); heading.className = 'result-heading'; heading.textContent = label;
  const output = document.createElement('pre'); output.textContent = text;
  block.append(heading, output);
  const rich=renderDisplay(display,text);if(rich) {output.hidden=true;block.append(rich);}
  return block;
}
// Presentation only: keep the same output nodes while an edited revision is
// pending. The model still invalidates results immediately for execution/export.
function renderObservation(view, kind, content, stale = false) {
  view.observations[kind] = content;
  if (!content) { view.outputBlocks[kind]?.remove(); delete view.outputBlocks[kind]; return; }
  let block = view.outputBlocks[kind];
  if (!block) {
    block = view.outputBlocks[kind] = outputBlock('', '', kind);
    if (kind === 'value') {
      const spinner = document.createElement('span'); spinner.className = 'output-spinner'; spinner.setAttribute('aria-hidden','true'); block.append(spinner);
    }
  }
  const output = block.querySelector(':scope > pre');
  if (block.firstChild.textContent !== content.heading) block.firstChild.textContent = content.heading;
  if (output.textContent !== content.text) output.textContent = content.text;
  if(block.displayValue!==content.display || block.displayText!==content.text) {
    const richKey=JSON.stringify([content.display??null,content.text]);
    if(block.richKey!==richKey) {
      block.querySelector(':scope > .rich-output')?.remove();
      const rich=renderDisplay(content.display,content.text);output.hidden=!!rich;
      if(rich) block.insertBefore(rich,output);block.richKey=richKey;
    }
    block.displayValue=content.display;block.displayText=content.text;
  }
  const updating = stale && (/^(Saving before evaluation|Running)/.test(notebook.status) || (notebook.state.autoRun && notebook.status.startsWith('Changed')));
  block.dataset.stale = String(stale);
  block.dataset.updating = String(updating);
  block.setAttribute('aria-label', stale ? `${kind === 'value' ? 'Result' : kind === 'tests' ? 'Tests' : 'Debug'} from an earlier run, ${updating ? 'updating' : 'awaiting update'}` : content.heading);
  block.title = stale ? `From an earlier run. ${updating ? 'Updating…' : 'Awaiting an update.'}` : '';
  if (block.parentNode !== view.results) view.results.append(block);
}
function clearObservations(view) {
  for (const kind of ['value', 'debug', 'tests']) renderObservation(view, kind, null);
}
const selection = new CellSelection();
let documentId, selectionActive = false;
const editable = () => notebook.state.cells.filter(c => c.kind !== 'generated');
const cellIndex = key => notebook.state.cells.findIndex(c => c.key === key);
const textTarget = target => target instanceof Element && !!target.closest('textarea,input,select,[contenteditable=true]');
function closeMenus(except = null) {
  document.querySelectorAll('details.popover[open]').forEach(menu => {
    if (menu === except) return;
    menu.open = false;
    if (menu.contains(document.activeElement)) menu.querySelector('summary').focus({preventScroll:true});
  });
}
function focusCell(key, extend = false) {
  notebook.finishEditing();
  closeMenus(); window.getSelection()?.removeAllRanges(); selection.select(key, extend); selectionActive = true; renderSelection();
  const card = cards.get(selection.focus)?.card;
  (card ?? $('notebook')).focus({preventScroll:true}); card?.scrollIntoView({block:'nearest'});
}
function focusCells(keys) {
  // Keep the active end of a range, including selections made upwards.
  const backwards = selection.focus === keys[0];
  selection.select(backwards ? keys.at(-1) : keys[0]);
  focusCell(backwards ? keys[0] : keys.at(-1), true);
}
function actionKeys(key) {
  const selected = selection.selected;
  return selectionActive && selected.includes(key) ? selected : [key];
}
function editCell(key) {
  const cell = notebook.state.cells[cellIndex(key)]; if (!cell) return;
  if (selection.focus !== key) notebook.finishEditing();
  closeMenus(); selection.select(key); selection.mode = 'text'; selectionActive = true;
  renderSelection(); cards.get(key)?.editor.focus();
}
function renderSelection() {
  const selected = selection.selected;
  for (const [key, view] of cards) {
    const cell = notebook.state.cells[cellIndex(key)]; if (!cell) continue;
    const active = selectionActive && selected.includes(key), editing = active && selection.mode === 'text';
    view.card.classList.toggle('selected', active); view.card.classList.toggle('current', active && key === selection.focus); view.card.classList.toggle('command-selected', active && selection.mode === 'cells');
    view.card.classList.toggle('editing', editing); view.card.classList.toggle('markdown-cell', cell.kind === 'markdown');
    view.card.dataset.selected = String(active); view.card.tabIndex = key === selection.focus ? 0 : -1;
    view.card.setAttribute('aria-label', `Cell ${selection.keys.indexOf(key) + 1}, ${cell.kind === 'markdown' ? 'Markdown' : 'Code'}${active && selection.mode === 'cells' ? ', selected' : ''}`);
    view.gutter.setAttribute('aria-pressed', active && selection.mode === 'cells');
    const sourceCollapsed = cell.collapsed && !editing;
    view.editor.setHidden(sourceCollapsed || (cell.kind === 'markdown' && !editing));
    view.preview.hidden = cell.kind !== 'markdown' || editing || cell.collapsed;
    view.expand.hidden = !sourceCollapsed;
    const keys = actionKeys(key), count = keys.length;
    const collapsed = keys.every(k => notebook.state.cells[cellIndex(k)].collapsed);
    view.up.textContent = count > 1 ? `Move ${count} cells up` : 'Move up';
    view.up.setAttribute('aria-label', count > 1 ? view.up.textContent : 'Move cell up');
    view.down.textContent = count > 1 ? `Move ${count} cells down` : 'Move down';
    view.down.setAttribute('aria-label', count > 1 ? view.down.textContent : 'Move cell down');
    view.up.disabled = keys[0] === selection.keys[0];
    view.down.disabled = keys.at(-1) === selection.keys.at(-1);
    view.merge.textContent = count > 1 ? `Merge ${count} cells` : 'Merge with next';
    view.merge.setAttribute('aria-label', view.merge.textContent);
    view.merge.disabled = count === 1 && view.down.disabled;
    view.collapse.textContent = `${collapsed ? 'Expand' : 'Collapse'} ${count > 1 ? `${count} sources` : 'source'}`;
    view.collapse.setAttribute('aria-label', count > 1 ? view.collapse.textContent : `${collapsed ? 'Expand' : 'Collapse'} cell`);
  }
  $('selection-status').textContent = !selectionActive || notebook.state.mode !== 'notebook' ? '' : selection.mode === 'text' ? 'Editing · Esc to select cell' : selected.length > 1 ? `${selected.length} cells selected · ⌘ / Ctrl C, X, V` : selected.length ? 'Cell selected · Enter to edit' : 'No cells · A or B to insert';
}
function insertCells(position, additions, edit = false) {
  checkInsertion(notebook.state.cells, additions);
  notebook.change(s => s.cells.splice(insertionIndex(s.cells, position), 0, ...additions));
  selection.select(additions[0].key); selection.select(additions.at(-1).key, true);
  selectionActive = true; renderSelection();
  if (edit) editCell(additions[0].key); else cards.get(selection.focus)?.card.focus();
}
function insertAtSelection(below, kind = 'code') {
  const selected = selection.selected;
  const at = below ? selection.keys.indexOf(selected.at(-1)) + 1 : Math.max(0, selection.keys.indexOf(selected[0]));
  insertCells(at, [makeCell(kind)], true);
}
function removeCells(keys) {
  if (!keys.length) return;
  const position = Math.min(...keys.map(key => selection.keys.indexOf(key)));
  notebook.change(s => { s.cells = s.cells.filter(c => !keys.includes(c.key)); });
  selection.mode = 'cells'; focusCell(selection.keys[Math.min(position, selection.keys.length - 1)]);
}
function moveCells(keys, delta) {
  const cells = editable(), from = cells.findIndex(c => c.key === keys[0]);
  if (from + delta < 0 || from + keys.length + delta > cells.length) return;
  const moved = cells.splice(from, keys.length);
  cells.splice(from + delta, 0, ...moved);
  notebook.change(s => {
    // Reorder visible cells as a block, leaving generated sections in place.
    let next = 0;
    s.cells = s.cells.map(c => c.kind === 'generated' ? c : cells[next++]);
  });
  focusCells(keys);
}
function collapseCells(keys) {
  const cells = keys.map(key => notebook.state.cells[cellIndex(key)]);
  const collapsed = !cells.every(c => c.collapsed);
  for (const cell of cells) cell.collapsed = collapsed;
  focusCells(keys); void notebook.persist();
}
function splitCell(key) {
  const index=cellIndex(key), cell=notebook.state.cells[index], editor=cards.get(key)?.editor;
  if (!editor || cell.kind==='generated') return;
  const at=editor.view.state.selection.main.head, next=makeCell(cell.kind,cell.source.slice(at));
  checkInsertion(notebook.state.cells,[next]);
  notebook.change(s=>{s.cells[index].source=cell.source.slice(0,at);s.cells[index].outputs=[];s.cells.splice(index+1,0,next);});
  editCell(next.key);cards.get(next.key).editor.goTo(1);
}
async function mergeCells(keys) {
  let indices=keys.map(cellIndex).sort((a,b)=>a-b);
  if(indices.length===1) { const next=selection.keys[selection.keys.indexOf(keys[0])+1];if(next) indices.push(cellIndex(next)); }
  if(indices.length<2) return;
  const cells=indices.map(i=>notebook.state.cells[i]);
  if(cells.some(c=>c.kind!==cells[0].kind)) throw new Error('Choose cells of the same type to merge.');
  if(cells.filter(c=>c.attributes?.trim()).length>1) throw new Error('These cells have separate attributes. Keep them separate or remove the extra attributes before merging.');
  const key=cells[0].key;
  let sources=cells.map(c=>c.source);
  if(cells[0].kind==='code') {
    // inspect guards against edits, undo, document changes and Stop while the
    // parser is running. These facts never require evaluating notebook code.
    const parsed=await notebook.inspect('parse', notebook.state.format, {draft:true});
    sources=sources.map((source,i)=>i===sources.length-1 ? source : commentFinalExpression(source,parsed.model.cells[indices[i]].facts));
  }
  notebook.change(s=>{ const first=s.cells[indices[0]];first.source=sources.join('\n');first.attributes=cells.find(c=>c.attributes?.trim())?.attributes??'';first.outputs=[];s.cells=s.cells.filter((c,i)=>!indices.slice(1).includes(i)); });
  focusCell(key);
}
function findNotebook() {
  closeMenus();$('find-dialog').showModal();$('find-query').focus();updateFind();
}
function updateFind() {
  const query=$('find-query').value.toLocaleLowerCase();$('find-results').replaceChildren();if(!query) return;
  let count=0;
  const sources=notebook.state.mode==='source'?[{source:notebook.state.source}]:editable();
  for(const [index,cell] of sources.entries()) {
    const lines=cell.source.split('\n');
    for(const [line,text] of lines.entries()) {
      const column=text.toLocaleLowerCase().indexOf(query);if(column<0) continue;
      const hit=button(`${notebook.state.mode==='source'?'Source':`Cell ${index+1}`} · ${line+1}: ${text.slice(0,160)}`,()=>{
        $('find-dialog').close();if(cell.key) {editCell(cell.key);cards.get(cell.key).editor.goTo(line+1,column+1);}else sourceEditor.goTo(line+1,column+1);
      });$('find-results').append(hit);if(++count===100) return;
    }
  }
  if(!count) $('find-results').textContent='No matches';
}
function insertion(position) {
  const rail = document.createElement('div'); rail.className = 'insertion';
  for (const [kind, label] of [['code','+ Code'],['markdown','+ Markdown']]) rail.append(button(label, () => insertCells(position, [makeCell(kind)], true), `Insert ${kind} cell ${position ? `after cell ${position}` : 'at start'}`));
  return rail;
}
async function runCell(key, advance = false, insert = false) {
  const cell = notebook.state.cells[cellIndex(key)]; if (!cell) return;
  notebook.finishEditing({ flush: false });
  if (insert) insertAtSelection(true);
  else if (advance) {
    const next = selection.keys[selection.keys.indexOf(key) + 1];
    if (next) focusCell(next); else insertAtSelection(true);
  } else if (cell.kind === 'markdown') focusCell(key);
  if (cell.kind === 'markdown') {
    notebook.finishEditing();
    if (!notebook.result?.rendering) { const result = await notebook.inspect(); notebook.result = result; notebook.emit('result'); }
  } else await notebook.run(cellIndex(key));
}
function createCard(cell) {
  const card = document.createElement('article'); card.className = 'cell'; card.dataset.key = cell.key; card.setAttribute('aria-roledescription','cell'); card.setAttribute('aria-describedby','navigation-help');
  const gutter = button('', () => {}, 'Select cell'); gutter.className = 'gutter';
  gutter.onclick = event => focusCell(cell.key, event.shiftKey);
  const body = document.createElement('div'); body.className = 'cell-body';
  const tools = document.createElement('div'); tools.className = 'cell-tools';
  const menu = document.createElement('details'); menu.className = 'popover';
  const summary = document.createElement('summary'); summary.textContent = '⋯'; summary.setAttribute('aria-label','Cell actions'); summary.title = 'Cell actions';
  const panel = document.createElement('div'); panel.className = 'menu-panel';
  const label = document.createElement('span'); label.className = 'cell-label';
  const kindLabel = document.createElement('label'); kindLabel.textContent = 'Cell type';
  const kind = document.createElement('select'); kind.className = 'cell-kind';
  for (const [value, text] of [['code','Code'],['markdown','Markdown']]) { const option = document.createElement('option'); option.value = value; option.textContent = text; kind.append(option); }
  kindLabel.append(kind);
  const index = () => cellIndex(cell.key);
  kind.onchange = () => { notebook.change(s => { s.cells[index()].kind = kind.value; s.cells[index()].outputs = []; }); editCell(cell.key); };
  const run = button('▷', () => runCell(cell.key), 'Run cell'); run.title = 'Run cell · ⌘ / Ctrl Enter';
  const up = button('Move up', () => moveCells(actionKeys(cell.key), -1), 'Move cell up');
  const down = button('Move down', () => moveCells(actionKeys(cell.key), 1), 'Move cell down');
  const collapse = button('Collapse source', () => collapseCells(actionKeys(cell.key)), 'Collapse cell');
  const merge = button('Merge with next', () => mergeCells(actionKeys(cell.key)));
  const remove = button('Delete cell', () => removeCells([cell.key])); remove.className = 'danger';
  panel.append(label, kindLabel, button('Dependencies & timing',()=>showDependencies(index())), button('Split at cursor',()=>splitCell(cell.key)), merge, up, down, collapse, remove); menu.append(summary, panel); tools.append(run, menu);
  const results = document.createElement('div'); results.className = 'cell-result'; results.id = `result-${cell.key}`; results.setAttribute('aria-live','polite');
  const editor = new CellEditor(body,{
    source:cell.source,kind:cell.kind,positions:cell.editorSelection,highlighter,
    symbol:position=>symbolAt(notebook.result,index(),position),
    completions:prefix=>completionOptions(notebook.result ?? notebook.baseline?.result,prefix),
    onRename:position=>openRename(index(),position),
    onFocus:()=>{ selection.select(cell.key); selection.mode='text'; selectionActive=true; renderSelection(); },
    onChange:(value,isComposing,positions)=>notebook.editCell(index(),value,isComposing || composing,positions),
    onSelection:positions=>{ if(index()>=0) notebook.state.cells[index()].editorSelection=positions; notebook.group=null; },
    onComposition:value=>{ composing=value; if(value) clearTimeout(notebook.timer); else notebook.schedule(); },
    adjacent:(forward,goal)=>{
      const next=selection.keys[selection.keys.indexOf(cell.key)+(forward?1:-1)];
      if(!next) return false;
      editCell(next); cards.get(next)?.editor.enter(forward,goal); return true;
    },
  });
  const preview = document.createElement('div'); preview.className = 'cell-preview'; preview.title = 'Click to edit Markdown';
  preview.onclick = event => {
    if (event.target.closest('a,button') || window.getSelection()?.toString()) return;
    if (event.shiftKey) focusCell(cell.key, true); else editCell(cell.key);
  };
  const expand = button('Collapsed cell · click to edit', () => editCell(cell.key)); expand.className = 'expand-cell';
  const meta = document.createElement('div'); meta.className = 'cell-meta';
  card.onfocus = () => { if (selection.focus !== cell.key || selection.mode !== 'cells') { selection.select(cell.key); selectionActive = true; renderSelection(); } };
  card.onclick = event => { if (event.target === card || event.target === body) focusCell(cell.key, event.shiftKey); };
  body.append(expand, preview, meta, results); card.append(gutter, body, tools);
  const view = { card, gutter, editor, kind, label, run, up, down, collapse, merge, preview, expand, results, meta, previewSource:null, observations:{}, outputBlocks:{} };
  cards.set(cell.key, view); return view;
}
function renderCells() {
  const focused = document.activeElement;
  const focusedEditor = editorFor(focused);
  if (documentId !== notebook.state.id) { documentId = notebook.state.id; selection.anchor = selection.focus = null; selectionActive = false; selection.mode = 'cells'; for (const view of cards.values()) clearObservations(view); }
  const cells = editable(); selection.reconcile(cells.map(c => c.key));
  const current = new Set(selection.keys);
  for (const [key, view] of cards) if (!current.has(key)) { view.editor.destroy(); view.card.remove(); cards.delete(key); }
  $('cells').querySelectorAll('.insertion').forEach(n => n.remove());
  let prior = null;
  for (const [position, cell] of cells.entries()) {
    const view = cards.get(cell.key) ?? createCard(cell);
    if (prior ? prior.nextElementSibling !== view.card : $('cells').firstElementChild !== view.card) $('cells').insertBefore(view.card, prior ? prior.nextSibling : $('cells').firstChild);
    prior = view.card;
    view.gutter.textContent = String(position + 1).padStart(2, '0'); view.gutter.setAttribute('aria-label',`Select cell ${position + 1}`); view.kind.value = cell.kind;
    view.kind.setAttribute('aria-label', `Cell ${position + 1} kind`); view.editor.setLabel(`Cell ${position + 1} source`,view.results.id);
    view.editor.sync(cell.source,cell.kind,cell.editorSelection);
    view.run.setAttribute('aria-label', cell.kind === 'markdown' ? 'Render Markdown cell' : 'Run cell');
  }
  cells.forEach((cell, i) => $('cells').insertBefore(insertion(i), cards.get(cell.key).card));
  $('cells').append(insertion(cells.length));
  renderSelection(); renderResults();
  if (focused.isConnected && document.activeElement !== focused && !focusedEditor?.dom.hidden) focused.focus({preventScroll:true});
}
function showDependencies(index) {
  closeMenus();
  const result=notebook.result, cell=result?.model?.cells[index];
  const roots=[cell?.output,...(cell?.expectations ?? [])].filter(Boolean);
  const items=result?.plan?.explanations?.filter(e=>roots.includes(e.root)) ?? [];
  const content=$('dependencies-content'); content.replaceChildren();
  if (!items.length) content.textContent='Run or check the notebook to inspect this cell’s dependencies.';
  else {
    for(const item of items) {
      const label=item.root===cell.output?'Output':`Test ${cell.expectations.indexOf(item.root)+1}`;
      const reason=document.createElement('p'); reason.textContent=`${label}: ${item.reason}`;
      const deps=document.createElement('pre'); deps.textContent=item.dependencies.map(name=>`${name}: ${(result.graph.definitions.find(d=>d.name===name)?.dependencies ?? []).join(', ') || 'no notebook dependencies'}`).join('\n');
      content.append(reason,deps);
    }
    const time=document.createElement('p');
    time.textContent=`Last request: ${Math.round(result.workerMs ?? 0)} ms in the worker · ${result.evaluation.evaluated_roots?.length ?? 0} evaluations · ${result.plan.reused.length} reused.`;
    content.append(time);
    if (result.graph?.scope==='module') {const note=document.createElement('p');note.textContent='This document uses types or dispatch requiring conservative module-wide invalidation.';content.append(note);}
  }
  $('dependencies-dialog').showModal();
}
function openRename(index,position) {
  if (notebook.state.cells[index]?.kind!=='code') return;
  const d=symbolAt(notebook.result,index,position);
  if (!d) {notice('Run or check, then place the cursor on a top-level name to rename it.');return;}
  $('rename-name').value=d.name; $('rename-error').textContent='';
  $('rename-apply').onclick=()=>perform(async()=>{
    try {await notebook.rename(index,position,$('rename-name').value);$('rename-dialog').close();editCell(notebook.state.cells[index].key);}
    catch(error){$('rename-error').textContent=error.message;}
  });
  $('rename-dialog').showModal();$('rename-name').select();
}
function renderResults() {
  const result = notebook.result;
  const showDiagnostics = !notebook.diagnosticsDeferred;
  $('document-diagnostics').replaceChildren();
  for (const view of cards.values()) {
    for (const child of [...view.results.children]) if (!Object.values(view.outputBlocks).includes(child)) child.remove();
    view.meta.textContent = '';
  }
  const cellAt = index => cards.get(notebook.state.cells[index]?.key);
  if (result?.rendering) for (const item of result.rendering) {
    const view = cellAt(item.cell); if (!view) continue;
    view.preview.replaceChildren(renderMarkdown(item.events)); view.previewSource = notebook.state.cells[item.cell].source;
  }
  for (const cell of editable()) {
    const view = cards.get(cell.key);
    if (cell.kind === 'markdown' && view.previewSource !== cell.source) {
      const fallback = document.createElement('div'); fallback.className = 'markdown-fallback'; fallback.textContent = cell.source;
      view.preview.replaceChildren(...(cell.source ? [fallback] : [])); view.previewSource = cell.source;
    }
  }
  const failures = showDiagnostics ? result?.model?.diagnostics ?? [] : [];
  const diagnosticTexts = new Set();
  for (const d of failures) {
    const view = notebook.state.mode === 'notebook' ? cellAt(d.cell) : null;
    const place = d.location ? ` · ${d.scope === 'cell' ? 'line ' : 'source '}${d.location.line}:${d.location.column}` : '';
    const block = outputBlock(`${d.severity}: ${d.code}${place}`, d.message, 'diagnostic');
    if(d.location && (view || notebook.state.mode==='source')) {
      block.querySelector('.result-heading').append(button('Go to source',()=>{if(view) editCell(notebook.state.cells[d.cell].key);(view?.editor??sourceEditor).goTo(d.location.line,d.location.column,true);}));
    }
    (view?.results ?? $('document-diagnostics')).append(block); diagnosticTexts.add(d.message);
  }
  for (const d of showDiagnostics ? result?.evaluation?.diagnostics ?? [] : []) if (!diagnosticTexts.has(d.message)) $('document-diagnostics').append(outputBlock(d.title ?? d.severity, d.message, 'diagnostic'));
  if (showDiagnostics && result?.status !== 'partial' && (result?.failure || result?.evaluation?.failure)) $('document-diagnostics').append(outputBlock('Run failed', result.failure ?? result.evaluation.failure, 'diagnostic'));
  const transcript = showDiagnostics || result?.status === 'ok' ? result?.evaluation?.events ?? [] : [];
  for (const [index, cell] of notebook.state.cells.entries()) {
    const view = cellAt(index); if (!view) continue;
    const analyzed = result?.model?.cells?.[index];
    const inferredId = analyzed?.id && !/(?:^|\s)id=/.test(cell.attributes) ? `id=${analyzed.id}` : '';
    view.label.textContent = [`Cell ${selection.keys.indexOf(cell.key) + 1}`, inferredId, cell.attributes].filter(Boolean).join(' · ');
    if (cell.kind === 'code') {
      const root = analyzed?.output;
      const value = result?.graph || result?.status === 'ok' ? result?.evaluation?.values?.find(v => v.root === root) : null;
      const evaluated = (result?.graph || result?.status === 'ok') && ['ok','partial'].includes(result?.evaluation?.status) && Array.isArray(result.evaluation.values);
      const removedOutput = evaluated && !root;
      const type = value && result.evaluation.definitions?.find(d => d.name === root)?.type;
      const displayed = value ? { heading:`Result${type ? ` · ${type}` : ''}`, text:value.text, display:value.display } : removedOutput ? null : view.observations.value;
      renderObservation(view, 'value', displayed, !value);
      if (!displayed && showDiagnostics) view.meta.textContent = result?.status === 'diagnostic' ? 'Blocked by document diagnostics' : '';
      const error = result?.evaluation?.root_errors?.find(e=>e.root===root);
      if (error && showDiagnostics) view.results.append(outputBlock('Output failed',error.failure ?? error.status,'diagnostic'));
      const tests = result?.evaluation?.tests?.filter(t=>t.cell===index) ?? [];
      const testFailures=tests.filter(t=>!t.passed);
      const testLocation=test=>{
        const at=test.scope==='source'?test.start-analyzed.body_start:test.start;
        if(at==null) return null;
        const prefix=new TextDecoder().decode(new TextEncoder().encode(cell.source).subarray(0,Math.max(0,at)));
        const lines=prefix.split('\n');return {line:lines.length,column:new TextEncoder().encode(lines.at(-1)).length+1};
      };
      const testContent=tests.length ? {
        heading:testFailures.length ? `Tests · ${testFailures.length} failed, ${tests.length-testFailures.length} passed` : `Tests · ${tests.length} passed`,
        text:tests.map(t=>{const at=testLocation(t);return `${t.passed?'PASS':'FAIL'}${at?` · line ${at.line}:${at.column}`:''}: ${t.message}`;}).join('\n'),
      } : evaluated ? null : view.observations.tests;
      renderObservation(view, 'tests', testContent, !tests.length);
      view.outputBlocks.tests?.classList.toggle('diagnostic', testFailures.length>0);
      if (tests.length && view.outputBlocks.tests) {
        const heading=view.outputBlocks.tests.querySelector('.result-heading');
        const target=testFailures[0] ?? tests[0];
        const at=testLocation(target);if(at) heading.append(button('Go to source',()=>{editCell(cell.key);view.editor.goTo(at.line,at.column,true);}));
      }
      const events = transcript.filter(e => e.cell === index);
      const debug = events.length ? { heading:!error && ['ok','partial'].includes(result.status) ? 'Debug · current result' : 'Debug · failed run', text:events.map(e => `${e.kind === 'dbg' ? 'dbg' : e.kind}: ${e.message}`).join('\n') }
        : value || removedOutput ? null : view.observations.debug;
      renderObservation(view, 'debug', debug, !events.length);
      const imported=notebook.state.savedResults?.snapshots?.filter(s=>s.cell===index)??[];
      if(!displayed) for(const saved of imported) view.results.append(outputBlock('Imported result · unverified',saved.text,'unverified',saved.display));
      const importedDebug=notebook.state.savedResults?.events?.filter(e=>e.cell===index)??[];
      if(!debug && !notebook.result?.evaluation && importedDebug.length) view.results.append(outputBlock('Imported debug · unverified',importedDebug.map(e=>`${e.kind}: ${e.message}`).join('\n'),'unverified'));
      const snapshots = analyzed?.outputs ?? cell.outputs;
      if (!displayed && snapshots?.length) view.results.append(outputBlock('Saved snapshot · unverified', snapshots.map(o => o.source).join('\n'), 'unverified'));
    } else clearObservations(view);
  }
  const unassigned = transcript.filter(e => e.cell == null);
  if (unassigned.length) $('document-diagnostics').append(outputBlock('Notebook debug', unassigned.map(e => e.message).join('\n'), 'debug'));
  if (notebook.state.mode === 'source' && result?.evaluation?.tests?.length) $('document-diagnostics').append(outputBlock('Tests',result.evaluation.tests.map(t=>`${t.passed?'PASS':'FAIL'}${t.location?` · source ${t.location.line}:${t.location.column}`:''}: ${t.message}`).join('\n'),result.evaluation.tests.some(t=>!t.passed)?'diagnostic':''));
  if (notebook.state.mode === 'source' && result?.status === 'ok' && result?.evaluation?.values?.length) $('document-diagnostics').append(outputBlock('Current results', result.evaluation.values.map(v => `${v.root}: ${v.text}`).join('\n')));
}
async function refreshLibrary() {
  const token = ++libraryToken;
  try {
    const records = (await store.list()).filter(validDraft);
    if (token !== libraryToken) return;
    $('recent').replaceChildren();
    for (const record of records) { const option = document.createElement('option'); option.value = record.id; option.textContent = record.title || 'Untitled'; option.selected = record.id === notebook.state.id; $('recent').append(option); }
  } catch { /* The persistent save-status message already explains the failure. */ }
}
function reflect(reason) {
  if (!notebook?.state) return;
  const s = notebook.state;
  if ($('title').value !== s.title) $('title').value = s.title;
  document.title = `${s.title || 'Untitled'} — Roclet`;
  $('auto').checked = s.autoRun; $('format').value = s.format;
  $('stop').hidden = !/Running|Saving before|Preparing document/.test(notebook.status);
  if ($('stop').hidden && document.activeElement === $('stop')) $('run').focus({preventScroll:true});
  const status = notebook.diagnosticsDeferred && /^(Needs attention|Run failed · no current results)/.test(notebook.status) ? 'Editing · results pending' : notebook.status;
  $('status').textContent = status; $('status').className = /failed|attention|conflict/i.test(status) ? 'error' : '';
  $('save-status').textContent = notebook.saveStatus; $('save-status').title = notebook.saveStatus; $('save-status').className = /^Not saved|unavailable/.test(notebook.saveStatus) ? 'error' : '';
  $('recovery-copy').hidden=!/^Not saved/.test(notebook.saveStatus);
  $('undo').disabled = !notebook.history.length; $('redo').disabled = !notebook.future.length;
  $('notebook-view').setAttribute('aria-pressed', s.mode === 'notebook'); $('source-view').setAttribute('aria-pressed', s.mode === 'source');
  $('notebook').hidden = s.mode !== 'notebook'; $('source-pane').hidden = s.mode !== 'source';
  $('app-header').hidden = s.mode !== 'notebook';
  const preamble=s.preamble ?? '';headerEditor.sync(preamble,'code',s.headerSelection);
  if(s.mode==='notebook' && headerDocumentId!==s.id) {
    headerDocumentId=s.id;$('app-header').open=s.headerExpanded ?? false;
  }
  if (s.mode === 'source') sourceEditor.sync(s.source,s.format==='roc'?'code':'markdown',s.editorSelection);
  // Raw edits can change cell boundaries; do not attach retained observations to
  // newly parsed cells merely because they occupy the same source positions.
  if (reason === 'edit' && s.mode === 'source') for (const view of cards.values()) clearObservations(view);
  if (reason === 'document') renderCells();
  renderSelection();
  if (reason === 'result' || reason === 'edit' || reason === 'diagnostics') renderResults();
  if (!notebook.result) { $('generated').textContent = ''; if (reason === 'status') renderResults(); }
  if (reason === 'saved') void refreshLibrary();
}
function bind() {
  document.addEventListener('focusout', event => {
    const editor = editorFor(event.target); if (!editor) return;
    const { id, revision } = notebook.state;
    queueMicrotask(() => {
      // Ignore editor-internal focus changes, DOM moves and old blur events
      // delivered after another cell has already been edited.
      if (notebook.state.id !== id || notebook.state.revision !== revision || !editor.dom.isConnected || editor.dom.contains(document.activeElement)) return;
      notebook.finishEditing();
      if (selection.mode === 'text' && cards.get(selection.focus)?.editor === editor && notebook.state.cells[cellIndex(selection.focus)]?.collapsed) {
        selection.mode = 'cells';
        renderSelection();
      }
    });
  });
  $('title').oninput = () => notebook.change(s => { s.title = $('title').value; }, {group:'title',source:notebook.state.sourceCurrent,reason:'edit'});
  $('notebook-view').onclick = () => perform(async () => { await notebook.mode('notebook'); if (notebook.state.mode === 'notebook') focusCell(selection.focus); });
  $('source-view').onclick = () => perform(async () => { await notebook.mode('source'); sourceEditor.focus(); });
  $('format').onchange = () => perform(async () => { await notebook.format($('format').value); reflect('document'); });
  $('run').onclick = () => perform(() => notebook.run()); $('stop').onclick = () => notebook.stop();
  $('auto').onchange = () => notebook.setAuto($('auto').checked);
  $('app-header').ontoggle=()=>{
    if(!notebook?.state || notebook.state.mode!=='notebook')return;
    notebook.state.headerExpanded=$('app-header').open;void notebook.persist();
    if($('app-header').open)headerEditor.view.requestMeasure();
  };
  const undo = redo => { notebook.undo(redo); if (notebook.state.mode === 'notebook') focusCell(selection.focus); else sourceEditor.focus(); };
  $('undo').onclick = () => undo(false); $('redo').onclick = () => undo(true);
  $('recovery-copy').onclick=()=>perform(()=>notebook.recoveryCopy());
  $('new').onclick = () => perform(async () => { await notebook.replace(newDraft()); editCell(selection.focus); });
  $('rich-example').onclick=()=>perform(async()=>{const response=await fetch('../fixtures/documents/rich-outputs.roc');if(!response.ok) throw new Error('Example unavailable; rebuild the offline distribution.');await notebook.open(await response.text(),'Rich outputs.roc');closeMenus();});
  $('recent').onchange = () => perform(async () => { if($('recent').value===notebook.state.id) return; const record = await store.get($('recent').value); if (validDraft(record)) await notebook.replace(record); });
  $('open').onchange = () => perform(async () => { const file = $('open').files[0]; if (!file) return; if(file.name.toLowerCase().endsWith('.zip')) {if(file.size>20*1024*1024) throw new Error('Roclet bundles are limited to 20 MiB.');const {record}=await importBundle(await file.arrayBuffer(),compilerManifest);await notebook.replace(record);notice('Imported an independent copy. Saved results are unverified; press Run to recompute.');}else {if (file.size > 256 * 1024) throw new Error('This prototype supports Roclet notebooks up to 256 KiB.'); await notebook.open(await file.text(), file.name);} $('open').value = ''; closeMenus(); if (notebook.state.mode === 'notebook') focusCell(selection.focus); else sourceEditor.focus(); });
  $('preview').onclick = () => perform(async () => { const result = await notebook.inspect('export', 'roc'); $('generated').textContent = result.source; closeMenus(); $('generated-dialog').showModal(); });
  const showProjectFile = path => {
    const files=notebook.state.files ?? [], select=$('project-select'); select.replaceChildren();
    const create=document.createElement('option'); create.value=''; create.textContent='New file'; select.append(create);
    for (const file of files) {const option=document.createElement('option');option.value=file.path;option.textContent=file.path;select.append(option);}
    const file=files.find(file=>file.path===path);select.value=file?.path ?? '';
    $('project-path').value=file?.path ?? ''; $('project-source').value=file?.source ?? '';
    $('project-remove').disabled=!file; $('project-status').textContent=`${files.length} project files saved with this notebook.`;
  };
  $('project-files').onclick=()=>{closeMenus();showProjectFile(notebook.state.files?.[0]?.path);$('project-dialog').showModal();};
  $('project-select').onchange=()=>showProjectFile($('project-select').value);
  $('project-upload').onchange=()=>perform(async()=>{
    const additions=[];
    for(const file of $('project-upload').files) {if(file.size>16*1024*1024) throw new Error('Project sources exceed the 16 MiB limit.'); additions.push({path:file.webkitRelativePath || file.name,source:await file.text()});}
    const paths=new Set(additions.map(file=>file.path));
    notebook.setProjectFiles([...(notebook.state.files ?? []).filter(file=>!paths.has(file.path)),...additions]);
    $('project-upload').value='';showProjectFile(additions[0]?.path);
  });
  $('project-save').onclick=()=>perform(()=>{
    const old=$('project-select').value,path=$('project-path').value,source=$('project-source').value;
    const files=(notebook.state.files ?? []).filter(file=>file.path!==old && file.path!==path);
    notebook.setProjectFiles([...files,{path,source}]);showProjectFile(path);$('project-status').textContent='File saved. Imports update with the next run.';
  });
  $('project-remove').onclick=()=>{notebook.removeProjectFile($('project-select').value);showProjectFile();};
  $('download').onclick = () => perform(async () => {
    const result = await notebook.inspect('export');
    if (notebook.state.format === 'roc' && result.status !== 'ok') throw new Error('Fix the errors before downloading runnable Roc, or switch to Markdown to save unfinished source.');
    const url = URL.createObjectURL(new Blob([result.source], {type:'text/plain;charset=utf-8'}));
    const link = document.createElement('a'); link.href = url; link.download = `${(notebook.state.title || 'notebook').replace(/[^a-z0-9._ -]/gi, '_')}.${notebook.state.format === 'roc' ? 'roc' : 'md'}`; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    notice('Download requested for a separate copy. The original file is not updated.');
  });
  $('share').onclick=()=>{closeMenus();$('share-dialog').showModal();$('share-results').checked=!!notebook.result?.evaluation?.values?.length;$('share-debug').checked=false;$('share-type').dispatchEvent(new Event('change'));};
  $('share-type').onchange=()=>{$('share-source').closest('label').hidden=$('share-type').value==='bundle';};
  $('export-share').onclick=()=>perform(async()=>{
    const button=$('export-share');button.disabled=true;$('share-status').textContent='Preparing export…';
    try {const type=$('share-type').value,capture=await captureExport(notebook,compilerManifest,{results:$('share-results').checked,debug:$('share-debug').checked});
      const blob=type==='report'?await exportReport(capture,{source:$('share-source').checked}):type==='site'?await exportSite(capture,{source:$('share-source').checked}):await exportBundle(capture);
      download(blob,`${downloadName(capture.document.title)}${type==='report'?'.html':type==='site'?'.site.zip':'.roclet.zip'}`);
      $('share-status').textContent=`Download requested · ${capture.snapshots.length} result snapshots, ${capture.events.length} debug messages. ${type==='site'?'Extract and serve over HTTPS or localhost.':''}`;
    }finally {button.disabled=false;}
  });
  $('offline').onclick=()=>perform(async()=>{closeMenus();$('offline-dialog').showModal();$('offline-state').textContent='Verifying offline files…';try {$('offline-state').textContent=(await offlineStatus()).label;}catch(error){$('offline-state').textContent=error.message;}$('storage-state').textContent=await storageStatus();});
  $('prepare-offline').onclick=()=>perform(async()=>{const b=$('prepare-offline');b.disabled=true;$('offline-state').textContent='Downloading and verifying Roclet and its compiler…';try {$('offline-state').textContent=(await prepareOffline()).label;}catch(error){$('offline-state').textContent=error.message;}finally {b.disabled=false;}});
  $('persist-storage').onclick=()=>perform(async()=>{$('storage-state').textContent=await storageStatus(true);});
  $('find').onclick=findNotebook;$('find-query').oninput=updateFind;
  $('back-notebook').onclick = $('notebook-view').onclick;
  const help = () => { closeMenus(); $('shortcuts-dialog').showModal(); };
  $('help').onclick = help; $('shortcuts').onclick = help;
  document.querySelectorAll('[data-close]').forEach(b => b.onclick = () => b.closest('dialog').close());
  document.addEventListener('click', event => {
    const menu = event.target.closest('details.popover'); closeMenus(menu);
    if (event.target.closest('.menu-panel button,.menu-panel a')) closeMenus();
  });
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.isComposing || composing || event.keyCode === 229 || document.querySelector('dialog[open]')) return;
    const mod = event.metaKey || event.ctrlKey, key = event.key.toLowerCase();
    const target = event.target, card = target.closest?.('.cell');
    const menu = target.closest?.('details[open]');
    if (event.key === 'Escape' && menu) { event.preventDefault(); event.stopPropagation(); menu.open = false; menu.querySelector('summary').focus(); return; }
    if (mod && event.shiftKey && key==='f') {event.preventDefault();event.stopPropagation();findNotebook();return;}
    const inNotebook = notebook.state.mode === 'notebook' && $('notebook').contains(target);
    if(event.key==='Escape' && target.closest?.('.cm-search')) return;
    if (event.key === 'Escape' && editorFor(target) === sourceEditor) { event.preventDefault(); event.stopPropagation(); notebook.finishEditing(); sourceEditor.element.blur(); return; }
    if (event.key === 'Escape' && editorFor(target)?.closeCompletion()) {event.preventDefault();event.stopPropagation();return;}
    if (event.key === 'Escape' && inNotebook) { event.preventDefault(); event.stopPropagation(); focusCell(card?.dataset.key ?? selection.focus); return; }
    if (mod && key === 's') { event.preventDefault(); event.stopPropagation(); $('download').click(); return; }
    // Title, selects and menus retain native editing/navigation behavior.
    const editor = !!editorFor(target);
    if (mod && key === 'z' && (editor || (inNotebook && selection.mode === 'cells') || target === document.body)) {
      event.preventDefault(); event.stopPropagation(); const wasCells = selection.mode === 'cells'; notebook.undo(event.shiftKey, { editing: editor });
      if (wasCells && inNotebook) focusCell(selection.focus); return;
    }
    if(editorFor(target)===headerEditor && mod && event.key==='Enter') {event.preventDefault();event.stopPropagation();void perform(()=>notebook.run());return;}
    if (!inNotebook || menu || target.closest?.('button,summary,select')) return;
    if(mod && event.shiftKey && (key==='-' || key==='_') && card) {event.preventDefault();event.stopPropagation();void perform(()=>splitCell(card.dataset.key));return;}
    if (event.key === 'Enter' && (mod || event.shiftKey || event.altKey) && card) {
      event.preventDefault(); event.stopPropagation(); void perform(() => runCell(card.dataset.key, event.shiftKey && !mod, event.altKey && !mod)); return;
    }
    if (textTarget(target) || selection.mode !== 'cells') return;
    if (mod && key === 'a') { event.preventDefault(); event.stopPropagation(); selection.all(); selectionActive = true; renderSelection(); cards.get(selection.focus)?.card.focus(); return; }
    if (mod || event.altKey) return;
    if(event.shiftKey && key==='m') {event.preventDefault();event.stopPropagation();void perform(()=>mergeCells(selection.selected));return;}
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
      event.preventDefault(); event.stopPropagation(); selection.move(event.key === 'ArrowUp' ? -1 : 1, event.shiftKey); focusCell(selection.focus, true);
    } else if (event.key === 'Enter') { event.preventDefault(); event.stopPropagation(); editCell(selection.focus); }
    else if (!event.shiftKey && (key === 'a' || key === 'b')) { event.preventDefault(); event.stopPropagation(); void perform(() => insertAtSelection(key === 'b')); }
    else if (event.key === 'Backspace' || event.key === 'Delete') { event.preventDefault(); event.stopPropagation(); removeCells(selection.selected); }
    else if (event.key === '?') { event.preventDefault(); event.stopPropagation(); help(); }
  }, true);
  const ownsClipboard = event => notebook.state.mode === 'notebook' && selection.mode === 'cells' && $('notebook').contains(event.target) && !textTarget(event.target) && !event.target.closest?.('details,button,a');
  for (const action of ['copy','cut']) document.addEventListener(action, event => {
    if (!ownsClipboard(event) || !selection.selected.length || !event.clipboardData || window.getSelection()?.toString()) return;
    const keys = selection.selected, cells = editable().filter(c => keys.includes(c.key)), encoded = encodeCells(cells);
    try {
      // A plain-text envelope also preserves boundaries in browsers that strip custom MIME data.
      event.clipboardData.setData('text/plain', encoded);
      try { event.clipboardData.setData(cellMime, encoded); } catch { /* text/plain is sufficient */ }
      event.preventDefault(); event.stopPropagation(); if (action === 'cut') removeCells(keys);
      $('selection-status').textContent = `${cells.length} cell${cells.length === 1 ? '' : 's'} ${action === 'cut' ? 'cut' : 'copied'}`;
    } catch { notice('The clipboard could not be written. The cells were kept.'); }
  });
  document.addEventListener('paste', event => {
    if (!ownsClipboard(event) || !event.clipboardData) return;
    const structured = event.clipboardData.getData(cellMime), text = structured || event.clipboardData.getData('text/plain');
    if (!text) return;
    event.preventDefault(); event.stopPropagation(); void perform(() => {
      const additions = decodeCells(text, !!structured); if (!additions.length) return;
      insertCells(selection.keys.indexOf(selection.selected.at(-1)) + 1, additions);
    });
  });
  window.addEventListener('beforeunload', event => { if (notebook.saveStatus !== 'Saved in this browser') { event.preventDefault(); event.stopPropagation(); event.returnValue = ''; } });
}
export async function startNotebook(drafts = new DraftStore()) {
store = drafts;
try {
  const [binary, manifest] = await Promise.all([fetch('../artifacts/roclet.wasm').then(r => { if (!r.ok) throw new Error('Build the compiler adapter first.'); return r.arrayBuffer(); }), fetch('../artifacts/manifest.json').then(r => r.json())]);
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', binary))].map(v => v.toString(16).padStart(2,'0')).join('');
  if (hash !== manifest.artifacts['roclet.wasm'].sha256) throw new Error('Compiler artifact does not match its manifest. Rebuild or refresh Roclet.');
  compilerManifest=manifest;
  highlighter=new CompilerHighlighter(binary);
  sourceEditor=new CellEditor($('source'),{highlighter,
    label:'Roclet notebook source',onChange:(value,isComposing,positions)=>notebook.editSource(value,isComposing || composing,positions),
    onSelection:positions=>{if(notebook?.state) {notebook.state.editorSelection=positions;notebook.group=null;}},
    onComposition:value=>{composing=value;if(value) clearTimeout(notebook.timer);else notebook.schedule();},
  });
  headerEditor=new CellEditor($('app-header-source'),{highlighter,label:'Roc app header',
    onChange:(value,isComposing,positions)=>notebook.editPreamble(value,isComposing || composing,positions),
    onFocus:()=>{notebook.finishEditing();selectionActive=false;renderSelection();},
    onSelection:positions=>{if(notebook?.state){notebook.state.headerSelection=positions;notebook.group=null;}},
    onComposition:value=>{composing=value;if(value)clearTimeout(notebook.timer);else notebook.schedule();},
  });
  notebook = new Notebook(binary, store, {onChange:reflect,loadPackage:loadPackageBundle});
  const dispose=notebook.dispose.bind(notebook);
  notebook.dispose=()=>{highlighter.dispose();sourceEditor.destroy();headerEditor.destroy();for(const view of cards.values()) view.editor.destroy();dispose();};
  bind(); await notebook.initialize();
  const example=new URL(location.href).searchParams.get('example');
  const examples = new Map([
    ['reactivity', ['../demos/01-reactivity.roc', 'A result before its ingredients.roc']],
    ['weather', ['../demos/02-a-little-data.roc', 'Three days of weather.roc']],
    ['circle', ['../demos/03-circle.roc', 'A bigger circle.roc']],
    ['meeting-windows', ['../demos/04-meeting-windows.roc', 'Finding room for a design review.roc']],
    ['rich-outputs', ['../fixtures/documents/rich-outputs.roc', 'Rich outputs.roc']],
  ]);
  if (example) {
    // Only bundled examples, never arbitrary URLs supplied by a query parameter.
    clearTimeout(notebook.timer);
    try {
      const entry=examples.get(example);if(!entry) throw new Error('Unknown example.');
      const response=await fetch(entry[0]);if(!response.ok) throw new Error('Example is unavailable.');
      await notebook.open(await response.text(),entry[1]);
      notice('Opened your own editable copy. Download a copy to keep your changes.');
      const url=new URL(location.href);url.searchParams.delete('example');history.replaceState(null,'',url.pathname+url.search+url.hash);
    } catch(error) {notice(`Example could not be opened: ${error.message}`);}
  }
  const publication=new URL(location.href).searchParams.get('publication');
  if(publication==='published.roclet.zip') {
    // A fixed filename, never an arbitrary URL import; new copies never auto-run.
    clearTimeout(notebook.timer);
    try {const response=await fetch('./published.roclet.zip');if(!response.ok) throw new Error('Publication is missing.');const {record}=await importBundle(await response.arrayBuffer(),manifest);await notebook.replace(record);notice('Opened your own editable copy. Press Run to recompute.');history.replaceState(null,'',location.pathname);}
    catch(error) {notice(`Publication could not be opened: ${error.message}`);}
  }
  document.documentElement.dataset.ready = 'true'; return notebook;
} catch (error) { $('status').textContent = 'Roclet could not start'; notice(error.message); }

}
