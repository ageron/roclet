import { EditorSelection, findColumn } from '@codemirror/state';

// Keep CodeMirror's pixel goal across short lines, pages and editor boundaries.
export function horizontalGoal(view, range = view.state.selection.main) {
  if (range.goalColumn != null) return range.goalColumn;
  const coords = view.coordsAtPos(range.head, range.assoc);
  return coords ? coords.left - view.contentDOM.getBoundingClientRect().left : 18;
}
export function cursorOnLine(view, line, goal) {
  const coords = view.coordsAtPos(line.from), rect = view.contentDOM.getBoundingClientRect();
  let pos = coords && view.posAtCoords({x:rect.left + goal,y:(coords.top + coords.bottom) / 2}, true);
  // CodeMirror's column helper accounts for tabs and grapheme clusters when the
  // target line is not yet drawn. A measurement refines it after scrolling.
  if (pos == null || pos < line.from || pos > line.to) pos = line.from + findColumn(line.text, Math.max(0,Math.round((goal - 18) / view.defaultCharacterWidth)), view.state.tabSize);
  return EditorSelection.cursor(pos, 0, undefined, goal);
}
export function enterAtBoundary(view, forward, goal) {
  const line = view.state.doc.line(forward ? 1 : view.state.doc.lines);
  const range = cursorOnLine(view, line, goal);
  view.dispatch({selection:range,scrollIntoView:true,userEvent:'select'}); view.focus();
  const expected = view.state.selection, doc = view.state.doc;
  view.requestMeasure({
    read: () => cursorOnLine(view, line, goal),
    write: measured => {
      if (view.hasFocus && view.state.doc === doc && view.state.selection === expected && measured.head !== range.head) view.dispatch({selection:measured,scrollIntoView:true,userEvent:'select'});
    },
  });
}
// The part of a notebook panel's scroller not covered by its sticky title bar.
function visibleHeight(view) {
  const scroller = view.dom.closest('.panel-scroll');
  if (!scroller) return view.dom.ownerDocument.defaultView.innerHeight - 110;
  return scroller.clientHeight - (scroller.querySelector(':scope > .panel-title')?.offsetHeight ?? 0);
}
export function moveVertical(view, forward, page, extend, adjacent) {
  const {state} = view, main = state.selection.main, line = state.doc.lineAt(main.head);
  if (!extend && state.selection.ranges.length === 1 && main.empty && line.number === (forward ? state.doc.lines : 1)) {
    if (adjacent?.(forward, horizontalGoal(view,main))) return true;
  }
  const height = Math.max(view.defaultLineHeight, Math.min(view.scrollDOM.clientHeight, visibleHeight(view)) - view.defaultLineHeight);
  const ranges = state.selection.ranges.map(range => {
    if (!extend && !range.empty) return EditorSelection.cursor(forward ? range.to : range.from);
    const goal = horizontalGoal(view,range), start = EditorSelection.cursor(range.head,range.assoc,undefined,goal);
    let moved = view.moveVertically(start,forward,page ? height : undefined);
    const target = state.doc.lineAt(moved.head);
    moved = cursorOnLine(view,target,goal);
    // Extending a page selection through an edge includes the entire edge line.
    if (page && extend && target.number === (forward ? state.doc.lines : 1)) moved = EditorSelection.cursor(forward ? state.doc.length : 0, 0, undefined, goal);
    return extend ? EditorSelection.range(range.anchor,moved.head,goal) : EditorSelection.cursor(moved.head,moved.assoc,undefined,goal);
  });
  view.dispatch({selection:EditorSelection.create(ranges,state.selection.mainIndex),scrollIntoView:true,userEvent:'select'});
  const expected=view.state.selection, doc=view.state.doc;
  view.requestMeasure({
    read:()=>expected.ranges.map(r=>{
      if (page && extend && r.head === (forward ? doc.length : 0)) return r;
      const measured=cursorOnLine(view,doc.lineAt(r.head),r.goalColumn ?? horizontalGoal(view,r));
      return extend ? EditorSelection.range(r.anchor,measured.head,measured.goalColumn) : measured;
    }),
    write:measured=>{if(view.hasFocus && view.state.doc===doc && view.state.selection===expected && measured.some((r,i)=>r.head!==expected.ranges[i].head)) view.dispatch({selection:EditorSelection.create(measured,expected.mainIndex),scrollIntoView:true,userEvent:'select'});},
  });
  return true;
}
export function smartHome(view, extend = false) {
  const ranges = view.state.selection.ranges.map(range => {
    const line = view.state.doc.lineAt(range.head), column = range.head - line.from;
    const indent = /[^\t ]/.test(line.text) ? /^[\t ]*/.exec(line.text)[0].length : 0;
    const target = line.from + (column === 0 || column > indent ? indent : 0);
    return extend ? EditorSelection.range(range.anchor,target) : EditorSelection.cursor(target);
  });
  view.dispatch({selection:EditorSelection.create(ranges,view.state.selection.mainIndex),scrollIntoView:true,userEvent:'select'}); return true;
}
