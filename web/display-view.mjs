import {renderMarkdown} from './markdown-view.mjs';

// Validate even cached/imported snapshots. Renderers never interpret inspected Roc.
export function normalizeDisplay(value) {
  if (!value || value.version!==1 || !['text','markdown','table','image'].includes(value.kind)) return null;
  if (typeof value.text!=='string' || value.text.length>65536) return null;
  const out={version:1,kind:value.kind,text:value.text};
  if (value.kind==='table') {
    if (!Array.isArray(value.columns) || value.columns.length>16 || !Array.isArray(value.rows) || value.rows.length>200) return null;
    const cell=s=>typeof s==='string' && s.length<=512;
    if (!value.columns.every(cell) || !value.rows.every(row=>Array.isArray(row) && row.length===value.columns.length && row.every(cell))) return null;
    if (![value.row_count,value.column_count].every(n=>Number.isSafeInteger(n) && n>=0) || value.row_count<value.rows.length || value.column_count<value.columns.length) return null;
    Object.assign(out,{columns:[...value.columns],rows:value.rows.map(row=>[...row]),row_count:value.row_count,column_count:value.column_count});
  } else if (value.kind==='markdown') {
    if (typeof value.content!=='string' || value.content.length>16388 || !Array.isArray(value.events) || value.events.length>20000) return null;
    let size=0;
    for (const event of value.events) {
      if (!['block_start','block_end','span_start','span_end','text'].includes(event?.event) || !Number.isInteger(event.kind) || typeof event.text!=='string' || !Number.isFinite(event.detail)) return null;
      size+=event.text.length; if(size>262144) return null;
    }
    out.content=value.content;out.events=value.events.map(({event,kind,text,detail})=>({event,kind,text,detail}));
  } else if(value.kind==='image') {
    if (!['image/png','image/jpeg','image/webp'].includes(value.mime) || typeof value.content!=='string' || value.content.length>131072 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.content) || !value.content) return null;
    let signature;try {signature=atob(value.content.slice(0,32));}catch {return null;}
    if (value.mime==='image/png' && !signature.startsWith('\x89PNG\r\n\x1a\n')) return null;
    if (value.mime==='image/jpeg' && !signature.startsWith('\xff\xd8\xff')) return null;
    if (value.mime==='image/webp' && !(signature.startsWith('RIFF') && signature.slice(8,12)==='WEBP')) return null;
    out.content=value.content;out.mime=value.mime;
  }
  return out;
}

export function renderDisplay(raw,text,{doc=document,interactive=true}={}) {
  if (raw==null) return null;
  const root=doc.createElement('div');root.className='rich-output';
  const value=normalizeDisplay(raw);
  const note=message=>{const p=doc.createElement('p');p.className='display-note';p.textContent=message;root.append(p);};
  const fallback=()=>{const details=doc.createElement('details'),summary=doc.createElement('summary'),pre=doc.createElement('pre');summary.textContent='Plain text';pre.textContent=text;details.append(summary,pre);root.append(details);return details;};
  if (!value) {note('Rich preview unavailable. The plain-text result is still available.');fallback().open=true;return root;}
  try {
    if (value.kind==='text') {const pre=doc.createElement('pre');pre.textContent=text;root.append(pre);return root;}
    if (value.kind==='markdown') root.append(renderMarkdown(value.events,doc));
    if (value.kind==='image') {
      const img=doc.createElement('img');img.alt=text;img.src=`data:${value.mime};base64,${value.content}`;img.className='display-image';
      img.onerror=()=>{img.remove();note('Image preview unavailable.');};root.append(img);
    }
    if (value.kind==='table') {
      const wrap=doc.createElement('div'),table=doc.createElement('table'),caption=doc.createElement('caption'),head=doc.createElement('thead'),body=doc.createElement('tbody'),tr=doc.createElement('tr');
      wrap.className='display-table-scroll';wrap.tabIndex=0;wrap.setAttribute('aria-label','Scrollable result table');
      caption.textContent=`${value.row_count} rows × ${value.column_count} columns`;table.append(caption,head,body);head.append(tr);
      for(const name of value.columns) {const th=doc.createElement('th');th.scope='col';th.textContent=name;tr.append(th);}
      wrap.append(table);root.append(wrap);
      const controls=doc.createElement('div'),status=doc.createElement('span');controls.className='display-pagination';status.setAttribute('aria-live','polite');
      let page=0;const pageSize=interactive?50:200;
      const previous=doc.createElement('button'),next=doc.createElement('button');previous.textContent='Previous';next.textContent='Next';previous.type=next.type='button';previous.setAttribute('aria-label','Previous table page');next.setAttribute('aria-label','Next table page');
      const show=()=>{
        body.replaceChildren();const start=page*pageSize,end=Math.min(value.rows.length,start+pageSize);
        for(const row of value.rows.slice(start,end)) {const tr=doc.createElement('tr');for(const cell of row) {const td=doc.createElement('td');td.textContent=cell;if(cell.endsWith('…')) td.title='Preview value; long cells may be shortened';tr.append(td);}body.append(tr);}
        status.textContent=value.rows.length?`Rows ${start+1}–${end} of ${value.row_count}`:'No rows';previous.disabled=page===0;next.disabled=end>=value.rows.length;
      };
      previous.onclick=()=>{page--;show();};next.onclick=()=>{page++;show();};
      if(interactive && value.rows.length>pageSize) controls.append(previous,status,next);else controls.append(status);
      if(interactive && value.rows.length>pageSize) root.append(controls);show();
      const limits=[];if(value.row_count>value.rows.length) limits.push(`Preview limited to ${value.rows.length} of ${value.row_count} rows.`);if(value.column_count>value.columns.length) limits.push(`Showing ${value.columns.length} of ${value.column_count} columns.`);if(limits.length) note(limits.join(' '));
    }
    fallback();
  } catch {
    root.replaceChildren();note('Rich preview unavailable. The plain-text result is still available.');fallback().open=true;
  }
  return root;
}
