// Semantic locations come exclusively from the checked compiler response.
const bytes = new TextEncoder(), text = new TextDecoder();
export function sourceRange(result, span) {
  if (!span) return null;
  const m = result.mappings?.find(m => m.generated_start <= span.start && span.end <= m.generated_end);
  if (!m) return null;
  const cell = result.model.cells[m.cell];
  // Notebook editors show normalized cell.source. source_map maps this back
  // to the imported file (escaped marker directives); applying it here would
  // shift the cursor into source text the editor does not contain.
  const convert = offset => m.source_start + offset - m.generated_start - cell.body_start;
  const start=convert(span.start), end=convert(span.end), encoded=bytes.encode(cell.source);
  if (start<0 || end>encoded.length || end<start) return null;
  return {cell:m.cell, from:text.decode(encoded.slice(0,start)).length, to:text.decode(encoded.slice(0,end)).length};
}
export function symbols(result) {
  if (!result?.graph) return [];
  return (result.evaluation?.definitions ?? []).filter(d=>!d.name_region || d.name_region.end>d.name_region.start).map(d => ({...d, locations:[d.name_region,...(d.references ?? [])].map(r=>sourceRange(result,r)).filter(Boolean)}));
}
export function symbolAt(result, cell, position) {
  return symbols(result).find(d=>d.locations.some(r=>r.cell===cell && r.from<=position && position<=r.to));
}
export function renameEdits(result, cell, position, name) {
  const d=symbolAt(result,cell,position);
  if (!d) throw new Error('Place the cursor on a checked top-level name.');
  if (!/^[a-z][A-Za-z0-9_]*$/.test(name)) throw new Error('Use a Roc name starting with a lowercase letter.');
  if (name===d.name) return [];
  if (!d.rename_safe || !sourceRange(result,d.name_region)) throw new Error('This binding cannot be renamed safely yet (generated name or record field reference).');
  if (result.evaluation.binders.includes(name)) throw new Error(`“${name}” is already bound in this document; renaming could capture a reference.`);
  const unique=new Map();
  for (const r of d.locations) {
    if (result.model.cells[r.cell].source.slice(r.from,r.to)!==d.name) throw new Error('The checked source has changed. Check again before renaming.');
    unique.set(`${r.cell}:${r.from}:${r.to}`,{...r,insert:name});
  }
  return [...unique.values()].sort((a,b)=>b.cell-a.cell || b.from-a.from);
}
export function completionOptions(result, prefix) {
  return symbols(result).filter(d=>/^[a-z][A-Za-z0-9_]*!?$/.test(d.name) && d.name.startsWith(prefix) && sourceRange(result,d.name_region))
    .map(d=>({label:d.name,detail:d.type})).sort((a,b)=>a.label.localeCompare(b.label));
}
