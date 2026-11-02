// Run with browser-check.mjs --page index.html --script tools/browser-recents-probe.mjs.
(async () => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const until = async predicate => {
    for (let i=0;i<100;i++) { if (predicate()) return; await new Promise(resolve=>setTimeout(resolve,20)); }
    throw new Error('Timed out waiting for recent notebooks');
  };
  const {DraftStore} = await import('/web/edit-store.mjs');
  const {newDraft} = await import('/web/edit-model.mjs');
  const store = new DraftStore(), record = newDraft('Notebook to keep'), other = newDraft('Another notebook');
  await store.save(record); await store.save(other);
  const editor = await store.fork(), editing = await editor.get(record.id);
  const refresh = () => dispatchEvent(new Event('pageshow'));
  const link = id => document.querySelector(`#recents a[href$="${id}"]`);
  refresh(); await until(()=>link(record.id));
  const url = location.href;
  link(record.id).parentElement.querySelector('.remove-recent').click();
  await until(()=>!link(record.id));
  assert(location.href===url,'Removal must not open the notebook');
  assert(link(other.id),'Other notebooks must remain visible');
  assert((await store.get(record.id)).title===record.title,'Draft must not be deleted');
  // Hiding history metadata must not cause a false concurrency conflict, and
  // an old in-memory draft must not restore the hidden entry on autosave.
  editing.title='Edited in another tab'; await editor.save(editing);
  refresh(); await until(()=>link(other.id));
  const reopened = await store.fork();
  assert(!(await reopened.list()).some(r=>r.id===record.id),'Removal must persist in a new store');
  assert((await reopened.get(record.id)).title===editing.title,'Hidden notebooks must remain accessible by ID');
  link(other.id).parentElement.querySelector('.remove-recent').click();
  await until(()=>document.querySelector('#recents').children.length===0);
  assert(!document.querySelector('#recent-status').hidden,'Empty-state message must be visible');
  assert(document.activeElement===document.querySelector('#open-notebook'),'Removing the last entry must retain keyboard focus');
  await store.removeFromRecents('missing');
  store.close();editor.close();reopened.close();
  return {result:'pass',verified:'home removal, empty state, focus, draft preservation, persistence, and concurrent autosave'};
})()
