import {assert} from '../tests/harness.mjs';
import {normalizeDisplay,renderDisplay} from './display-view.mjs';
import {DocumentSession} from './document-session.mjs';
import {exportReport} from './sharing.mjs';

let session,log='';
const pass=message=>{log+=`PASS ${message}\n`;document.querySelector('#log').textContent=log;};
const raw=content=>({version:1,kind:'plotly',text:'Chart summary',content});
// Inspect the opaque-origin frame from within it; production frames send no messages.
function observe(frame) {
  const result=new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{window.removeEventListener('message',receive);reject(new Error('Chart timed out'));},20000);
    function receive(event) {
      if(event.source!==frame.contentWindow || !event.data?.chartTest) return;
      clearTimeout(timer);window.removeEventListener('message',receive);resolve(event.data);
    }
    window.addEventListener('message',receive);
  });
  frame.srcdoc=frame.srcdoc.replace('</body>',`<script>
    addEventListener('message',async event=>{
      if(event.source!==parent || !event.data?.chartQuery)return;
      const chart=document.getElementById('chart');
      if(event.data.zoom)await Plotly.relayout(chart,{'xaxis.range':[0.25,0.75],'xaxis.autorange':false});
      if(event.data.fail)Plotly.react=()=>Promise.reject(Error('test draw failure'));
      parent.postMessage({chartQuery:event.data.chartQuery,y:chart.data?.[0]?.y,range:chart.layout?.xaxis?.range},'*');
    });
    const check=setInterval(()=>{
      const chart=document.getElementById('chart'),status=document.getElementById('status');
      if(chart.dataset.ready!=='true' && !chart.hidden)return;
      clearInterval(check);
      let parentBlocked=false,storageBlocked=false;
      try{parent.document.body;}catch{parentBlocked=true;}
      try{localStorage.getItem('chart-test');}catch{storageBlocked=true;}
      parent.postMessage({chartTest:true,ready:chart.dataset.ready==='true',status:status.textContent,
        svg:chart.querySelectorAll('svg').length,types:chart.data?.map(d=>d.type),
        x:chart.data?.[0]?.x,y:chart.data?.[0]?.y,title:chart.layout?.title?.text,
        parentBlocked,storageBlocked},'*');
    },25);
  </script></body>`);
  return result;
}

