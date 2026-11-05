import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';

test('the actual Worker entrypoint boots in workerd and serves CORS without upstream networking',{timeout:45000},async t=>{
  const child=spawn(process.execPath,['node_modules/wrangler/bin/wrangler.js','dev','--ip','127.0.0.1','--port','0','--inspector-port','0','--local'],{
    cwd:new URL('../',import.meta.url),env:{...process.env,WRANGLER_SEND_METRICS:'false'},stdio:['ignore','pipe','pipe'],
  });
  t.after(async()=>{
    if(child.exitCode===null){child.kill();await new Promise(resolve=>child.once('close',resolve));}
  });
  let log='';
  const base=await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(Error('Worker startup timed out: '+log)),30000);
    const output=chunk=>{
      log+=chunk.toString();const match=log.match(/Ready on (http:\/\/127\.0\.0\.1:\d+)/);
      if(match){clearTimeout(timer);resolve(match[1]);}
    };
    child.stdout.on('data',output);child.stderr.on('data',output);
    child.once('error',error=>{clearTimeout(timer);reject(error);});
    child.once('exit',code=>{clearTimeout(timer);reject(Error(`Worker exited ${code}: ${log}`));});
  });
  const health=await fetch(base+'/health');assert.equal(health.status,200);assert.match(await health.text(),/ready/);
  const invalid=await fetch(base+'/api/packages/not-a-package');assert.equal(invalid.status,400);assert.equal(invalid.headers.get('Access-Control-Allow-Origin'),'*');
  const path='/api/packages/ageron/roc-ascii/v0.5.1/3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst';
  const preflight=await fetch(base+path,{method:'OPTIONS',headers:{Origin:'https://ageron.github.io','Access-Control-Request-Method':'GET'}});
  assert.equal(preflight.status,204);assert.equal(preflight.headers.get('Access-Control-Allow-Origin'),'*');
});
