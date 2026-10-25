import { EditorState, EditorSelection, Compartment, StateEffect, StateField, Prec, Transaction } from '@codemirror/state';
import { EditorView, keymap, drawSelection, rectangularSelection, crosshairCursor, Decoration, hoverTooltip } from '@codemirror/view';
import { defaultKeymap, indentWithTab, addCursorAbove, addCursorBelow } from '@codemirror/commands';
import { selectNextOccurrence, selectSelectionMatches, search, searchKeymap, openSearchPanel } from '@codemirror/search';
import { Language, defineLanguageFacet, languageDataProp, syntaxHighlighting, HighlightStyle, indentUnit } from '@codemirror/language';
import { parser, GFM } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import { moveVertical, smartHome, enterAtBoundary } from './editor-navigation.mjs';

const owners=new WeakMap();
export const editorFor = node => owners.get(node?.closest?.('.cm-editor'));
const colorEffect=StateEffect.define();
const colors=StateField.define({
  create:()=>Decoration.none,
  update(value,tr) { if(tr.docChanged) value=Decoration.none; for(const effect of tr.effects) if(effect.is(colorEffect)) value=effect.value; return value; },
  provide:field=>EditorView.decorations.from(field),
});
const mdData=defineLanguageFacet({commentTokens:{block:{open:'<!--',close:'-->'}}});
const markdown=new Language(mdData,parser.configure([GFM,{props:[languageDataProp.add({Document:mdData})]}]),[],'markdown');
const roc=EditorState.languageData.of(()=>[{commentTokens:{line:'#'}}]);
const highlighting=HighlightStyle.define([
  {tag:tags.heading,class:'tok-heading'}, {tag:tags.strong,class:'tok-strong'}, {tag:tags.emphasis,class:'tok-emphasis'},
  {tag:[tags.url,tags.link],class:'tok-link'}, {tag:tags.monospace,class:'tok-code'}, {tag:tags.strikethrough,class:'tok-strike'},
  {tag:[tags.processingInstruction,tags.contentSeparator,tags.meta],class:'tok-markup'},
]);
const theme=EditorView.theme({
  '&':{fontSize:'14px',background:'transparent',borderRadius:'7px'},'&.cm-focused':{outline:'none'},
  '.cm-scroller':{fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',lineHeight:'1.7',maxHeight:'min(550px,70vh)',overflow:'auto'},
  '.cm-content':{padding:'12px 0',minHeight:'54px',caretColor:'var(--text, #294338)'},'.cm-line':{padding:'0 18px'},
  '&.cm-focused .cm-cursor':{borderLeftColor:'var(--text, #294338)'},'.cm-selectionBackground':{background:'var(--selection, #dbe6de)'},
  '&.cm-focused .cm-selectionBackground':{background:'var(--selection-active, #c7dfd0)'},
  '.cm-content .tok-keyword,.tok-markup':{color:'var(--keyword, #8750a0)'},'.cm-content .tok-string':{color:'var(--string, #32784e)'},'.cm-content .tok-number':{color:'var(--number, #a45f28)'},
  '.cm-content .tok-type':{color:'var(--syntax-type, #326f9b)'},'.cm-content .tok-operator':{color:'var(--operator, #755d91)'},'.cm-content .tok-variable':{color:'var(--text, #294338)'},
  '.cm-content .tok-comment':{color:'var(--comment, #7d8981)',fontStyle:'italic'},'.tok-heading':{color:'var(--accent, #356d51)',fontWeight:'650'},
  '.tok-strong':{fontWeight:'700'},'.tok-emphasis':{fontStyle:'italic'},'.tok-link':{color:'var(--syntax-type, #326f9b)',textDecoration:'underline'},
  '.tok-code':{color:'var(--number, #9a5d37)'},'.tok-strike':{textDecoration:'line-through'},
});
export class CellEditor {
  constructor(parent,{source='',kind='code',label='Cell source',positions,highlighter,onChange=()=>{},onFocus=()=>{},onSelection=()=>{},onComposition=()=>{},adjacent=()=>false,symbol=()=>null,completions=()=>[],onRename=()=>{}}={}) {
    this.completions=completions;
    this.highlighter=highlighter; this.kind=kind; this.syncing=false; this.destroyed=false;
    this.language=new Compartment(); this.accessible=new Compartment();
    const motion=(forward,page=false,extend=false)=>view=>moveVertical(view,forward,page,extend,adjacent);
    const keys=[
      {key:'Ctrl-Space',run:()=>this.complete()},
      {key:'F2',run:view=>{onRename(view.state.selection.main.head);return true;}},
      {key:'Escape',run:()=>this.closeCompletion()},
      {key:'Enter',run:()=>this.acceptCompletion()},
      {key:'Tab',run:()=>this.acceptCompletion()},
      {key:'ArrowUp',run:view=>this.moveCompletion(-1)||motion(false)(view),shift:motion(false,false,true)}, {key:'ArrowDown',run:view=>this.moveCompletion(1)||motion(true)(view),shift:motion(true,false,true)},
      {key:'PageUp',run:motion(false,true),shift:motion(false,true,true)}, {key:'PageDown',run:motion(true,true),shift:motion(true,true,true)},
      {key:'Meta-ArrowUp',run:motion(false,'edge'),shift:motion(false,'edge',true)}, {key:'Meta-ArrowDown',run:motion(true,'edge'),shift:motion(true,'edge',true)},
      {key:'Home',run:view=>smartHome(view),shift:view=>smartHome(view,true)}, {key:'Meta-ArrowLeft',run:view=>smartHome(view),shift:view=>smartHome(view,true)},
      {key:'Mod-Alt-ArrowUp',run:addCursorAbove}, {key:'Mod-Alt-ArrowDown',run:addCursorBelow},
      {key:'Mod-d',run:selectNextOccurrence}, {key:'Mod-Shift-l',run:selectSelectionMatches}, indentWithTab,
    ];
    const extensions=[EditorState.allowMultipleSelections.of(true),EditorState.tabSize.of(4),indentUnit.of('    '),
      drawSelection(),rectangularSelection({eventFilter:event=>event.altKey && event.shiftKey}),crosshairCursor({key:'Alt'}),
      EditorView.clickAddsSelectionRange.of(event=>event.altKey && !event.shiftKey),
      Prec.highest(keymap.of(keys)),keymap.of(defaultKeymap),theme,colors,syntaxHighlighting(highlighting),
      search(),keymap.of(searchKeymap),
      hoverTooltip((view,pos)=>{
        if(this.kind!=='code') return null;
        const d=symbol(pos); if(!d) return null;
        return {pos,above:true,create:()=>{const dom=document.createElement('div');dom.className='roc-type-tooltip';dom.textContent=`${d.name} : ${d.type}`;return {dom};}};
      },{hoverTime:350}),
      this.language.of(kind==='markdown'?markdown:roc),this.accessible.of(EditorView.contentAttributes.of({'aria-label':label,'aria-multiline':'true',spellcheck:'false'})),
      EditorView.domEventHandlers({scroll:()=>{this.closeCompletion();return false;},blur:()=>{this.closeCompletion();return false;},focus:()=>{onFocus();return false;},compositionstart:()=>{onComposition(true);return false;},compositionend:()=>{onComposition(false);return false;}}),
      EditorView.updateListener.of(update=>{
        if(this.syncing) return;
        if(update.docChanged) { onChange(this.source,update.view.composing,update.state.selection.toJSON()); this.highlighter?.request(this); if(this.completion) this.complete(); }
        else if(update.selectionSet) {this.closeCompletion();onSelection(update.state.selection.toJSON());}
      }),
    ];
    this.view=new EditorView({parent,state:EditorState.create({doc:source,extensions})}); owners.set(this.view.dom,this);
    if(positions) this.restoreSelection(positions);
    this.highlighter?.request(this);
  }
  get source() { return this.view.state.doc.toString(); }
  get element() { return this.view.contentDOM; }
  get dom() { return this.view.dom; }
  focus() { this.view.focus(); }
  setHidden(hidden) { if(this.dom.hidden!==hidden) { this.dom.hidden=hidden; if(!hidden) this.view.requestMeasure(); } }
  setLabel(label,description) { if(this.label===label) return; this.label=label; this.view.dispatch({effects:this.accessible.reconfigure(EditorView.contentAttributes.of({'aria-label':label,'aria-describedby':description,'aria-multiline':'true',spellcheck:'false'}))}); }
  sync(source,kind,positions) {
    if(source!==this.source || kind!==this.kind) this.closeCompletion();
    this.syncing=true;
    try {
      if(source!==this.source) { this.view.dispatch({changes:{from:0,to:this.view.state.doc.length,insert:source},annotations:Transaction.addToHistory.of(false)}); if(positions) this.restoreSelection(positions); this.highlighter?.request(this); }
      if(kind!==this.kind) { this.kind=kind; this.view.dispatch({effects:[this.language.reconfigure(kind==='markdown'?markdown:roc),colorEffect.of(Decoration.none)]}); this.highlighter?.request(this); }
    } finally { this.syncing=false; }
  }
  restoreSelection(positions) {
    try { const size=this.view.state.doc.length; this.view.dispatch({selection:EditorSelection.create(positions.ranges.map(r=>EditorSelection.range(Math.min(size,r.anchor),Math.min(size,r.head))),Math.min(positions.main??0,positions.ranges.length-1))}); } catch { /* Old cursor positions are optional browser state. */ }
  }
  search() { openSearchPanel(this.view); }
  selectMatch(from,to) { this.view.dispatch({selection:{anchor:from,head:to},scrollIntoView:true}); }
  goTo(line,column=1,byteColumn=false) { const l=this.view.state.doc.line(Math.max(1,Math.min(this.view.state.doc.lines,line))); const offset=byteColumn?new TextDecoder().decode(new TextEncoder().encode(l.text).slice(0,Math.max(0,column-1))).length:Math.max(0,column-1); this.view.dispatch({selection:{anchor:Math.min(l.to,l.from+offset)},scrollIntoView:true}); this.focus(); }
  enter(forward,goal) { enterAtBoundary(this.view,forward,goal); }
  highlight(source,spans) {
    if(this.destroyed || this.source!==source) return;
    const marks=spans.filter(s=>s.to>s.from && s.to<=source.length).map(s=>Decoration.mark({class:`tok-${s.kind}`}).range(s.from,s.to));
    const view=this.view, selection=view.state.selection, focused=view.hasFocus;
    view.dispatch({effects:colorEffect.of(Decoration.set(marks,true))});
    // Chrome can collapse its native selection when highlighting wraps an
    // existing text node, even though CodeMirror retained the same selection.
    // Restore the main DOM range before the next selectionchange is observed.
    // Secondary cursors remain in CodeMirror's selection/drawing state.
    if(focused && view.hasFocus && !view.composing && view.state.selection.eq(selection)) {
      const anchor=view.domAtPos(selection.main.anchor),head=view.domAtPos(selection.main.head);
      const native=view.root.getSelection?.() ?? view.dom.ownerDocument.getSelection();
      if(native && (native.anchorNode!==anchor.node || native.anchorOffset!==anchor.offset || native.focusNode!==head.node || native.focusOffset!==head.offset))
        native.setBaseAndExtent(anchor.node,anchor.offset,head.node,head.offset);
    }
  }
  complete() {
    if(this.kind!=='code' || this.view.state.selection.ranges.length!==1) return false;
    const pos=this.view.state.selection.main.head, line=this.view.state.doc.lineAt(pos);
    const prefix=line.text.slice(0,pos-line.from).match(/[A-Za-z_][A-Za-z0-9_]*$/)?.[0] ?? '';
    const options=this.completions(prefix).filter(o=>o.label!==prefix).slice(0,30);
    this.closeCompletion(); if(!options.length) return true;
    const dom=document.createElement('div');dom.className='roc-completions';dom.setAttribute('role','listbox');dom.id=`completion-${crypto.randomUUID()}`;
    this.completion={dom,options,from:pos-prefix.length,to:pos,index:0};
    options.forEach((o,index)=>{const row=document.createElement('div');row.setAttribute('role','option');row.id=`${dom.id}-${index}`;
      const name=document.createElement('span'),type=document.createElement('small');name.textContent=o.label;type.textContent=o.detail;row.append(name,type);
      row.onmousedown=event=>{event.preventDefault();this.completion.index=index;this.acceptCompletion();};dom.append(row);});
    document.body.append(dom);const rect=this.view.coordsAtPos(pos) ?? this.dom.getBoundingClientRect();
    dom.style.left=`${Math.max(8,Math.min(rect.left,innerWidth-dom.offsetWidth-8))}px`;dom.style.top=`${Math.max(8,Math.min(rect.bottom+4,innerHeight-dom.offsetHeight-8))}px`;
    this.element.setAttribute('aria-controls',dom.id);this.moveCompletion(0);return true;
  }
  moveCompletion(delta) {
    const c=this.completion;if(!c)return false;c.index=(c.index+delta+c.options.length)%c.options.length;
    [...c.dom.children].forEach((row,i)=>row.setAttribute('aria-selected',String(i===c.index)));
    const active=c.dom.children[c.index];active.scrollIntoView({block:'nearest'});this.element.setAttribute('aria-activedescendant',active.id);return true;
  }
  acceptCompletion() {
    const c=this.completion;if(!c)return false;this.closeCompletion();
    const insert=c.options[c.index].label;this.view.dispatch({changes:{from:c.from,to:c.to,insert},selection:{anchor:c.from+insert.length},userEvent:'input.complete'});this.focus();return true;
  }
  closeCompletion() {
    if(!this.completion)return false;this.completion.dom.remove();this.completion=null;
    this.element.removeAttribute('aria-controls');this.element.removeAttribute('aria-activedescendant');return true;
  }
  destroy() { if(this.destroyed) return; this.destroyed=true; this.closeCompletion(); this.highlighter?.cancel(this); owners.delete(this.dom); this.view.destroy(); }
}
