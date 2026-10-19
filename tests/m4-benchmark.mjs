import { assert } from './harness.mjs';
export async function benchmark(session) {
  const makeSource=n=>Array.from({length:8},(_,i)=>`# %%\nv_${i} = ${i===0?n:i+2}\nout_${i+1} = v_${i} * 3`).join('\n');
  const request=source=>({operation:'document',action:'evaluate',format:'roc',source});
  let previous=await session.request(request(makeSource(2))),selectiveTimes=[],fullTimes=[];
  for(let i=0;i<5;i++) {
    const req=request(makeSource(i+10));
    const selective=await session.request({...req,reactivity:{known:true,previous:previous.graph,current:previous.graph,available:previous.roots,roots:[],force:[]}});
    const full=await session.request(req);
    assert.deepEqual(selective.plan.evaluate,['out_1']);assert.equal(selective.plan.reused.length,7);
    const values=[...selective.evaluation.values,...previous.evaluation.values.filter(v=>v.root!=='out_1')];
    assert.deepEqual(values,full.evaluation.values);
    selectiveTimes.push(selective.workerMs);fullTimes.push(full.workerMs);previous=full;
  }
  const median=xs=>Math.round([...xs].sort((a,b)=>a-b)[Math.floor(xs.length/2)]);
  return {selectiveMedianMs:median(selectiveTimes),fullMedianMs:median(fullTimes),evaluated:1,reused:7,rounds:5};
}
