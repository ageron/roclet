import { openedDraft } from './edit-model.mjs';
import { importBundle } from './sharing.mjs';
import { bundleLimit } from './attachments.mjs';

// Import a copy using the editor's formats and integrity checks. Persist it before
// navigating so the editor opens the selected notebook, never an empty draft.
export async function openNotebookFile(file, store, loadManifest) {
  let record;
  if (/\.zip$/i.test(file.name)) {
    if (file.size > bundleLimit) throw new Error('Roclet bundles are limited to 40 MiB.');
    ({record} = await importBundle(await file.arrayBuffer(), await loadManifest()));
  } else {
    if (!/\.(roc|md)$/i.test(file.name)) throw new Error('Choose a .roc, .md, or .roclet.zip notebook.');
    if (file.size > 256 * 1024) throw new Error('Roclet notebooks are limited to 256 KiB.');
    record = openedDraft(await file.text(), file.name);
  }
  await store.save(record);
  return `web/edit.html?notebook=${encodeURIComponent(record.id)}`;
}
