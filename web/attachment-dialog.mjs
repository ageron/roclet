import {attachment,attachments,attachmentPath,attachmentPreview,fileSize} from './attachments.mjs';
import {download} from './sharing.mjs';

// One shared dialog stays bound to the notebook for which it was opened.
export class AttachmentDialog {
  constructor(doc = document) {
    this.doc=doc;
    this.$=id=>doc.getElementById(id);
    this.dialog=this.$('attachments-dialog');
    this.$('attachment-add').onclick=()=>this.$('attachment-upload').click();
    this.$('attachment-upload').onchange=event=>{
      const files=[...event.target.files];event.target.value='';void this.importFiles(files);
    };
    this.$('attachment-replace').onclick=()=>this.$('attachment-replacement').click();
    this.$('attachment-replacement').onchange=event=>{
      const file=event.target.files[0];event.target.value='';if(file) void this.importFiles([file],this.selected);
    };
    this.$('attachment-rename').onclick=()=>this.run(async()=>{
      const old=this.current(),path=this.$('attachment-path').value.trim();
      if(path===old.path)return;
      this.notebook.setAttachments(attachments((this.notebook.state.attachments??[]).map(file=>file===old?{...file,path}:file),this.notebook.state.files));
      await this.render(path);this.message('Path updated. Update the import in your code to match.');this.offerUndo();
    });
    this.$('attachment-remove').onclick=()=>this.run(async()=>{
      const path=this.current().path;this.notebook.removeAttachment(path);
      await this.render();this.message(`Removed “${path}”.`);this.offerUndo();
    });
    this.$('attachment-undo').onclick=()=>this.run(async()=>{
      if(this.notebook.state.revision!==this.undoRevision) {this.$('attachment-undo').hidden=true;return;}
      this.notebook.undo();await this.render();this.message('Attachment change undone.');this.$('attachment-undo').hidden=true;
    });
    this.$('attachment-download').onclick=()=>{
      const file=this.current();download(file.blob,file.path.split('/').at(-1));
      this.message('Download requested for the original file bytes.');
    };
    this.$('attachment-kind').onchange=()=>this.snippet();
    this.$('attachment-copy').onclick=()=>this.run(async()=>{
      const text=this.$('attachment-import').value;
      try {await navigator.clipboard.writeText(text);this.message('Import copied. Paste it into a Roc code cell.');}
      catch {this.$('attachment-import').focus();this.$('attachment-import').select();this.message('Select and copy the import above.');}
    });
    const drop=this.$('attachment-drop');
    drop.ondragover=event=>{event.preventDefault();drop.dataset.dragging='true';};
    drop.ondragleave=()=>{delete drop.dataset.dragging;};
    drop.ondrop=event=>{event.preventDefault();delete drop.dataset.dragging;void this.importFiles([...event.dataTransfer.files]);};
  }
  current() {return this.notebook.state.attachments?.find(file=>file.path===this.selected);}
  message(text,error=false) {
    const status=this.$('attachment-status');status.textContent=text;status.dataset.error=String(error);
    status.setAttribute('role',error?'alert':'status');
  }
  offerUndo() {this.undoRevision=this.notebook.state.revision;this.$('attachment-undo').hidden=false;}
  async run(work) {
    if(this.busy)return;
    this.busy=true;this.$('attachment-controls').inert=true;
    try {await work();}
    catch(error) {this.message(error.message,true);}
    finally {this.busy=false;this.$('attachment-controls').inert=false;}
  }
  async importFiles(files,replace=null) {
    if(!files.length)return;
    const notebook=this.notebook,id=notebook.state.id,epoch=this.epoch;
    await this.run(async()=>{
      this.message(files.length===1?'Copying file…':'Copying files…');
      // Validate all paths and sizes before reading; a batch either succeeds
      // completely or leaves the notebook unchanged.
      const existing=(notebook.state.attachments??[]).filter(file=>file.path!==replace);
      const planned=files.map(file=>({path:replace??attachmentPath(file),blob:file,sha256:'0'.repeat(64)}));
      const collision=planned.find(file=>existing.some(other=>other.path===file.path));
      if(collision)throw new Error(`“${collision.path}” is already attached. Select it and choose Replace file… to update its contents.`);
      attachments([...existing,...planned],notebook.state.files);
      const imported=await Promise.all(planned.map(file=>attachment(file.path,file.blob)));
      if(!this.dialog.open || notebook.state.id!==id || this.epoch!==epoch)return;
      // Re-read state after asynchronous file reads; never overwrite unrelated
      // changes made while the file picker or disk read was pending.
      notebook.setAttachments([...(notebook.state.attachments??[]).filter(file=>file.path!==replace),...imported]);
      await this.render(imported[0].path);
      this.message(replace?`Replaced the copy at “${replace}”. Its import path stays the same.`:`${files.length===1?'File copied':`${files.length} files copied`} into this notebook. Nothing was uploaded.`);
      this.offerUndo();
    });
  }
  async open(target) {
    this.epoch=(this.epoch??0)+1;
    this.notebook=target.notebook;this.selected=null;
    this.$('attachment-undo').hidden=true;
    this.$('attachments-title').textContent=`Attachments · ${target.title}`;
    this.message('');this.dialog.showModal();await this.render();
  }
  snippet() {
    const file=this.current();if(!file)return;
    // Validation excludes characters that require escaping/interpolation in
    // the pinned compiler's literal file-import paths.
    this.$('attachment-import').value=`import ${JSON.stringify(file.path)} as file_data : ${this.$('attachment-kind').value==='bytes'?'List(U8)':'Str'}`;
  }
  async render(selected=this.selected) {
    const files=this.notebook.state.attachments??[];
    const focusedPath=this.doc.activeElement?.closest('.attachment-entry')?.dataset.path;
    this.selected=files.some(file=>file.path===selected)?selected:files[0]?.path;
    const list=this.$('attachment-list');list.replaceChildren();
    this.$('attachment-count').textContent=`${files.length} ${files.length===1?'file':'files'} · ${fileSize(files.reduce((n,file)=>n+file.blob.size,0))} of 16 MiB`;
    this.$('attachment-empty').hidden=files.length>0;
    this.$('attachment-details').hidden=!files.length;
    for(const file of files) {
      const button=this.doc.createElement('button'),name=this.doc.createElement('strong'),size=this.doc.createElement('small');
      button.type='button';button.className='attachment-entry';button.dataset.path=file.path;
      button.setAttribute('aria-pressed',String(file.path===this.selected));
      name.textContent=file.path;size.textContent=fileSize(file.blob.size);button.append(name,size);
      button.onclick=()=>{void this.render(file.path);this.message('');};list.append(button);
      if(focusedPath && file.path===this.selected)button.focus({preventScroll:true});
    }
    const file=this.current();if(!file)return;
    this.$('attachment-path').value=file.path;
    this.$('attachment-meta').textContent=`${fileSize(file.blob.size)} · ${file.blob.type||'No media type'}`;
    this.snippet();
    this.$('attachment-preview').textContent='Loading preview…';
    const preview=await attachmentPreview(file);
    if(this.current()!==file || !this.dialog.open)return;
    this.$('attachment-kind').value=preview.kind;
    this.$('attachment-preview-label').textContent=preview.kind==='text'?'UTF-8 text preview':'Raw bytes · hexadecimal preview';
    this.$('attachment-preview').textContent=preview.text||'(empty file)';
    this.$('attachment-preview-note').textContent=preview.truncated?'Preview shortened. The complete file is saved.':'';
    this.snippet();
  }
}
