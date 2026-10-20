import {newDraft,makeCell} from './edit-model.mjs';
import {assert} from '../tests/harness.mjs';

const status=document.getElementById('status'),log=document.getElementById('log');
const html=await fetch('./edit.html').then(response=>response.text());
const frames=[];
const report=message=>{log.textContent+=`PASS ${message}\n`;};
const until=async predicate=>{
  for(let i=0;i<1500;i++){if(predicate())return;await new Promise(resolve=>setTimeout(resolve,20));}
  throw new Error('Timed out waiting for notebook startup');
};
async function fixture({moduleError=false}={}) {
  const page=new DOMParser().parseFromString(html,'text/html');
  const bootstrap=page.getElementById('notebook-bootstrap');
  assert(bootstrap,'Missing notebook bootstrap');
  const program=bootstrap.textContent;
  bootstrap.type='application/x-held-bootstrap';
  if(moduleError) {
    const map=page.querySelector('script[type=importmap]'),imports=JSON.parse(map.textContent);
    imports.imports['./edit.mjs']='data:text/javascript,throw new Error("Startup module unavailable")';
    map.textContent=JSON.stringify(imports);
  }
  const frame=globalThis.document.createElement('iframe');frame.title='Isolated notebook startup test';frames.push(frame);
  frame.srcdoc='<!doctype html>'+page.documentElement.outerHTML;
  globalThis.document.body.append(frame);
  await new Promise(resolve=>frame.addEventListener('load',resolve,{once:true}));
  const window=frame.contentWindow,document=frame.contentDocument;
  const start=(source=program)=>{
    const script=document.createElement('script');script.type='module';script.textContent=source;document.body.append(script);
  };
  const hidden=()=>window.getComputedStyle(document.getElementById('notebook-app')).visibility==='hidden';
  const cleanup=()=>{window.__notebook?.dispose();frame.remove();};
  return {frame,window,document,start,hidden,cleanup};
}

