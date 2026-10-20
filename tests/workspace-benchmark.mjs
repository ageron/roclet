import {assert} from './harness.mjs';
import {DocumentSession} from '../web/document-session.mjs';
import {newDraft,requestFor} from '../web/edit-model.mjs';
const encoder=new TextEncoder();
const rounded=n=>Math.round(n*1000)/1000;
const median=values=>rounded([...values].sort((a,b)=>a-b)[Math.floor(values.length/2)]);
const measure=async(session,request)=>{
  const start=performance.now(),result=await session.request(request),roundTripMs=performance.now()-start;
  if(result.status!=='ok')throw new Error(JSON.stringify({status:result.status,diagnostics:result.model?.diagnostics,evaluation:result.evaluation}));
  assert(result.workspaceCache,'Benchmark requires the persistent compiler workspace');
  return {result,sample:{roundTripMs,workerMs:result.workerMs,outsideWorkerMs:roundTripMs-result.workerMs,
    originalRequestBytes:encoder.encode(JSON.stringify(request)).length,...result.transportMetrics,
    cacheHits:result.workspaceCache.hits,cacheMisses:result.workspaceCache.misses,
    frontendBuilds:result.workspaceCache.frontend_builds,lowerings:result.workspaceCache.lowerings,
    rootExecutions:result.workspaceCache.executions,preparedHits:result.workspaceCache.prepared_hits,
    imageBytes:result.workspaceCache.image_bytes,imageRetries:result.workspaceCache.image_retries,analyses:result.workspaceCache.analyses}};
};
const summarize=samples=>({rounds:samples.length,...Object.fromEntries(Object.keys(samples[0]).map(key=>[`${key}Median`,median(samples.map(s=>s[key]))]))});
const reactive=(request,previous)=>({...request,compact:true,...(previous?{reactivity:{known:true,previous:previous.graph,current:{context:'',scope:'module',definitions:[]},roots:[],available:previous.roots,force:[]}}:{})});

// Every measured edit is checked against its expected values. Timings include
// the real worker/UTF-8/WASM/cache-write path and never compare cached results.
// maxWallMemoryBytes bounds the warm Wall Area worker's linear memory, so a
// reintroduced fixed per-revision reservation fails loudly.
export async function benchmarkWorkspace(bytes,{rounds=15,buildMode,maxWallMemoryBytes=256*1024*1024,report=()=>{}}={}) {
  if(!Number.isInteger(rounds)||rounds<1||rounds>100) throw new Error('Choose between 1 and 100 benchmark rounds');
  const sessions=[],session=()=>{const value=new DocumentSession(bytes);sessions.push(value);return value;};
  try {
    const wall=session(),state=newDraft('Wall area',true),wallSamples=[];
    let previous=null,wallStartup;
    for(let index=-3;index<rounds;index++) {
      const width=index+8;state.cells[2].source=`width = ${width}\nheight = 3`;
      const measured=await measure(wall,reactive(requestFor(state,'evaluate'),previous));
      assert.deepEqual(measured.result.evaluation.values.map(value=>value.text),[`${width*3}.0`,`${width*3}.0`]);
      assert.equal(measured.sample.fileBytes,0);previous=measured.result;
      assert.equal(measured.sample.frontendBuilds,1);assert.equal(measured.sample.lowerings,1);assert.equal(measured.sample.rootExecutions,2);assert.equal(measured.sample.analyses,1);
      if(index===-3)wallStartup=measured.sample;
      if(index>=0)wallSamples.push(measured.sample);
    }
    const wallWarm=summarize(wallSamples);
    if(Number.isFinite(wallWarm.memoryBytesMedian))assert(wallWarm.memoryBytesMedian<=maxWallMemoryBytes,`Wall Area worker memory ${wallWarm.memoryBytesMedian} exceeds ${maxWallMemoryBytes} bytes`);
    report('Wall Area edits checked');
    const modules=session(),moduleSamples=[];
    const geometry=offset=>`Geometry := [].{\narea : U64, U64 -> U64\narea = |width, height| width * height + ${offset}\n}`;
    const materials='Materials := [].{\nprice : U64\nprice = 4\n}';
    const source='# %% id=area\nimport Geometry\nimport Materials\nout_area = Geometry.area(5, 3)\n# %% id=cost\nout_cost = out_area * Materials.price';
    previous=null;let currentRequest,moduleStartup;
    for(let index=-3;index<rounds;index++) {
      const offset=index+3,changedSource=geometry(offset);
      currentRequest={operation:'document',action:'evaluate',format:'roc',source,compact:true,files:[{path:'/workspace/Geometry.roc',source:changedSource},{path:'/workspace/Materials.roc',source:materials}]};
      const measured=await measure(modules,reactive(currentRequest,previous));
      assert.deepEqual(measured.result.evaluation.values.map(value=>value.text),[`${15+offset}`,`${(15+offset)*4}`]);
      assert.equal(measured.sample.frontendBuilds,1);assert.equal(measured.sample.lowerings,1);assert.equal(measured.sample.rootExecutions,2);assert.equal(measured.sample.analyses,1);
      if(index!==-3)assert.equal(measured.sample.fileBytes,encoder.encode(changedSource).length);
      previous=measured.result;if(index===-3)moduleStartup=measured.sample;
      if(index>=0)moduleSamples.push(measured.sample);
    }
    report('Imported module implementation edits checked; unchanged module bytes never resent');
    modules.stop();
    const restored=session(),restoredMeasurement=await measure(restored,currentRequest);
    assert.deepEqual(restoredMeasurement.result.evaluation.values,previous.evaluation.values);
    assert(restoredMeasurement.result.workspaceCache.hits>0,'Restarted worker must consume persisted build artifacts');
    return {buildMode,rounds,warmupRounds:3,wallArea:{startup:wallStartup,warm:wallWarm},
      multiModule:{startup:moduleStartup,warm:summarize(moduleSamples),restoredWorker:restoredMeasurement.sample}};
  } finally {for(const value of sessions)value.stop();}
}
