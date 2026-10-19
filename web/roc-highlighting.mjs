import { DocumentSession } from './document-session.mjs';

export function rocSpans(source, facts, offset = 0) {
  const bytes = new TextEncoder().encode(source), spans = [];
  // The compiler uses UTF-8 offsets. CodeMirror uses UTF-16 positions.
  const positions = new Uint32Array(bytes.length + 1); let byte = 0, utf16 = 0;
  for (const character of source) {
    const point = character.codePointAt(0), size = point > 0xffff ? 4 : point > 0x7ff ? 3 : point > 0x7f ? 2 : 1;
    for (let i=0;i<size;i++) positions[byte+i]=utf16;
    byte+=size; utf16+=character.length; positions[byte]=utf16;
  }
  const mark = (from,to,kind) => { if (to > from && from >= 0 && to <= bytes.length) spans.push({from:offset+positions[from],to:offset+positions[to],kind}); };
  const commentGap = (from,to) => {
    for (let i=from;i<to;i++) if (bytes[i]===35) {
      let end=i; while(end<to && bytes[end]!==10 && bytes[end]!==13) end++;
      mark(i,end,'comment'); i=end;
    }
  };
  let end=0;
  for (const token of facts?.tokens??[]) {
    commentGap(end,token.start); end=token.end;
    const tag=token.tag;
    let kind = tag.startsWith('Kw') ? 'keyword' : /String|SingleQuote|Escape/.test(tag) && !/Interpolation/.test(tag) ? 'string' : /^(Float|Int)$|Number|DotInt/.test(tag) ? 'number' : /UpperIdent|OpaqueName/.test(tag) ? 'type' : /Op|Interpolation/.test(tag) ? 'operator' : /LowerIdent/.test(tag) ? 'variable' : null;
    if (kind) mark(token.start,token.end,kind);
  }
  commentGap(end,bytes.length); return spans;
}
export function syntaxSpans(source, kind, result) {
  if (kind === 'code') return rocSpans(source,result.facts);
  const bytes=new TextEncoder().encode(source), decoder=new TextDecoder();
  return (result.blocks??[]).filter(b=>b.kind==='fence' && b.info==='roc').flatMap(b=>rocSpans(decoder.decode(bytes.slice(b.body_start,b.body_end)),b.facts,decoder.decode(bytes.slice(0,b.body_start)).length));
}
// One serial, coalescing syntax worker per Roclet; it never executes user code.
export class CompilerHighlighter {
  constructor(bytes) { this.session=new DocumentSession(bytes); this.pending=new Map(); this.cache=new Map(); this.closed=false; }
  request(editor) {
    if (this.closed) return;
    const source=editor.source, kind=editor.kind, key=kind+'\0'+source;
    if (this.cache.has(key)) { const spans=this.cache.get(key); queueMicrotask(()=>{if(!editor.destroyed && editor.source===source && editor.kind===kind) editor.highlight(source,spans);}); return; }
    this.pending.set(editor,{source,kind,key}); clearTimeout(this.timer);
    this.timer=setTimeout(()=>this.drain(),100);
  }
  cancel(editor) { this.pending.delete(editor); }
  async drain() {
    if (this.running || this.closed) return;
    this.running=true;
    while(this.pending.size && !this.closed) {
      const [editor,request]=this.pending.entries().next().value; this.pending.delete(editor);
      const timeout=setTimeout(()=>this.session.stop(),5000);
      try {
        const result=await this.session.request({operation:'syntax',source:request.source});
        const spans=syntaxSpans(request.source,request.kind,result);
        this.cache.set(request.key,spans); while(this.cache.size>24) this.cache.delete(this.cache.keys().next().value);
        if (!editor.destroyed && editor.source===request.source && editor.kind===request.kind) editor.highlight(request.source,spans);
      } catch { /* Syntax coloring never prevents editing or changes diagnostics. */ }
      finally { clearTimeout(timeout); }
    }
    this.running=false;
  }
  dispose() { this.closed=true; clearTimeout(this.timer); this.pending.clear(); this.cache.clear(); this.session.stop(); }
}
