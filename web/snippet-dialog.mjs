import {categories,dependencies,snippets,prepareSnippet} from './snippets.mjs';
import {renderDisplay} from './display-view.mjs';
import {closeMenus} from './notebook-panel.mjs';

export class SnippetDialog {
  constructor() {
    this.dialog=document.getElementById('snippet-dialog');
    this.$=id=>this.dialog.querySelector(`[data-snippet="${id}"]`);
    this.$('search').oninput=()=>this.renderList();
    this.$('category').onchange=()=>this.renderList();
    this.dialog.addEventListener('keydown',event=>{
      if(event.key==='Escape'){event.preventDefault();event.stopPropagation();this.dialog.close();}
    });
    for(const [id,label] of Object.entries(categories)) {
      const option=document.createElement('option');option.value=id;option.textContent=label;this.$('category').append(option);
    }
    this.$('list').onkeydown=event=>{
      const buttons=[...this.$('list').querySelectorAll('button')],index=buttons.indexOf(document.activeElement);
      let next;
      if(event.key==='ArrowDown')next=Math.min(index+1,buttons.length-1);
      if(event.key==='ArrowUp')next=Math.max(index-1,0);
      if(event.key==='Home')next=0;
      if(event.key==='End')next=buttons.length-1;
      if(next!==undefined && buttons[next]){event.preventDefault();buttons[next].focus();this.select(buttons[next].dataset.id);}
    };
    this.$('search').onkeydown=event=>{
      if(event.key==='ArrowDown'){event.preventDefault();this.$('list').querySelector('button')?.focus();}
    };
    this.$('insert').onclick=()=>{
      try {
        if(this.target.notebook.state.id!==this.documentId)throw Error('The notebook changed. Close and reopen Insert.');
        this.target.insertSnippet(this.selected,this.urls,this.position);
        this.inserted=true;this.dialog.close();this.target.editSelection();
      } catch(error){this.$('status').textContent=error.message;}
    };
    this.dialog.addEventListener('close',()=>{
      if(this.dialog.open)return; // Ignore a queued close event after reopening.
      this.disposePreview();
      if(!this.inserted && this.target?.notebook.state?.id===this.documentId)this.target.focusSelection();
    });
  }
  async open(target,category='all',position) {
    closeMenus();
    await target.prepareInsertion();
    this.target=target;this.documentId=target.notebook.state.id;this.position=position??target.insertionPosition();this.inserted=false;
    this.$('target').textContent=`Insert into ${target.title} · ${this.position ? `after cell ${this.position}`:'at start'}`;
    this.$('category').value=category;this.$('search').value='';this.$('status').textContent='';
    // Resolve the curated pins from assets that are also included offline.
    try {
      this.urls??=await (async()=>{
        const response=await fetch('./vendor/roc-packages/manifest.json');
        if(!response.ok)throw Error('Snippet packages are unavailable. Reload or rebuild this distribution.');
        const manifest=await response.json(),urls={};
        for(const [id,dep] of Object.entries(dependencies)) {
          if(dep.pin) {
            const pin=await fetch(dep.pin);
            if(!pin.ok)throw Error(`${dep.label} is unavailable in this distribution.`);
            urls[id]=(await pin.text()).trim();
          } else urls[id]=manifest.packages.find(p=>p.package===dep.repository && p.version===dep.version)?.url;
        }
        return urls;
      })();
    } catch(error){target.notice(error.message);return;}
    this.selected=null;this.renderList();this.dialog.showModal();this.$('search').focus();
  }
  renderList() {
    const category=this.$('category').value,words=this.$('search').value.toLowerCase().trim().split(/\s+/).filter(Boolean);
    const matches=snippets.filter(s=>(category==='all'||s.category===category) && words.every(w=>`${s.title} ${s.description} ${s.source} ${Object.keys(s.modules).map(id=>dependencies[id].label).join(' ')}`.toLowerCase().includes(w)));
    this.$('list').replaceChildren();
    for(const snippet of matches) {
      const button=document.createElement('button');button.type='button';button.dataset.id=snippet.id;
      const title=document.createElement('strong'),detail=document.createElement('small');title.textContent=snippet.title;detail.textContent=categories[snippet.category];button.append(title,detail);
      button.onclick=()=>this.select(snippet.id);this.$('list').append(button);
    }
    this.$('empty').hidden=matches.length>0;
    this.select(matches.find(s=>s.id===this.selected?.id)?.id??matches[0]?.id);
  }
  disposePreview(){for(const node of this.$('preview').children)node.dispose?.();this.$('preview').replaceChildren();}
  select(id) {
    this.selected=snippets.find(s=>s.id===id);this.disposePreview();
    this.$('detail').hidden=!this.selected;this.$('insert').disabled=!this.selected;this.$('status').textContent='';
    for(const button of this.$('list').children)button.setAttribute('aria-pressed',String(button.dataset.id===id));
    if(!this.selected)return;
    const snippet=this.selected;
    this.$('title').textContent=snippet.title;this.$('description').textContent=snippet.description;
    if(typeof snippet.preview==='string'){const pre=document.createElement('pre');pre.textContent=snippet.preview;this.$('preview').append(pre);}
    else {const view=renderDisplay(snippet.preview,snippet.preview.text,{onInput:()=>{}});if(view)this.$('preview').append(view);}
    try {
      const recipe=prepareSnippet(this.target.notebook.state,snippet,this.urls);
      this.$('code').textContent=recipe.source;
      const uses=Object.keys(snippet.modules).map(id=>dependencies[id].label);
      this.$('dependencies').textContent=recipe.added.length?`Adds ${recipe.added.join(' and ')}. Packages and imports are included automatically.`:uses.length?`Uses ${uses.join(' and ')}. Imports are included automatically.`:'No packages needed.';
    } catch(error){this.$('code').textContent=snippet.source;this.$('dependencies').textContent='';this.$('status').textContent=error.message;this.$('insert').disabled=true;}
  }
}
