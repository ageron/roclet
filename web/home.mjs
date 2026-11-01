import {serverProjectReady} from './server-project.mjs';
import {DraftStore} from './edit-store.mjs';
const store = new DraftStore();
const status = document.getElementById('recent-status');
const list = document.getElementById('recents');
const more = document.getElementById('show-all');
let expanded = false, generation = 0;
async function refresh() {
  const current = ++generation;
  try {
    const records = (await store.list()).filter(r => r.schema === 1 && typeof r.id === 'string' && typeof r.title === 'string' && Array.isArray(r.cells));
    if (current !== generation) return;
    list.replaceChildren();
    status.hidden = records.length > 0;
    status.textContent = 'No notebooks saved in this browser yet. Create a notebook or open a demo to get started.';
    more.hidden = records.length <= 6;
    more.textContent = expanded ? 'Show fewer' : `Show all ${records.length} notebooks`;
    for (const record of expanded ? records : records.slice(0,6)) {
      const item = document.createElement('li'), link = document.createElement('a'), label = document.createElement('span'), title = document.createElement('strong'), date = document.createElement('time'), arrow = document.createElement('span');
      link.href = `web/edit.html?notebook=${encodeURIComponent(record.id)}`;
      title.textContent = record.title || 'Untitled';
      const updated = new Date(record.updatedAt);
      if (Number.isFinite(updated.getTime())) {date.dateTime = updated.toISOString();date.textContent = `Edited ${updated.toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'})}`;}
      arrow.className = 'arrow';arrow.textContent = '→';arrow.setAttribute('aria-hidden','true');
      label.append(title,date);link.append(label,arrow);item.append(link);list.append(item);
    }
  } catch {
    if (current !== generation) return;
    list.replaceChildren();more.hidden = true;status.hidden = false;
    status.textContent = 'Recent notebooks are unavailable because this browser could not open its storage. You can still try a demo.';
  }
}
more.onclick = () => { expanded = !expanded; void refresh(); };
addEventListener('pageshow', () => void refresh());
addEventListener('focus', () => void refresh());
void refresh();

const openButton = document.getElementById('open-notebook');
const fileInput = document.getElementById('open-notebook-file');
const openStatus = document.getElementById('open-status');
openButton.onclick = () => fileInput.click();
fileInput.onchange = async () => {
  const file = fileInput.files[0];
  if (!file) return;
  openButton.disabled = true; openStatus.hidden = false; openStatus.textContent = 'Opening notebook…';
  try {
    const {openNotebookFile} = await import('./open-notebook.mjs');
    const url = await openNotebookFile(file, store, async () => {
      const response = await fetch('artifacts/manifest.json');
      if (!response.ok) throw new Error('Could not load Roclet’s compiler information. Please try again.');
      return response.json();
    });
    location.assign(url);
  } catch (error) {
    openStatus.textContent = error.message || 'Could not open this notebook.';
  } finally {
    openButton.disabled = false; fileInput.value = '';
  }
};

// Local projects retain the same homepage and demos, with disk notebooks first.
const project=await serverProjectReady;
if(project) {
  if(project.config.initial && !new URL(location.href).searchParams.has('home')) {
    location.replace(`web/edit.html?file=${encodeURIComponent(project.config.initial)}`);
  } else {
    const section=document.createElement('section');
    const heading=document.createElement('h2');heading.textContent='Project notebooks';
    const root=document.createElement('p');root.textContent=project.config.root;
    const entries=document.createElement('ul');entries.className='recent-list';
    section.append(heading,root,entries);document.querySelector('.workspace').before(section);
    try {
      const {paths}=await project.call('list');
      for(const path of paths.sort()) {
        const item=document.createElement('li'),link=document.createElement('a');
        link.href=`web/edit.html?file=${encodeURIComponent(path)}`;link.textContent=path;item.append(link);entries.append(item);
      }
      if(!paths.length){const empty=document.createElement('p');empty.textContent='No notebooks here yet. Create one above and use Save to choose its filename.';section.append(empty);}
    }catch(error){root.textContent=error.message;}
  }
}
