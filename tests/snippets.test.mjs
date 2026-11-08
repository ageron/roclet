import {test} from 'node:test';
import assert from 'node:assert/strict';
import {snippets,prepareSnippet} from '../web/snippets.mjs';
import {normalizeDisplay} from '../web/display-view.mjs';
const urls={roclet:'https://github.com/ageron/roclet-display/releases/download/0.4.0/pinned.tar.zst',plume:'https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/pinned.tar.zst',random:'https://github.com/kili-ilo/roc-random/releases/download/0.9.3/pinned.tar.zst'};
const snippet=id=>snippets.find(s=>s.id===id);
const state=(preamble='app [main!] {}',source='')=>({preamble,cells:[{kind:'code',source}],inputValues:{}});
test('every rich preview satisfies the output renderer contract',()=>{
  for(const snippet of snippets)if(typeof snippet.preview!=='string')assert(normalizeDisplay(snippet.preview),snippet.id);
});
test('successive package insertions keep the closing brace on its own line',()=>{
  const draft=state();
  for(const id of ['slider','random-integer','line']) {
    const recipe=prepareSnippet(draft,snippet(id),urls);
    draft.preamble=recipe.preamble;draft.cells.push({kind:'code',source:recipe.source});
  }
  assert.equal(draft.preamble,`app [main!] {\n    plume: "${urls.plume}",\n    random: "${urls.random}",\n    roclet: "${urls.roclet}",\n}\nimport roclet.Display\nimport roclet.Input\nimport random.Random\nimport plume.Chart\nimport plume.Scatter\nimport plume.Coordinate\n`);
});
test('adding a package separates inline closing braces and preserves comments',()=>{
  for(const body of [` roclet: "${urls.roclet}",`, `\n    # Keep this package\n    roclet: "${urls.roclet}",`]) {
    const recipe=prepareSnippet(state(`app [main!] {${body}}\nimport roclet.Display\n`),snippet('random-integer'),urls);
    assert.match(recipe.preamble,/roclet: "[^"\n]+",\n}\nimport roclet.Display/);
    if(body.includes('#'))assert.match(recipe.preamble,/    # Keep this package\n    roclet:/);
  }
});
test('insertion preserves comments and URLs containing braces and reuses package aliases',()=>{
  const preamble='# app [main!] { fake: "no" }\napp [main!] {\n  pictures: "https://github.com/ageron/roclet-display/releases/download/0.4.0/{hash}.tar.zst",\n}\n';
  const recipe=prepareSnippet(state(preamble),snippet('table'),urls);
  assert.equal(recipe.preamble,preamble.trimEnd()+'\nimport pictures.Display\n');
  assert.deepEqual(recipe.added,[]);
});
test('existing imports and module aliases are reused without duplicates',()=>{
  const preamble=`app [main!] { show: "${urls.roclet}" }\nimport show.Display as Output\n`;
  const recipe=prepareSnippet(state(preamble),snippet('table'),urls);
  assert.equal(recipe.preamble,preamble);
  assert.match(recipe.source,/Output.table/);
  const builtin=prepareSnippet(state('import Display # already available'),snippet('table'),urls);
  assert.match(builtin.source,/Display.table/);
  assert.match(builtin.preamble,/^app \[main!\] \{\}/);
  assert.deepEqual(builtin.added,[]);
});
test('repeated insertion avoids variable names, widget keys and package aliases',()=>{
  const draft=state('app [main!] {}','roclet = 3\nslider = 4\nout_slider = 5');draft.inputValues.slider_key=9;
  const recipe=prepareSnippet(draft,snippet('slider'),urls);
  assert.match(recipe.preamble,/roclet_2:/);
  assert.match(recipe.source,/slider_2 = Input.slider/);
  assert.match(recipe.source,/key: "slider_key_2"/);
  assert.match(recipe.source,/out_slider_2 = slider_2.display/);
  const again=prepareSnippet({preamble:recipe.preamble,cells:[...draft.cells,{kind:'code',source:recipe.source}]},snippet('slider'),urls);
  assert.match(again.source,/slider_3 =/);
  assert.equal(again.preamble,recipe.preamble);
});
test('prose and comments do not shadow module names',()=>{
  const draft=state('app [main!] {}\n# Display is useful');draft.cells.push({kind:'markdown',source:'Use Display for tables'});
  assert.match(prepareSnippet(draft,snippet('table'),urls).source,/Display.table/);
});
test('a conflicting module or malformed header fails without changing the draft',()=>{
  const draft=state('app [main!] {}\nimport other.Display');const before=structuredClone(draft);
  assert.throws(()=>prepareSnippet(draft,snippet('table'),urls),/already used/);
  assert.deepEqual(draft,before);
  assert.throws(()=>prepareSnippet(state('app [main!] {'),snippet('table'),urls),/valid app header/);
});
