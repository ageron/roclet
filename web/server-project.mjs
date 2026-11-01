// Optional local-server transport. Static hosting never needs this API.
export class ServerProject {
  constructor(config,{fetch=globalThis.fetch.bind(globalThis)}={}) { this.config=config;this.fetch=fetch; }
  async call(action,path='',extra={}) {
    const response=await this.fetch('/api/local/files',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-Roclet-Token':this.config.token},body:JSON.stringify({action,path,...extra})});
    const result=await response.json();
    if(!response.ok)throw new Error(result.error || `Local server: HTTP ${response.status}`);
    return result;
  }
  handle(path) {
    const project=this;let expected;
    return {
      name:path.split('/').at(-1),serverPath:path,projectRoot:project.config.root,
      async isSameEntry(other) {return other.projectRoot===project.config.root && other.serverPath===path;},
      async getFile() {
        const {source}=await project.call('read',path);expected=source;
        return {name:this.name,exists:source!==null,size:new TextEncoder().encode(source??'').length,text:async()=>source??''};
      },
      async createWritable() {
        const baseline=expected;let source,aborted=false;
        return {async write(text){source=text;},async abort(){aborted=true;},async close(){
          if(aborted || typeof source!=='string')throw new Error('Save was cancelled.');
          await project.call('write',path,{source,expected:baseline});
        }};
      },
    };
  }
  async files(state) {
    if(state.serverFile?.project!==this.config.root)return null;
    return (await this.call('workspace',state.serverFile.path)).files;
  }
  async pick({save=false,name='notebook.roc'}={}) {
    const {paths}=await this.call('list');
    return new Promise((resolve,reject)=>{
      const dialog=document.createElement('dialog');dialog.className='local-project-dialog';
      const heading=document.createElement('h2');heading.textContent=save?'Save notebook':'Open notebook';
      const root=document.createElement('p');root.textContent=this.config.root;root.style.overflowWrap='anywhere';
      const label=document.createElement('label');label.textContent='Path within project';
      const input=document.createElement('input');input.type='text';input.value=save?name:'';input.placeholder='notes/notebook.roc';input.style.width='100%';label.append(input);
      const list=document.createElement('div');list.style.cssText='display:grid;max-height:45vh;overflow:auto;gap:4px;margin:12px 0';
      const message=document.createElement('p');message.setAttribute('role','status');
      const actions=document.createElement('div');actions.style.cssText='display:flex;gap:8px;justify-content:flex-end';
      const cancel=document.createElement('button');cancel.textContent='Cancel';
      const accept=document.createElement('button');accept.textContent=save?'Save':'Open';
      const finish=async()=>{
        accept.disabled=true;
        try {
          const path=input.value.trim();
          if(!path || /[\\:\x00-\x1f]/.test(path) || path.split('/').some(p=>!p||p.startsWith('.')) || !/\.(roc|md)$/.test(path))throw new Error('Choose a relative .roc or .md path within the project.');
          const {source}=await this.call('read',path);
          if(!save && source===null)throw new Error('This file does not exist.');
          if(save && source!==null && !confirm(`Replace ${path}?`))return;
          resolve(this.handle(path));dialog.close();
        }catch(error){message.textContent=error.message;}finally{accept.disabled=false;}
      };
      const render=()=>{list.replaceChildren();for(const path of paths.sort().filter(p=>p.toLowerCase().includes(input.value.toLowerCase()))){const button=document.createElement('button');button.textContent=path;button.style.textAlign='left';button.onclick=()=>{input.value=path;if(!save)void finish();};list.append(button);}};
      input.oninput=render;input.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();void finish();}};
      accept.onclick=finish;cancel.onclick=()=>dialog.close();
      dialog.onclose=()=>{dialog.remove();reject(new DOMException('Cancelled','AbortError'));};
      actions.append(cancel,accept);dialog.append(heading,root,label,list,message,actions);document.body.append(dialog);render();dialog.showModal();input.focus();
    });
  }
}
export let serverProject=null;
export const serverProjectReady=(async()=>{
  if(!globalThis.location || !['127.0.0.1','localhost','[::1]'].includes(location.hostname))return null;
  try {
    const response=await fetch('/api/local/config',{cache:'no-store'});
    if(!response.ok)return null;
    const config=await response.json();
    if(typeof config.root!=='string'||typeof config.token!=='string')return null;
    return serverProject=new ServerProject(config);
  }catch{return null;}
})();
