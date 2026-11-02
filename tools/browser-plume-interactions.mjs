// Release integration measurement. Use --page web/edit.html?example=plume-charts
// --scenario tools/browser-plume-interactions.mjs and --upload-plan if needed.
export default async function({evaluate}) {
  const until=async expression=>{const end=Date.now()+120000;while(!await evaluate(expression)){if(Date.now()>end)throw Error(`Timed out: ${expression}`);await new Promise(resolve=>setTimeout(resolve,20));}};
  await until("document.documentElement.dataset.ready==='true'");
  await evaluate("(async()=>{const {workbench}=await import('/web/edit.mjs');globalThis.measuredNotebook=workbench().active.notebook;})()");
  await until("document.querySelector('.display-plotly') || document.querySelector('#package-dialog').open");
  if(await evaluate("document.querySelector('#package-dialog').open"))await evaluate("globalThis.__rocletFilePicker('#package-load')");
  await until("!measuredNotebook.busy && measuredNotebook.result?.status==='ok' && !!document.querySelector('.display-plotly')");
  await evaluate("globalThis.retainedChart=document.querySelector('.display-plotly');globalThis.stops=0;const stop=measuredNotebook.session.stop.bind(measuredNotebook.session);measuredNotebook.session.stop=(...args)=>{stops++;return stop(...args);};measuredNotebook.setAuto(true);clearTimeout(measuredNotebook.timer);measuredNotebook.timer=null;");
  const samples=[];
  for(const [index,value] of [2,3,1,2,3,1,2,3,1].entries()) {
    await evaluate(`measuredNotebook.setInputValue('frequency',${value})`);
    await until(`!measuredNotebook.busy && measuredNotebook.result?.interaction?.revision===measuredNotebook.state.revision`);
    const sample=await evaluate("(()=>{const n=measuredNotebook,t=n.result.interaction;return {inputToDrawnMs:t.drawnAt-t.receivedAt,paintOpportunityMs:t.paintOpportunityAt-t.drawnAt,workerMs:n.result.workerMs,y10:JSON.parse(n.result.evaluation.values.find(v=>v.root==='out_wave').display.content).data[0].y[10]};})()");
    if(Math.abs(sample.y10-Math.sin(value))>1e-12)throw Error('Wrong final wave');
    if(index>=6)samples.push(sample);
  }
  const environment=await evaluate("(async()=>({browser:navigator.userAgent,wasmOptimize:(await fetch('/artifacts/manifest.json').then(r=>r.json())).wasmOptimize,sameFrame:document.querySelector('.display-plotly')===retainedChart,workerStops:stops}))()");
  if(!environment.sameFrame || environment.workerStops)throw Error(JSON.stringify(environment));
  return {result:'pass',...environment,samples};
}
