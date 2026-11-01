import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {plotlyFigure} from '../web/plotly-view.mjs';

test('chart boundary accepts figures and rejects malformed or oversized snapshots',()=>{
  assert.deepEqual(plotlyFigure('{"data":[],"layout":{}}'),{data:[],layout:{}});
  for(const content of [null,'null','[]','{}','{"data":[1],"layout":{}}','{"data":[],"layout":null}','{"data":[],"layout":{}}'+' '.repeat(131072),'é'.repeat(65537)]) assert.equal(plotlyFigure(content),null);
  const prefix='{"data":[],"layout":{}}';
  assert(plotlyFigure(prefix+' '.repeat(131072-prefix.length)));
  assert.deepEqual(plotlyFigure('{"data":[],"layout":{},"config":{"plotlyServerURL":"https://example.com"}}'),{data:[],layout:{}});
});

test('vendored Plotly and license match their pinned checksums',async()=>{
  const root=new URL('../web/vendor/plotly/',import.meta.url),lock=JSON.parse(await readFile(new URL('lock.json',root),'utf8'));
  assert.equal(lock.version,'4.2.0');
  for(const [name,{sha256}] of Object.entries(lock.files)) assert.equal(createHash('sha256').update(await readFile(new URL(name,root))).digest('hex'),sha256);
});
