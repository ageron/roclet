import { assert } from './harness.mjs';
export async function benchmark(session) {
  const makeSource=n=>Array.from({length:8},(_,i)=>`# %%\nv_${i} = ${i===0?n:i+2}\nout_${i+1} = v_${i} * 3`).join('\n');
  const request=source=>({operation:'document',action:'evaluate',format:'roc',source});
  // The engine keeps the baseline: the first request resets it, stateless
  // full runs leave it alone.
  await session.request({...request(makeSource(2)),reactivity:{reset:true}});
  const selectiveTimes=[],fullTimes=[],withoutReused=values=>values.map(({reused,...value})=>value);
  for(let i=0;i<5;i++) {
    const req=request(makeSource(i+10));
    const selective=await session.request({...req,reactivity:{}});
    const full=await session.request(req);
    assert.deepEqual(selective.plan.evaluate,['out_1']);assert.equal(selective.plan.reused.length,7);
    assert.deepEqual(selective.evaluation.values.map(v=>v.reused),[false,true,true,true,true,true,true,true]);
    assert.deepEqual(withoutReused(selective.evaluation.values),withoutReused(full.evaluation.values));
    selectiveTimes.push(selective.workerMs);fullTimes.push(full.workerMs);
  }
  const median=xs=>Math.round([...xs].sort((a,b)=>a-b)[Math.floor(xs.length/2)]);
  return {selectiveMedianMs:median(selectiveTimes),fullMedianMs:median(fullTimes),evaluated:1,reused:7,rounds:5};
}
