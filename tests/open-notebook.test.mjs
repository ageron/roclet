import {test} from 'node:test';
import assert from 'node:assert/strict';
import {openNotebookFile} from '../web/open-notebook.mjs';
import {validDraft} from '../web/edit-model.mjs';

for (const name of ['notes.roc', 'notes.md']) {
  test(`home opens ${name} only after saving an independent draft`, async () => {
    let saved;
    const file = new File(['hello\n'], name);
    const store = {async save(record) { saved = record; }};
    const manifest = () => { throw new Error('Source import needs no compiler manifest'); };
    const url = await openNotebookFile(file, store, manifest);
    assert.equal(validDraft(saved), true);
    assert.equal(saved.source, 'hello\n');
    assert.equal(new URL(url, 'https://example.test/').searchParams.get('notebook'), saved.id);
    const firstId = saved.id;
    await openNotebookFile(file, store, manifest);
    assert.notEqual(saved.id, firstId);
  });
}
test('home rejects unsupported or oversized files before saving', async () => {
  const store = {save() { assert.fail('Invalid import must not be saved'); }};
  for (const [file, error] of [
    [new File(['oops'], 'notes.html'), /Choose a/],
    [new File(['x'.repeat(256 * 1024 + 1)], 'notes.roc'), /256 KiB/],
    [{name:'notes.zip', size:40 * 1024 * 1024 + 1}, /40 MiB/],
  ]) await assert.rejects(openNotebookFile(file, store), error);
});
test('home surfaces storage failures instead of opening an empty draft', async () => {
  await assert.rejects(openNotebookFile(new File(['hello'], 'notes.md'), {
    async save() { throw new Error('Storage full'); },
  }), /Storage full/);
});
test('home verifies bundle contents before saving', async () => {
  let loaded = false;
  await assert.rejects(openNotebookFile(new File(['not a zip'], 'notes.roclet.zip'), {
    save() { assert.fail('Corrupt bundle must not be saved'); },
  }, async () => { loaded = true; return {}; }));
  assert.equal(loaded, true);
});
