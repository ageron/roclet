import { prepareOffline, offlineStatus, storageStatus } from './offline.mjs';
import { captureExport, exportBundle, importBundle, exportReport, exportSite, download, downloadName } from './sharing.mjs';
import { validDraft } from './edit-model.mjs';
import { editorFor } from './cell-editor.mjs';
import { CompilerHighlighter } from './roc-highlighting.mjs';
import { DraftStore } from './edit-store.mjs';
import { loadPackageBundle } from './package-dialog.mjs';
import { NotebookPanel, closeMenus, showHelp } from './notebook-panel.mjs';
import { clonePanel, engineDetailsKey, readPreference, writePreference } from './workbench.mjs';
const $ = id => document.getElementById(id);
let compilerManifest, libraryToken = 0, panel;
const storage = (() => { try { return globalThis.localStorage; } catch { return null; } })();
const preferences = { engineDetails: readPreference(storage, engineDetailsKey) };
// Header commands act on the active panel.
const active = () => panel;
async function refreshLibrary() {
  const token = ++libraryToken, target = active();
  try {
    const records = (await target.store.list()).filter(validDraft);
    if (token !== libraryToken) return;
    $('recent').replaceChildren();
    for (const record of records) { const option = document.createElement('option'); option.value = record.id; option.textContent = record.title || 'Untitled'; option.selected = record.id === target.notebook.state.id; $('recent').append(option); }
  } catch { /* The persistent save-status message already explains the failure. */ }
}
// Header state that mirrors the active panel's notebook.
function reflectHeader(reason) {
  const notebook = active().notebook;
  if (!notebook?.state) return;
  const s = notebook.state;
  document.title = `${s.title || 'Untitled'} — Roclet`;
  $('format').value = s.format;
  $('recovery-copy').hidden=!/^Not saved/.test(notebook.saveStatus);
  $('undo').disabled = !notebook.history.length; $('redo').disabled = !notebook.future.length;
  $('notebook-view').setAttribute('aria-pressed', s.mode === 'notebook'); $('source-view').setAttribute('aria-pressed', s.mode === 'source');
  $('engine-details').setAttribute('aria-pressed', preferences.engineDetails);
  if (!notebook.result) $('generated').textContent = '';
  if (reason === 'saved') void refreshLibrary();
}
function bind() {
  const perform = work => active().perform(work);
  const notebook = () => active().notebook;
  $('notebook-view').onclick = () => active().setMode('notebook');
  $('source-view').onclick = () => active().setMode('source');
  $('format').onchange = () => perform(async () => { await notebook().format($('format').value); active().render('document'); });
  $('undo').onclick = () => active().undo(false); $('redo').onclick = () => active().undo(true);
  $('recovery-copy').onclick=()=>perform(()=>notebook().recoveryCopy());
  $('new').onclick = () => active().newDocument();
  $('rich-example').onclick=()=>perform(async()=>{const response=await fetch('../fixtures/documents/rich-outputs.roc');if(!response.ok) throw new Error('Example unavailable; rebuild the offline distribution.');await notebook().open(await response.text(),'Rich outputs.roc');closeMenus();});
  $('recent').onchange = () => perform(async () => { if($('recent').value===notebook().state.id) return; const record = await active().store.get($('recent').value); if (validDraft(record)) await notebook().replace(record); });
  $('open').onchange = () => perform(async () => { const target = active(), file = $('open').files[0]; if (!file) return; if(file.name.toLowerCase().endsWith('.zip')) {if(file.size>20*1024*1024) throw new Error('Roclet bundles are limited to 20 MiB.');const {record}=await importBundle(await file.arrayBuffer(),compilerManifest);await target.notebook.replace(record);target.notice('Imported an independent copy. Saved results are unverified; press Run to recompute.');}else {if (file.size > 256 * 1024) throw new Error('This prototype supports Roclet notebooks up to 256 KiB.'); await target.notebook.open(await file.text(), file.name);} $('open').value = ''; closeMenus(); target.focusSelection(); });
  $('preview').onclick = () => perform(async () => { const result = await notebook().inspect('export', 'roc'); $('generated').textContent = result.source; closeMenus(); $('generated-dialog').showModal(); });
  // Dialogs are shared by the page and bound to the panel active when opened.
  const showProjectFile = (target, path) => {
    const files=target.notebook.state.files ?? [], select=$('project-select'); select.replaceChildren();
    const create=document.createElement('option'); create.value=''; create.textContent='New file'; select.append(create);
    for (const file of files) {const option=document.createElement('option');option.value=file.path;option.textContent=file.path;select.append(option);}
    const file=files.find(file=>file.path===path);select.value=file?.path ?? '';
    $('project-path').value=file?.path ?? ''; $('project-source').value=file?.source ?? '';
    $('project-remove').disabled=!file; $('project-status').textContent=`${files.length} project files saved with this notebook.`;
  };
  $('project-files').onclick=()=>{
    const target=active(), project=target.notebook;closeMenus();
    $('project-select').onchange=()=>showProjectFile(target,$('project-select').value);
    $('project-upload').onchange=()=>target.perform(async()=>{
      const additions=[];
      for(const file of $('project-upload').files) {if(file.size>16*1024*1024) throw new Error('Project sources exceed the 16 MiB limit.'); additions.push({path:file.webkitRelativePath || file.name,source:await file.text()});}
      const paths=new Set(additions.map(file=>file.path));
      project.setProjectFiles([...(project.state.files ?? []).filter(file=>!paths.has(file.path)),...additions]);
      $('project-upload').value='';showProjectFile(target,additions[0]?.path);
    });
    $('project-save').onclick=()=>target.perform(()=>{
      const old=$('project-select').value,path=$('project-path').value,source=$('project-source').value;
      const files=(project.state.files ?? []).filter(file=>file.path!==old && file.path!==path);
      project.setProjectFiles([...files,{path,source}]);showProjectFile(target,path);$('project-status').textContent='File saved. Imports update with the next run.';
    });
    $('project-remove').onclick=()=>{project.removeProjectFile($('project-select').value);showProjectFile(target);};
    showProjectFile(target,project.state.files?.[0]?.path);$('project-dialog').showModal();
  };
  $('download').onclick = () => { const target = active(); return target.perform(async () => {
    const notebook = target.notebook, result = await notebook.inspect('export');
    if (notebook.state.format === 'roc' && result.status !== 'ok') throw new Error('Fix the errors before downloading runnable Roc, or switch to Markdown to save unfinished source.');
    const url = URL.createObjectURL(new Blob([result.source], {type:'text/plain;charset=utf-8'}));
    const link = document.createElement('a'); link.href = url; link.download = `${(notebook.state.title || 'notebook').replace(/[^a-z0-9._ -]/gi, '_')}.${notebook.state.format === 'roc' ? 'roc' : 'md'}`; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    target.notice('Download requested for a separate copy. The original file is not updated.');
  }); };
  $('share').onclick=()=>{
    const target=active();closeMenus();$('share-dialog').showModal();$('share-results').checked=!!target.notebook.result?.evaluation?.values?.length;$('share-debug').checked=false;$('share-type').dispatchEvent(new Event('change'));
    $('export-share').onclick=()=>target.perform(async()=>{
      const button=$('export-share');button.disabled=true;$('share-status').textContent='Preparing export…';
      try {const type=$('share-type').value,capture=await captureExport(target.notebook,compilerManifest,{results:$('share-results').checked,debug:$('share-debug').checked});
        const blob=type==='report'?await exportReport(capture,{source:$('share-source').checked}):type==='site'?await exportSite(capture,{source:$('share-source').checked}):await exportBundle(capture);
        download(blob,`${downloadName(capture.document.title)}${type==='report'?'.html':type==='site'?'.site.zip':'.roclet.zip'}`);
        $('share-status').textContent=`Download requested · ${capture.snapshots.length} result snapshots, ${capture.events.length} debug messages. ${type==='site'?'Extract and serve over HTTPS or localhost.':''}`;
      }finally {button.disabled=false;}
    });
  };
  $('share-type').onchange=()=>{$('share-source').closest('label').hidden=$('share-type').value==='bundle';};
  $('offline').onclick=()=>perform(async()=>{closeMenus();$('offline-dialog').showModal();$('offline-state').textContent='Verifying offline files…';try {$('offline-state').textContent=(await offlineStatus()).label;}catch(error){$('offline-state').textContent=error.message;}$('storage-state').textContent=await storageStatus();});
  $('prepare-offline').onclick=()=>perform(async()=>{const b=$('prepare-offline');b.disabled=true;$('offline-state').textContent='Downloading and verifying Roclet and its compiler…';try {$('offline-state').textContent=(await prepareOffline()).label;}catch(error){$('offline-state').textContent=error.message;}finally {b.disabled=false;}});
  $('persist-storage').onclick=()=>perform(async()=>{$('storage-state').textContent=await storageStatus(true);});
  $('find').onclick=()=>active().find();
  $('engine-details').onclick=()=>{
    preferences.engineDetails=!preferences.engineDetails;writePreference(storage,engineDetailsKey,preferences.engineDetails);
    for(const target of [panel]) target.render('status');
    reflectHeader('status');
  };
  $('shortcuts').onclick = showHelp;
  document.querySelectorAll('[data-close]').forEach(b => b.onclick = () => b.closest('dialog').close());
  document.addEventListener('click', event => {
    const menu = event.target.closest('details.popover'); closeMenus(menu);
    if (event.target.closest('.menu-panel button,.menu-panel a')) closeMenus();
  });
  // Page-level shortcuts. Each panel registers its own capture-phase handler on
  // its root, which runs after this one for targets inside that panel.
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229 || document.querySelector('dialog[open]')) return;
    const mod = event.metaKey || event.ctrlKey, key = event.key.toLowerCase(), target = event.target;
    const menu = target.closest?.('details[open]');
    if (event.key === 'Escape' && menu) { event.preventDefault(); event.stopPropagation(); menu.open = false; menu.querySelector('summary').focus(); return; }
    if (mod && event.shiftKey && key==='f') {event.preventDefault();event.stopPropagation();active().find();return;}
    if (mod && key === 's') { event.preventDefault(); event.stopPropagation(); $('download').click(); return; }
    if (target !== document.body || !active().notebook.state) return;
    if (mod && key === 'z') { event.preventDefault(); event.stopPropagation(); active().notebook.undo(event.shiftKey, { editing: !!editorFor(target) }); }
  }, true);
  window.addEventListener('beforeunload', event => { if (active().notebook.saveStatus !== 'Saved in this browser') { event.preventDefault(); event.stopPropagation(); event.returnValue = ''; } });
}
export async function startNotebook(drafts = new DraftStore()) {
// The panel markup exists before the compiler loads so its status is visible.
const root = clonePanel($('notebook-panel-template'), '');
$('workbench').append(root);
try {
  const [binary, manifest] = await Promise.all([fetch('../artifacts/roclet.wasm').then(r => { if (!r.ok) throw new Error('Build the compiler adapter first.'); return r.arrayBuffer(); }), fetch('../artifacts/manifest.json').then(r => r.json())]);
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', binary))].map(v => v.toString(16).padStart(2,'0')).join('');
  if (hash !== manifest.artifacts['roclet.wasm'].sha256) throw new Error('Compiler artifact does not match its manifest. Rebuild or refresh Roclet.');
  compilerManifest=manifest;
  const highlighter=new CompilerHighlighter(binary);
  panel = new NotebookPanel({root, bytes:binary, highlighter, store:drafts, loadPackage:loadPackageBundle, preferences, onChange:(_,reason)=>reflectHeader(reason)});
  const notebook = panel.notebook;
  notebook.dispose=()=>{highlighter.dispose();panel.dispose();};
  bind();
  const launch = new URL(location.href);
  const id = launch.searchParams.get('notebook'), fresh = launch.searchParams.get('new') === '1';
  await notebook.initialize({id, fresh});
  if (id || fresh) {launch.searchParams.delete('notebook');launch.searchParams.delete('new');history.replaceState(null,'',launch.pathname+launch.search+launch.hash);}
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
      panel.notice('Opened your own editable copy. Download a copy to keep your changes.');
      const url=new URL(location.href);url.searchParams.delete('example');history.replaceState(null,'',url.pathname+url.search+url.hash);
    } catch(error) {panel.notice(`Example could not be opened: ${error.message}`);}
  }
  const publication=new URL(location.href).searchParams.get('publication');
  if(publication==='published.roclet.zip') {
    // A fixed filename, never an arbitrary URL import; new copies never auto-run.
    clearTimeout(notebook.timer);
    try {const response=await fetch('./published.roclet.zip');if(!response.ok) throw new Error('Publication is missing.');const {record}=await importBundle(await response.arrayBuffer(),manifest);await notebook.replace(record);panel.notice('Opened your own editable copy. Press Run to recompute.');history.replaceState(null,'',location.pathname);}
    catch(error) {panel.notice(`Publication could not be opened: ${error.message}`);}
  }
  document.documentElement.dataset.ready = 'true'; return notebook;
} catch (error) { $('status').textContent = 'Roclet could not start'; $('notice').textContent = error.message; $('notice').hidden = false; }

}
