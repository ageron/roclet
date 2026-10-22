import test from 'node:test';
import assert from 'node:assert/strict';
import {runSuites} from '../tools/test-browser.mjs';

test('browser suites overlap without exceeding the worker limit, and all failures are reported',async()=>{
  const pending=[],started=[],reported=[];
  const run=item=>new Promise(resolve=>{started.push(item[0]);pending.push(resolve);});
  const work=runSuites([['A'],['B'],['C'],['D']],{jobs:2,run,report:r=>reported.push(r.label)});
  assert.deepEqual(started,['A','B']);
  pending.shift()({code:1,log:'failed A'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(started,['A','B','C']);
  assert.deepEqual(reported,['A']);
  pending.shift()({code:0,log:'passed B'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(started,['A','B','C','D']);
  pending.shift()({code:0,log:'passed C'});
  pending.shift()({code:0,log:'passed D'});
  const results=await work;
  assert.deepEqual(results.map(r=>r.label),['A','B','C','D']);
  assert.deepEqual(results.map(r=>r.code),[1,0,0,0]);
  assert.equal(reported.length,4);
});

test('serial mode continues after a driver error and rejects invalid worker counts',async()=>{
  let active=0;
  const results=await runSuites([['A'],['B']],{jobs:1,run:async([label])=>{
    assert.equal(active++,0);
    await Promise.resolve();
    active--;
    if(label==='A')throw new Error('Chrome failed to start');
    return {code:0,log:'passed'};
  }});
  assert.match(results[0].log,/Chrome failed to start/);
  assert.equal(results[0].code,1);
  assert.equal(results[1].code,0);
  for(const jobs of [0,-1,1.5,NaN])await assert.rejects(runSuites([],{jobs}),/positive integer/);
});
