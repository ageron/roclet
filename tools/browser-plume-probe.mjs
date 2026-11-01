// Release integration check, separate from the network-free core browser suites.
// Run browser-check with --page web/edit.html?example=plume-charts and this script.
// Supply the pinned release archive through --upload-plan if GitHub CORS fails.
(async()=>{
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),assert=(value,message)=>{if(!value)throw Error(message);};
  const $=id=>document.getElementById(id);
  const until=async predicate=>{for(let i=0;i<1200;i++){if(predicate())return;await pause(100);}throw Error('Timed out: '+$('status').textContent);};
  await until(()=>document.documentElement.dataset.ready==='true');
  const {editorFor}=await import('/web/cell-editor.mjs');
  const editors=()=>[...document.querySelectorAll('#notebook .cm-content')].map(editorFor);
  const chart=()=>editors().find(editor=>editor.source.includes('out_wave ='))?.dom.closest('.cell').querySelector('.value[data-stale="false"] .display-plotly');
  const figure=()=>JSON.parse(new DOMParser().parseFromString(chart().srcdoc,'text/html').querySelector('#figure').textContent);
  await until(()=>chart() || $('package-dialog').open || /failed|attention|Stopped after/i.test($('status').textContent));
  if($('package-dialog').open) {
    assert(typeof globalThis.__rocletFilePicker==='function','Use --upload-plan with the pinned Plume release archive');
    globalThis.__rocletFilePicker('#package-load');
  }
  await until(()=>chart() || /failed|attention|Stopped after/i.test($('status').textContent));
  assert(chart(),$('status').textContent+' '+$('document-diagnostics').textContent);
  const initial=figure();assert(initial.data[0].type==='scatter' && initial.data[0].x.length===81,'Missing Plume curve');
  assert(Math.abs(initial.data[0].y[10]-Math.sin(1))<1e-12,'Wrong sine coordinate');
  const slider=document.querySelector('#notebook input[aria-label="Amplitude"]');
  assert(slider && !slider.disabled,'Missing amplitude slider');
  slider.value='2';slider.dispatchEvent(new Event('input',{bubbles:true}));
  await until(()=>chart() && Math.abs(figure().data[0].y[10]-2*Math.sin(1))<1e-12 && $('status').textContent.startsWith('Current'));
  assert($('status').textContent.startsWith('Current'),'Slider result is not current');
  const doubled=figure();
  $('auto').checked=false;$('auto').dispatchEvent(new Event('change'));
  const equation=editors().find(editor=>editor.source.includes('F64.sin(number)')),original=equation.source;
  equation.view.dispatch({changes:{from:0,to:equation.view.state.doc.length,insert:original.replace('F64.sin(number)','F64.cos(number)')},userEvent:'input'});
  const run=async()=>{$('run').click();await until(()=>/Current|failed|attention|Stopped after/i.test($('status').textContent));assert($('status').textContent.startsWith('Current'),$('status').textContent+' '+$('document-diagnostics').textContent);};
  await run();assert(Math.abs(figure().data[0].y[0]-2)<1e-12,'Equation edit did not redraw a cosine');
  $('stop').click();await run();assert(Math.abs(figure().data[0].y[0]-2)<1e-12,'Worker restart lost chart or slider state');
  const source=await fetch('/demos/05-plume-charts.roc').then(r=>r.text()),bytes=await fetch('/artifacts/roclet.wasm').then(r=>r.arrayBuffer());
  const module=path=>JSON.stringify(new URL(path,location.href).href);
  const code=`import{createWasmTransport}from ${module('/compiler-adapter/wasm.mjs')};import{BuildCache,compilerNamespace}from ${module('/web/build-cache.mjs')};import{BrowserPackages}from ${module('/web/packages.mjs')};onmessage=async({data})=>{try{const raw=await createWasmTransport(data.bytes),ns=await compilerNamespace(data.bytes,raw.cacheIdentity());raw.importCache(await new BuildCache(ns).load());const packages=new BrowserPackages(new BuildCache(ns+':packages'),{fetch:async()=>{throw Error('Package networking disabled');}});postMessage({result:await packages.evaluate(raw,data.request)});}catch(error){postMessage({error:error.stack});}};`;
  const blob=URL.createObjectURL(new Blob([code],{type:'text/javascript'})),worker=new Worker(blob,{type:'module'});let offline;
  try {offline=await new Promise((resolve,reject)=>{worker.onmessage=({data})=>data.error?reject(Error(data.error)):resolve(data.result);worker.onerror=reject;worker.postMessage({bytes,request:{operation:'document',action:'evaluate',format:'roc',source}});});}
  finally {worker.terminate();URL.revokeObjectURL(blob);}
  assert(offline.status==='ok','Offline Plume compile failed: '+JSON.stringify(offline));
  const offlineFigure=JSON.parse(offline.evaluation.values.find(v=>v.root==='out_wave').display.content);
  assert(JSON.stringify(offlineFigure)===JSON.stringify(initial),'Offline Plume figure differs');
  const frame=chart();
  const drawn=new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{window.removeEventListener('message',receive);reject(Error('Plume chart did not draw'));},20000);
    function receive(event) {
      if(event.source!==frame.contentWindow || !event.data?.plumeDrawn)return;
      clearTimeout(timer);window.removeEventListener('message',receive);resolve(event.data);
    }
    window.addEventListener('message',receive);
  });
  frame.srcdoc=frame.srcdoc.replace('</body>',`<script>const timer=setInterval(()=>{const chart=document.getElementById('chart');if(chart.dataset.ready!=='true')return;clearInterval(timer);parent.postMessage({plumeDrawn:true,svg:chart.querySelectorAll('svg').length,version:Plotly.version},'*');},25);</script></body>`);
  const rendered=await drawn;assert(rendered.svg>0 && rendered.version==='4.2.0','Plume figure did not render with the pinned Plotly');
  frame.scrollIntoView({block:'center'});await pause(100);
  return {result:'pass',samples:initial.data[0].x.length,slider:{before:initial.data[0].y[10],after:doubled.data[0].y[10]},renderer:rendered.version,equationEdit:'pass',workerRestart:'pass',offline:'pass',horizontalOverflow:document.documentElement.scrollWidth>innerWidth};
})()
