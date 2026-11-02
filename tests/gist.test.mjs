import {test} from 'node:test';
import assert from 'node:assert/strict';
import {gistReference, loadGist} from '../web/gist.mjs';
import {validDraft, requestFor} from '../web/edit-model.mjs';

const id = 'abc123def456';
const revision = 'a'.repeat(40);
const response = files => new Response(JSON.stringify({files:Object.fromEntries(Object.entries(files).map(([name, content]) => [name, {content}]))}));
const load = (files, options = {}) => loadGist(id, {fetch:async()=>response(files), ...options});

test('Gist references accept IDs, page URLs and pinned revisions', () => {
  assert.deepEqual(gistReference(id), {id});
  assert.deepEqual(gistReference(`https://gist.github.com/user/${id}#file-notebook-roc`), {id});
  assert.deepEqual(gistReference(`https://gist.github.com/user/${id}/${revision}`), {id, revision});
  for (const value of ['http://gist.github.com/user/'+id, 'https://evil.test/'+id, 'https://gist.github.com/user/'+id+'/extra', '../abc', '', 'https://gist.github.com/user/'+id+'/a/b']) assert.throws(()=>gistReference(value), /Gist URL/);
});

test('Gist imports carry modules and text attachments into independent paused drafts', async () => {
  const files = {'notebook.roc':'app [main!] {}\nimport Geometry\nGeometry.area(3)', 'Geometry.roc':'module [area]\narea = |r| r * r', 'sales.csv':'name,total\ncafé,42\n'};
  const record = await load(files);
  assert.equal(validDraft(record), true);
  assert.equal(record.autoRun, false);
  assert.equal(record.source, files['notebook.roc']);
  assert.deepEqual(record.files, [{path:'Geometry.roc', source:files['Geometry.roc']}]);
  assert.equal(await record.attachments[0].blob.text(), files['sales.csv']);
  assert.match(record.attachments[0].sha256, /^[a-f0-9]{64}$/);
  assert.equal(requestFor(record, 'evaluate').files[0].path, '/workspace/Geometry.roc');
  assert.notEqual((await load(files)).id, record.id);
});

test('Gist entry selection handles Markdown, Main and ambiguous notebooks', async () => {
  assert.equal((await load({'notes.md':'# Notes'})).format, 'markdown');
  assert.equal((await load({'Main.roc':'hello', 'Utils.roc':'world'})).source, 'hello');
  await assert.rejects(load({'a.roc':'a', 'b.roc':'b'}), /gistFile/);
  assert.equal((await load({'a.roc':'a', 'b.roc':'b'}, {filename:'b.roc'})).source, 'b');
  await assert.rejects(load({'notes.md':'hello'}, {filename:'missing.md'}), /gistFile/);
});

test('Gist requests pin revisions and omit credentials', async () => {
  await loadGist(`https://gist.github.com/user/${id}/${revision}`, {fetch:async (url, options) => {
    assert.equal(url, `https://api.github.com/gists/${id}/${revision}`);
    assert.equal(options.credentials, 'omit');
    return response({'notebook.roc':'hello'});
  }});
});

test('Gist failures reject incomplete imports and invalid project paths', async () => {
  for (const status of [403, 404, 429, 500]) await assert.rejects(loadGist(id, {fetch:async()=>new Response('', {status})}), /GitHub|not found/);
  for (const body of [{truncated:true,files:{}}, {files:{'notebook.roc':{content:'partial',truncated:true}}}, {files:{'notebook.roc':{}}}]) await assert.rejects(loadGist(id, {fetch:async()=>new Response(JSON.stringify(body))}), /incomplete|full contents/);
  await assert.rejects(load({'notebook.roc':'hello','../Utils.roc':'bad'}), /relative project path/);
  await assert.rejects(load({'notebook.roc':'hello','../data.txt':'bad'}), /relative project path/);
  await assert.rejects(load({'notebook.roc':'hello','Main.roc':'bad'}), /reserved/);
  await assert.rejects(load({'notebook.roc':'é'.repeat(128 * 1024 + 1)}), /256 KiB/);
});
