import {inputValues} from './input-values.mjs';
import {zip,unzip,utf8,text} from './archive.mjs';
import {sha256,verified} from './offline-cache.mjs';
import {workerSource} from './offline.mjs';
import {newDraft,makeCell,validDraft} from './edit-model.mjs';
import {embedMathStyles} from './math-view.mjs';
import {renderMarkdown} from './markdown-view.mjs';
import {renderDisplay,normalizeDisplay} from './display-view.mjs';
import {projectFiles,projectPath} from './project-files.mjs';
export const downloadName = title => (title||'notebook').replace(/[^a-z0-9._ -]/gi,'_').slice(0,120);
export function download(blob,name) {
  const url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(url),5000);
}
export async function captureExport(notebook,compiler,{results=false,debug=false}={}) {
  const state=structuredClone(notebook.state),current=structuredClone(notebook.result);
  const parsed=await notebook.inspect('export');
  if(state.format==='roc' && parsed.status!=='ok') throw new Error('Fix the errors before exporting runnable Roc, or switch to Markdown to save unfinished source.');
  const document={schema:1,title:state.title,format:state.format,preamble:state.preamble??'',metadata:state.metadata??'',source:state.sourceCurrent?state.source:'',sourceCurrent:!!state.sourceCurrent,mode:state.mode,
    inputValues:inputValues(state.inputValues),files:projectFiles(state.files),
    cells:(state.sourceCurrent?(parsed.draft?.cells??parsed.model.cells):state.cells).map(({kind,source,attributes,outputs})=>({kind,source,attributes:attributes??'',outputs:outputs??[]}))};
  const snapshots=results && ['ok','partial'].includes(current?.status) ? (current.evaluation?.values??[]).map(v=>({cell:current.model.cells.findIndex(c=>c.output===v.root),root:v.root,text:v.text,...(v.display?{display:normalizeDisplay(v.display)}:{})})) : [];
  const events=debug ? (current?.evaluation?.events??[]).map(({cell,root,kind,message})=>({cell,root,kind,message})) : [];
  return {document,source:parsed.source,model:parsed.model,rendering:parsed.rendering??[],snapshots,events,compiler:{commit:compiler.compilerCommit,wasmSha256:compiler.artifacts['roclet.wasm'].sha256,displaySha256:compiler.inputs['package/Display.roc']},createdAt:new Date().toISOString()};
}
export async function bundleFiles(capture) {
  const sourcePath=capture.document.format==='roc'?'notebook.roc':'notebook.md';
  const sources=projectFiles(capture.document.files);
  const document={...capture.document,files:sources.map(({path})=>({path}))};
  const files=new Map([[sourcePath,utf8(capture.source)],['document.json',utf8(JSON.stringify(document))]]);
  for(const file of sources) files.set(`project/${file.path}`,utf8(file.source));
  if(capture.snapshots.length || capture.events.length) files.set('results.json',utf8(JSON.stringify({snapshots:capture.snapshots,events:capture.events,createdAt:capture.createdAt})));
  const entries=[];for(const [path,bytes] of files) entries.push({path,bytes:bytes.length,sha256:await sha256(bytes)});
  files.set('roclet.json',utf8(JSON.stringify({schema:1,type:'roclet-notebook',title:capture.document.title,source:sourcePath,compiler:capture.compiler,createdAt:capture.createdAt,files:entries},null,2)));
  return files;
}
export async function exportBundle(capture) {return zip(await bundleFiles(capture));}
export async function importBundle(bytes,compiler) {
  const files=await unzip(bytes,{maxBytes:20*1024*1024,maxEntries:272}),raw=files.get('roclet.json');if(!raw) throw new Error('This ZIP is not a Roclet bundle.');
  const manifest=JSON.parse(text(raw));
  if(manifest.schema!==1 || manifest.type!=='roclet-notebook' || !Array.isArray(manifest.files) || !['notebook.roc','notebook.md'].includes(manifest.source)) throw new Error('Unsupported Roclet bundle version.');
  if(manifest.compiler?.wasmSha256!==compiler.artifacts['roclet.wasm'].sha256 || manifest.compiler?.commit!==compiler.compilerCommit) throw new Error('This bundle requires another compiler version. Open it with the matching Roclet distribution.');
  const paths=new Set();
  for(const entry of manifest.files) {
    const project=typeof entry.path==='string' && entry.path.startsWith('project/');
    if(project) projectPath(entry.path.slice(8));
    if((!project && !['notebook.roc','notebook.md','document.json','results.json','Display.roc'].includes(entry.path)) || paths.has(entry.path)) throw new Error('Unsupported or duplicate bundle entry.');
    if(entry.path==='Display.roc' && entry.sha256!==compiler.inputs?.['package/Display.roc']) throw new Error('Bundled Display module does not match this compiler distribution.');
    paths.add(entry.path);const file=files.get(entry.path);
    if(!file || file.length!==entry.bytes || await sha256(file)!==entry.sha256) throw new Error(`Bundle integrity check failed: ${entry.path}`);
  }
  if(files.size!==paths.size+1 || !paths.has('document.json') || !paths.has(manifest.source)) throw new Error('Incomplete bundle manifest.');
  const doc=JSON.parse(text(files.get('document.json')));
  if(doc.schema!==1 || !['roc','markdown'].includes(doc.format) || typeof doc.title!=='string' || doc.title.length>120 || typeof doc.source!=='string' || typeof doc.preamble!=='string' || typeof doc.metadata!=='string' || typeof doc.sourceCurrent!=='boolean' || !['source','notebook'].includes(doc.mode) || !Array.isArray(doc.cells) || doc.cells.length>500) throw new Error('Malformed notebook in bundle.');
  const record=newDraft(doc.title);
  record.inputValues=inputValues(doc.inputValues);
  record.format=doc.format;record.source=doc.source;record.sourceCurrent=doc.sourceCurrent;record.preamble=doc.preamble;record.metadata=doc.metadata;record.mode=doc.mode;record.autoRun=false;
  if(doc.files!=null && !Array.isArray(doc.files)) throw new Error('Malformed project file list.');
  record.files=projectFiles((doc.files??[]).map(file=>{
    const path=projectPath(file?.path),member=`project/${path}`;
    if(!paths.has(member)) throw new Error(`Project file is missing: ${path}`);
    return {path,source:text(files.get(member))};
  }));
  if([...paths].filter(path=>path.startsWith('project/')).length!==record.files.length) throw new Error('Unexpected project files in bundle.');
  record.cells=doc.cells.map(c=>{
    if(!['code','markdown','generated'].includes(c.kind) || typeof c.source!=='string' || typeof c.attributes!=='string' || !Array.isArray(c.outputs) || c.outputs.some(o=>!o || typeof o.source!=='string' || typeof o.kind!=='string')) throw new Error('Malformed cell in bundle.');
    return {...makeCell(c.kind,c.source),attributes:c.attributes,outputs:c.outputs};
  });
  if(!validDraft(record) || utf8(record.source+record.preamble+record.metadata+record.cells.map(c=>c.source+c.attributes+c.outputs.map(o=>o.source).join('')).join('')).length>256*1024) throw new Error('Notebook exceeds the 256 KiB limit.');
  if(paths.has('results.json')) {
    const saved=JSON.parse(text(files.get('results.json')));
    if(!Array.isArray(saved.snapshots) || saved.snapshots.length>500 || !Array.isArray(saved.events) || saved.events.length>1001 || saved.snapshots.some(s=>!Number.isInteger(s.cell)||s.cell<0||s.cell>=record.cells.length||typeof s.text!=='string'||typeof s.root!=='string') || saved.events.some(e=>typeof e.message!=='string'||typeof e.kind!=='string'||(e.cell!=null&&(!Number.isInteger(e.cell)||e.cell<0||e.cell>=record.cells.length)))) throw new Error('Malformed saved results.');
    saved.snapshots=saved.snapshots.map(s=>({...s,display:normalizeDisplay(s.display)}));
    record.savedResults=saved;
  }
  return {record,manifest};
}
export async function exportReport(capture,{source=true}={}) {
  const doc=document.implementation.createHTMLDocument(capture.document.title),meta=doc.createElement('meta');
  meta.httpEquiv='Content-Security-Policy';meta.content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src 'self'; base-uri 'none'; form-action 'none'";doc.head.prepend(meta);
  const charset=doc.createElement('meta');charset.setAttribute('charset','utf-8');doc.head.prepend(charset);
  const viewport=doc.createElement('meta');viewport.name='viewport';viewport.content='width=device-width, initial-scale=1';doc.head.append(viewport);
  const css=doc.createElement('style');css.textContent='body{max-width:850px;margin:3rem auto;padding:0 1.5rem;font:16px/1.65 system-ui;color:#294338}h1,h2,h3{line-height:1.2}section{margin:1.8rem 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:1rem;background:#f4f7f4;border-radius:6px;font:14px/1.6 monospace}small{color:#65766a}table{border-collapse:collapse}th,td{border:1px solid #ddd;padding:.4rem}a{color:#356e58}.display-table-scroll{overflow:auto}.display-image{max-width:100%;max-height:480px}.display-note,.display-pagination{font-size:.8rem;color:#65766a}';doc.head.append(css);
  const title=doc.createElement('h1');title.textContent=capture.document.title;doc.body.append(title);
  const provenance=doc.createElement('small');provenance.textContent=`Exported ${capture.createdAt}. Saved results are snapshots, not a live execution. Source SHA-256: ${await sha256(utf8(capture.source))}. Compiler ${capture.compiler.commit}.`;doc.body.append(provenance);
  const add=(section,label,value)=>{const heading=doc.createElement('small'),pre=doc.createElement('pre');heading.textContent=label;pre.textContent=value;section.append(heading,pre);};
  for(const [index,cell] of capture.model.cells.entries()) {
    if(cell.kind==='generated') continue;const section=doc.createElement('section');
    if(cell.kind==='markdown') {const rendering=capture.rendering.find(r=>r.cell===index);if(rendering) section.append(renderMarkdown(rendering.events,doc));else add(section,'Markdown',cell.source);}
    else if(source) add(section,'Roc',cell.source);
    for(const snapshot of capture.snapshots.filter(s=>s.cell===index)) {const rich=renderDisplay(snapshot.display,snapshot.text,{doc,interactive:false});if(rich) {const label=doc.createElement('small');label.textContent='Result snapshot';section.append(label,rich);}else add(section,'Result snapshot',snapshot.text);}
    for(const event of capture.events.filter(e=>e.cell===index)) add(section,`Debug snapshot · ${event.kind}`,event.message);
    if(section.childNodes.length) doc.body.append(section);
  }
  if(capture.model.diagnostics?.length) {const section=doc.createElement('section');for(const d of capture.model.diagnostics) add(section,d.code,d.message);doc.body.append(section);}
  await embedMathStyles(doc);
  return new Blob(['<!doctype html>\n',doc.documentElement.outerHTML],{type:'text/html;charset=utf-8'});
}
export async function exportSite(capture,reportOptions={}) {
  const base=new URL('./',import.meta.url),response=await fetch(new URL('offline-release.json',base));if(!response.ok) throw new Error('Build the offline distribution first.');
  const release=await response.json(),files=new Map();
  for(const asset of release.assets) {
    const url=new URL(asset.path,base),path=asset.path.startsWith('../')?asset.path.slice(3):`web/${asset.path}`;
    files.set(path,new Uint8Array(await verified(await fetch(url),asset)));
  }
  // Runtime and source are immutable copies. A recipient explicitly opens their
  // own draft, with automatic evaluation off, and never edits the publication.
  files.set('web/offline-release.json',utf8(JSON.stringify(release)));
  files.set('web/offline-worker.mjs',utf8(workerSource(release)));
  const bundle=new Uint8Array(await (await exportBundle(capture)).arrayBuffer());files.set('web/published.roclet.zip',bundle);
  files.set('index.html',utf8('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Roclet notebook</title><style>body{font:18px/1.6 system-ui;max-width:650px;margin:10vh auto;padding:2rem}a{color:#356e58}</style><h1>Roclet notebook</h1><p><a href="web/edit.html?publication=published.roclet.zip">Open an editable copy in Roclet</a></p><p><a href="report.html">Read the static report</a> · <a href="web/published.roclet.zip" download>Download the Roclet bundle</a></p><p>Run this folder on HTTPS or a localhost static server. All computation stays in your browser.</p></html>'));
  files.set('report.html',new Uint8Array(await (await exportReport(capture,reportOptions)).arrayBuffer()));
  files.set('README.txt',utf8('Serve this extracted directory with any static HTTP server (HTTPS or localhost). Open index.html. No build, Node, accounts, or CDN needed. File URLs are not supported. The editable copy is saved only in the recipient browser. Choose File > Offline & storage > Prepare for offline use before disconnecting. The separate report.html opens directly without a server.\n'));
  // Include the publication in this site's offline release as well.
  release.assets.push({path:'published.roclet.zip',bytes:bundle.length,sha256:await sha256(bundle)});
  const landing=files.get('index.html'),entry=release.assets.find(a=>a.path==='../index.html');
  if(entry) Object.assign(entry,{bytes:landing.length,sha256:await sha256(landing)});
  release.version=await sha256(utf8(JSON.stringify(release.assets)));
  files.set('web/offline-release.json',utf8(JSON.stringify(release)));
  files.set('web/offline-worker.mjs',utf8(workerSource(release)));
  return zip(files);
}
