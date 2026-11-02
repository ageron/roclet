// Trusted control input against the real notebook and local Display/Input assets.
export default async function({evaluate,send}) {
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const until=async expression=>{const end=Date.now()+30000;while(!await evaluate(expression)){if(Date.now()>end)throw Error(`Timed out: ${expression}`);await pause(20);}};
  await until("document.documentElement.dataset.ready==='true'");
  const source='import Display\nimport Input\n# %%\ncontrol = Input.slider({key: "frequency", label: "Frequency", min: 1, max: 10, step: 1, default: 1})\nfrequency = control.value\nout_control = control.display\n# %%\nout_wave = Display.plotly(frequency.to_str(), "{\\"data\\":[{\\"x\\":[0,1],\\"y\\":[0,${frequency.to_str()}]}],\\"layout\\":{}}")\n# %%\nout_independent = 42';
  await evaluate(`(async()=>{const {workbench}=await import('/web/edit.mjs');globalThis.testNotebook=workbench().active.notebook;testNotebook.setAuto(false);await testNotebook.open(${JSON.stringify(source)},'Wave.roc');await testNotebook.run();testNotebook.setAuto(true);clearTimeout(testNotebook.timer);testNotebook.timer=null;globalThis.originalChart=document.querySelector('.display-plotly');globalThis.workerStops=0;globalThis.evaluations=0;const stop=testNotebook.session.stop.bind(testNotebook.session),dispatch=testNotebook.session.dispatch.bind(testNotebook.session);testNotebook.session.stop=(...args)=>{workerStops++;return stop(...args);};testNotebook.session.dispatch=(...args)=>{evaluations++;return dispatch(...args);};})()`);
  const position=await evaluate("(()=>{const s=document.querySelector('input[aria-label=Frequency]');s.scrollIntoView({block:'center'});const r=s.getBoundingClientRect();return {x:r.x,y:r.y+r.height/2,width:r.width};})()");
  await send('Input.dispatchMouseEvent',{type:'mousePressed',x:position.x+10,y:position.y,button:'left',clickCount:1});
  for(let i=1;i<=8;i++) {await send('Input.dispatchMouseEvent',{type:'mouseMoved',x:position.x+position.width*i/10,y:position.y,button:'left',buttons:1});await pause(20);}
  await send('Input.dispatchMouseEvent',{type:'mouseReleased',x:position.x+position.width*0.8,y:position.y,button:'left',clickCount:1});
  await until("!testNotebook.busy && testNotebook.result?.status==='ok'");
  await evaluate("document.querySelector('input[aria-label=Frequency]').focus()");
  for(let i=0;i<2;i++) {await send('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowLeft',code:'ArrowLeft',windowsVirtualKeyCode:37});await send('Input.dispatchKeyEvent',{type:'keyUp',key:'ArrowLeft',code:'ArrowLeft',windowsVirtualKeyCode:37});}
  await until("!testNotebook.busy && testNotebook.result?.status==='ok'");
  const result=await evaluate("({sameFrame:document.querySelector('.display-plotly')===originalChart,workerStops,evaluations,value:testNotebook.state.inputValues.frequency,output:testNotebook.result.evaluation.values.find(v=>v.root==='out_wave').text,reused:testNotebook.result.evaluation.values.find(v=>v.root==='out_independent').reused,interaction:testNotebook.result.interaction})");
  if(!result.sameFrame || result.workerStops || !result.reused || Number(result.output)!==result.value)throw Error(JSON.stringify(result));
  await evaluate("testNotebook.setInputValue('frequency',3);testNotebook.stop()");
  await pause(150);
  if(!await evaluate("!testNotebook.busy && !testNotebook.result && !testNotebook.session.queued && !testNotebook.state.autoRun"))throw Error('Stop retained pending work');
  return {result:'pass',...result};
}
