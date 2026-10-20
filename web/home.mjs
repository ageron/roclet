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
    status.textContent = 'A fresh start. Create a notebook or try a demo — your recent work will appear here.';
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