try {
  const content=JSON.stringify({data:[{type:'scatter',x:[0,1,2],y:[0,1,0],mode:'lines'}],layout:{title:{text:'Sine sample'}}});
  for(const invalid of ['bad','null','[]','{}','{"data":[],"layout":[]}','{"data":[null],"layout":{}}',content+' '.repeat(131072),'é'.repeat(65537)]) assert.equal(normalizeDisplay(raw(invalid)),null);
  assert(normalizeDisplay(raw('{"data":[],"layout":{}}')));
  const hostile='</script><script>parent.postMessage({injected:true},"*")</script>&雪';
  const mixed=raw(JSON.stringify({data:[
    {type:'bar',x:['A','B'],y:[2,3]},
    {type:'scatter',x:['A','B'],y:[1,4]},
    {type:'pie',labels:['A','B'],values:[2,3],domain:{x:[0.7,1],y:[0.7,1]}},
    {type:'sankey',node:{label:['A','B']},link:{source:[0],target:[1],value:[3]},domain:{x:[0.7,1],y:[0,0.3]}},
  ],layout:{title:{text:hostile}}}));
  const mixedView=renderDisplay(mixed,'Mixed chart'),mixedFrame=mixedView.querySelector('iframe');
  assert.equal(mixedFrame.getAttribute('sandbox'),'allow-scripts');
  assert.match(mixedFrame.srcdoc,/connect-src 'none'/);assert.doesNotMatch(mixedFrame.srcdoc,/<script>parent.postMessage/);
  const mixedReady=observe(mixedFrame);document.body.append(mixedView);
  const plotted=await mixedReady;
  assert(plotted.ready);assert(plotted.svg>0);assert.deepEqual(plotted.types,['bar','scatter','pie','sankey']);
  assert.equal(plotted.title,hostile);assert(plotted.parentBlocked);assert(plotted.storageBlocked);
  pass('bundled Plotly draws all Plume trace types; chart text is escaped and frames cannot access the notebook or storage');

  const saved=renderDisplay(raw(content),'Readable chart summary',{interactive:false});
  assert.equal(saved.querySelector('iframe'),null);assert.match(saved.textContent,/Readable chart summary/);assert(saved.querySelector('details').open);
  const badView=renderDisplay(raw('bad'),'Invalid chart summary');assert.equal(badView.querySelector('iframe'),null);assert.match(badView.textContent,/Invalid chart summary/);
  const unavailable=renderDisplay(raw(content),'Unavailable renderer'),failedFrame=unavailable.querySelector('iframe');
  failedFrame.srcdoc=failedFrame.srcdoc.replaceAll('/plotly.min.js','/missing.js');
  const failed=observe(failedFrame);document.body.append(unavailable);
  const failure=await failed;assert.equal(failure.ready,false);assert.match(failure.status,/Chart preview unavailable/);
  pass('invalid figures, missing renderers and saved snapshots retain readable fallbacks');

  session=new DocumentSession(await fetch('../artifacts/roclet.wasm').then(r=>r.arrayBuffer()));
  const source=`import Display\n# %%\nDisplay.plotly("Chart summary", ${JSON.stringify(content)})`;
  const result=await session.request({operation:'document',action:'evaluate',format:'roc',source});
  assert.equal(result.status,'ok');const value=result.evaluation.values[0];
  assert.equal(value.display.kind,'plotly');assert.equal(value.display.content,content);assert.equal(value.text,'Chart summary');
  const rendered=renderDisplay(value.display,value.text),ready=observe(rendered.querySelector('iframe'));document.body.append(rendered);
  assert.deepEqual((await ready).y,[0,1,0]);
  const retained=rendered.querySelector('iframe');
  const query=options=>new Promise(resolve=>{
    const chartQuery=crypto.randomUUID();
    const receive=event=>{if(event.source!==retained.contentWindow || event.data?.chartQuery!==chartQuery)return;window.removeEventListener('message',receive);resolve(event.data);};
    window.addEventListener('message',receive);retained.contentWindow.postMessage({chartQuery,...options},'*');
  });
  await query({zoom:true});retained.style.height='530px';
  const update=raw(JSON.stringify({data:[{type:'scatter',x:[0,1,2],y:[3,4,5]}],layout:{title:{text:'Updated'}}}));
  assert(rendered.update(update,'Updated summary'));await rendered.rendered;
  assert.equal(rendered.querySelector('iframe'),retained);assert.equal(retained.style.height,'530px');
  assert.equal(retained.title,'Updated summary');assert.match(rendered.querySelector('pre').textContent,/Updated summary/);
  assert.deepEqual((await query({})).y,[3,4,5]);assert.deepEqual((await query({})).range,[0.25,0.75]);
  assert(rendered.update(raw(content),'first'));assert(rendered.update(update,'latest'));await rendered.rendered;
  assert.deepEqual((await query({})).y,[3,4,5]);
  await query({fail:true});assert(rendered.update(raw(content),'Failed summary'));await rendered.rendered;
  assert.equal(rendered.update(update,'retry'),false);rendered.dispose();assert.equal(rendered.update(update,'disposed'),false);
  pass('compatible charts retain frame, zoom, height and fallback; overlapping updates converge and failures/disposal settle');
  const oversized=await session.request({operation:'document',action:'evaluate',format:'roc',source:'import Display\ngrow = |s, n| if n == 0 { s } else { grow(Str.concat(s,s),n - 1) }\n# %%\nDisplay.plotly("Too big",grow("AAAA",16))'});
  assert.equal(oversized.status,'ok');assert.equal(oversized.evaluation.values[0].display.kind,'text');assert.match(oversized.evaluation.values[0].text,/JSON is limited to 128 KiB/);
  pass('WASM evaluates Display.plotly, preserves its JSON and text, and bounds oversized figures');

  const report=await exportReport({document:{title:'Charts'},source:'chart',model:{cells:[{kind:'code',source:'chart'}]},snapshots:[{cell:0,text:value.text,display:value.display}],events:[],rendering:[],compiler:{},createdAt:new Date().toISOString()});
  const reportDoc=new DOMParser().parseFromString(await report.text(),'text/html');
  assert.equal(reportDoc.querySelectorAll('script,iframe').length,0);assert.match(reportDoc.body.textContent,/Chart summary/);
  pass('exported HTML reports keep the chart summary without executable scripts');
  document.documentElement.dataset.result='pass';document.querySelector('#status').textContent='Chart checks passed';
} catch(error) {
  document.documentElement.dataset.result='fail';document.querySelector('#status').textContent='Chart checks failed';log+=error.stack;
} finally {session?.stop();document.querySelector('#log').textContent=log;}
