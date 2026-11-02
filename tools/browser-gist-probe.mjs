// Run with browser-check.mjs --page 'web/edit.html?example=gist-garden'
// --script tools/browser-gist-probe.mjs. This checks the live pinned Gist.
(async () => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const started = Date.now();
  while (document.documentElement.dataset.ready !== 'true') {
    if (Date.now() - started > 60000) throw new Error('Gist startup timed out: ' + document.body.innerText);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const {workbench} = await import('/web/edit.mjs');
  const notebook = workbench().left.notebook;
  assert(notebook.state.title === 'A garden plan from a Gist', 'The Gist example did not open: ' + document.getElementById('notice').textContent);
  assert(!notebook.state.autoRun && !notebook.result?.evaluation, 'A Gist must wait for Run');
  assert(notebook.state.preamble.includes('garden: "./garden.roc"'), 'The relative package declaration is missing');
  assert(notebook.state.files.length === 3, 'The package and its modules were not imported');
  assert(notebook.state.attachments[0]?.path === 'planting-notes.txt', 'The attachment was not imported');
  const first = await notebook.run();
  assert(first.status === 'ok', 'The Gist notebook failed to run');
  assert(first.evaluation.values.some(v => /area_square_metres: 24\.0, plants: 72\.0/.test(v.text)), 'The relative package returned the wrong result');
  assert(first.evaluation.values.some(v => v.text.includes('Garden notes')), 'The text import failed');
  assert(first.evaluation.diagnostics.length === 0, 'The demo produced compiler diagnostics');
  const helper = notebook.state.files.find(file => file.path === 'Spacing.roc');
  notebook.setProjectFile(helper.path, helper.source.replace('area * plants_per_square_metre', 'area * plants_per_square_metre * 2'));
  const changed = await notebook.run();
  assert(changed.status === 'ok' && changed.evaluation.values.some(v => /plants: 144\.0/.test(v.text)), 'Changing the internal package module did not update the notebook');
  notebook.undo();
  const restored = await notebook.run();
  assert(restored.status === 'ok' && restored.evaluation.values.some(v => /plants: 72\.0/.test(v.text)), 'Undo did not restore the package');
  return {result:'pass', verified:'live pinned Gist, relative package, internal module edits, undo, text attachment, manual execution'};
})()