try {
  const initializing=await fixture();
  let resumeStorage,storageStarted=false;
  const storageGate=new Promise(resolve=>{resumeStorage=resolve;}),opening=newDraft('Opening selected notebook');opening.autoRun=false;
  initializing.window.__testStore={list:async()=>{storageStarted=true;await storageGate;return [opening];},save:async()=>{}};
  initializing.start("const {startNotebook}=await import('./edit.mjs');window.__notebook=await startNotebook(window.__testStore);");
  await until(()=>storageStarted);
  for(const extra of [{key:'s',ctrlKey:true},{key:'f',ctrlKey:true,shiftKey:true}]) {
    initializing.document.body.dispatchEvent(new initializing.window.KeyboardEvent('keydown',{bubbles:true,cancelable:true,...extra}));
  }
  assert(!initializing.document.querySelector('dialog[open]'));assert(initializing.hidden());
  resumeStorage();await until(()=>initializing.document.documentElement.dataset.ready==='true');
  assert.equal(initializing.document.getElementById('title').value,opening.title);initializing.cleanup();
  report('global save and find shortcuts cannot interrupt initialization or open dialogs behind the loading gate');

  const delayed=await fixture();
  assert.equal(delayed.document.documentElement.dataset.startup,'loading');
  assert(delayed.hidden());assert(delayed.document.getElementById('notebook-app').inert);
  assert.equal(delayed.window.getComputedStyle(delayed.document.getElementById('startup')).display,'grid');
  report('the loading gate is visible and editor controls are inert before the application module starts');

  let release,fetchStarted=false;
  const gate=new Promise(resolve=>{release=resolve;}),originalFetch=delayed.window.fetch.bind(delayed.window);
  delayed.window.fetch=async (...args)=>{
    if(String(args[0]).endsWith('/roclet.wasm')){fetchStarted=true;await gate;}
    return originalFetch(...args);
  };
  const selected=newDraft('Chosen notebook');selected.cells=[makeCell('markdown','# Chosen notebook\nAlready rendered when the editor appears.'),makeCell('code','out_1 = 42')];
  delayed.window.__testStore={list:async()=>[selected],save:async()=>{}};
  // Evaluation deliberately requests a package picker: startup must have finished
  // before either evaluation or the user-provided package bundle can complete.
  const NativeWorker=delayed.window.Worker;
  delayed.window.Worker=class extends NativeWorker {
    postMessage(message,transfer) {
      if(message.request?.action==='evaluate') {
        delayed.window.queueMicrotask(()=>this.onmessage({data:{packageNeeded:{url:'https://example.invalid/package.tar.zst',error:'Host blocks browser downloads'}}}));
      } else super.postMessage(message,transfer);
    }
  };
  let incorrectReveal=false;
  const observer=new delayed.window.MutationObserver(()=>{
    if(!delayed.hidden() && delayed.document.getElementById('title').value!==selected.title)incorrectReveal=true;
  });
  observer.observe(delayed.document.documentElement,{attributes:true,subtree:true,childList:true});
  delayed.start("const {startNotebook}=await import('./edit.mjs');window.__notebook=await startNotebook(window.__testStore);");
  await until(()=>fetchStarted);
  assert(delayed.hidden());assert.equal(delayed.document.documentElement.dataset.startup,'loading');
  release();
  await until(()=>delayed.document.documentElement.dataset.ready==='true');
  assert(!delayed.hidden());assert(!delayed.document.getElementById('notebook-app').inert);
  assert.equal(delayed.document.getElementById('title').value,selected.title);
  assert.equal(delayed.document.title,`Roclet: ${selected.title}`);
  assert.equal(delayed.document.querySelector('.cell-preview h1')?.textContent,selected.title);
  assert.equal(incorrectReveal,false);observer.disconnect();
  report('delayed compiler downloads keep the editor hidden until the chosen notebook and its prose are rendered');
  await until(()=>delayed.document.getElementById('package-dialog').open);
  assert.equal(delayed.document.documentElement.dataset.startup,'ready');assert(!delayed.hidden());
  assert.equal(delayed.window.getComputedStyle(delayed.document.getElementById('startup')).display,'none');
  delayed.document.getElementById('package-dialog').querySelector('[data-close]').click();
  await until(()=>delayed.window.__notebook.status.startsWith('Package loading cancelled'));
  delayed.window.__notebook.setAuto(false);
  const title=delayed.document.getElementById('title');title.value='Renamed notebook';title.dispatchEvent(new delayed.window.Event('input'));
  assert.equal(delayed.document.title,'Roclet: Renamed notebook');
  delayed.document.getElementById('undo').click();assert.equal(delayed.document.title,`Roclet: ${selected.title}`);
  await delayed.window.__notebook.open('# %%\nout_1 = 7\n','Opened notebook.roc');
  assert.equal(delayed.document.title,'Roclet: Opened notebook');
  delayed.cleanup();
  report('startup reveals the notebook before evaluation completes or an external package bundle is supplied');
  report('the Roclet tab prefix follows notebook renaming, undo and opening another source');

  const brokenModule=await fixture({moduleError:true});brokenModule.start();
  await until(()=>brokenModule.document.documentElement.dataset.startup==='error');
  assert(brokenModule.hidden());assert.equal(brokenModule.document.getElementById('startup').getAttribute('role'),'alert');
  assert.match(brokenModule.document.getElementById('startup-message').textContent,/Startup module unavailable/);
  assert(!brokenModule.document.getElementById('startup-actions').hidden);
  assert(brokenModule.document.getElementById('startup-reload'));brokenModule.cleanup();
  report('application import failures replace the spinner with an error, Reload and a home link');

  const brokenCompiler=await fixture();
  const original=brokenCompiler.window.fetch.bind(brokenCompiler.window);
  brokenCompiler.window.fetch=(...args)=>String(args[0]).endsWith('/roclet.wasm')?Promise.resolve(new Response('',{status:404})):original(...args);
  brokenCompiler.start();await until(()=>brokenCompiler.document.documentElement.dataset.startup==='error');
  assert(brokenCompiler.hidden());assert.match(brokenCompiler.document.getElementById('startup-message').textContent,/Build the compiler adapter first/);
  assert(!brokenCompiler.document.getElementById('startup-actions').hidden);brokenCompiler.cleanup();
  report('a missing compiler artifact reports the failure without exposing an unusable editor');

  for(const failStylesheet of [false,true]) {
    const math=await fixture(),links=[],head=math.document.head,append=head.append.bind(head);
    head.append=(...nodes)=>{
      for(const node of nodes) {
        if(node.matches?.('link[data-roclet-math]'))links.push(node);
        else append(node);
      }
    };
    const MathWorker=math.window.Worker;
    math.window.Worker=class extends MathWorker {
      constructor(...args) {
        super(...args);
        this.addEventListener('message',event=>{if(event.data?.result?.model)math.window.__startupParsed=true;});
      }
    };
    const notes=newDraft('Circle notes');notes.autoRun=false;notes.cells=[makeCell('markdown','# Circle notes\n\n$A = \\pi r^2$')];
    math.window.__testStore={list:async()=>[notes],save:async()=>{}};
    math.start("const {startNotebook}=await import('./edit.mjs');window.__notebook=await startNotebook(window.__testStore);");
    await until(()=>links.length && math.window.__startupParsed);
    await new Promise(resolve=>requestAnimationFrame(resolve));
    assert(math.hidden());assert.equal(math.document.documentElement.dataset.startup,'loading');
    for(const link of links) {
      if(failStylesheet)link.dispatchEvent(new math.window.Event('error'));
      else append(link);
    }
    await until(()=>math.document.documentElement.dataset.ready==='true');
    assert(!math.hidden());assert(math.document.querySelector('.roclet-math .katex'));math.cleanup();
    report(failStylesheet?'a failed equation stylesheet releases startup instead of leaving a permanent spinner':'initial equations and their stylesheet settle before the notebook is revealed');
  }

  const home=new DOMParser().parseFromString(await fetch('../').then(response=>response.text()),'text/html');
  const editor=new DOMParser().parseFromString(html,'text/html');
  assert.equal(new URL(editor.querySelector('link[rel=icon]').getAttribute('href'),new URL('./edit.html',location.href)).href,new URL(home.querySelector('link[rel=icon]').getAttribute('href'),new URL('../',location.href)).href);
  report('home and notebook declare the same Roclet favicon explicitly');
  status.textContent='PASS — notebook startup gates, errors and identity';document.documentElement.dataset.result='pass';
} catch(error) {
  status.textContent='FAIL';log.textContent+=error.stack??error.message;document.documentElement.dataset.result='fail';
} finally {
  for(const frame of frames){frame.contentWindow?.__notebook?.dispose();frame.remove();}
}
