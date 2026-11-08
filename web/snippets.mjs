// Curated, runnable starting points. {{names}} are resolved at insertion time.
export const categories = {all:'All',widgets:'Widgets',charts:'Charts',outputs:'Rich outputs',code:'Code snippets'};
export const dependencies = {
  roclet:{label:'Display',alias:'roclet',repository:'ageron/roclet-display',pin:'../dependencies/roclet-display-url.txt'},
  plume:{label:'Plume',alias:'plume',repository:'lukewilliamboswell/plume',version:'0.5.0'},
  random:{label:'Random',alias:'random',repository:'kili-ilo/roc-random',version:'0.9.3'},
};
const rich=(kind,content,text='Example output',extra={})=>({version:1,kind,content,text,...extra});
const numberHTML='<label>Value <input id="number" type="number" min="0" max="100" value="5"></label><script>const input=document.getElementById("number");input.oninput=()=>roclet.setValue(Number(input.value));roclet.onValue(value=>{input.value=value;});</script>';
const widgetHTML='<button onclick="this.textContent = \'Clicked!\'">Click me</button>';
const svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 100"><rect x="10" y="10" width="220" height="80" rx="12" fill="#8050be"/></svg>';
const image='iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOwrw2hKWIYtWDUglELRi0YtWDUglELRi0YtWDUglELhooFADqrQD2nQXpjAAAAAElFTkSuQmCC';
const event=(event,kind,text='',detail=0)=>({event,kind,text,detail});
const markdownPreview=rich('markdown','## Area\nThe area is **15** square metres.','Area: 15 square metres',{events:[
  event('block_start',0),event('block_start',6,'',2),event('text',0,'Area'),event('block_end',6),
  event('block_start',9),event('text',0,'The area is '),event('span_start',1),event('text',0,'15'),event('span_end',1),event('text',0,' square metres.'),event('block_end',9),event('block_end',0),
]});
const entry=(id,category,title,description,modules,source,preview,edit)=>({id,category,title,description,modules,source,preview,edit});
export const snippets = [
  entry('slider','widgets','Slider','Adjust a value and use it in other cells.',{roclet:['Display','Input']},String.raw`{{slider}} = {{Input}}.slider({
    key: "{{slider_key}}", label: "Value", min: 0, max: 100, step: 1, default: 5,
})
{{slider_value}} = {{slider}}.value
{{out_slider}} = {{slider}}.display`,rich('slider',JSON.stringify({key:'preview',label:'Value',min:'0',max:'100',step:'1',default:'5',value:'5'}),'Value: 5'),'5'),
  entry('number','widgets','Numeric input','Enter a number to use in other cells.',{roclet:['Display','Input']},`{{number_input}} = {{Input}}.custom({
    key: "{{number_key}}", label: "Value", min: 0, max: 100, default: 5,
    html: ${JSON.stringify(numberHTML)},
})
{{number_value}} = {{number_input}}.value
{{out_number}} = {{number_input}}.display`,rich('input',JSON.stringify({key:'preview',label:'Value',min:'0',max:'100',default:'5',value:'5',html:numberHTML}),'Value: 5'),'5'),
  entry('widget','widgets','Custom widget','Start with a button and customize its HTML and JavaScript.',{roclet:['Display']},`{{out_widget}} = {{Display}}.widget("Button example", ${JSON.stringify(widgetHTML)})`,rich('widget',widgetHTML,'Button example'),'Click me'),
  entry('table','outputs','Table','Display rows with column headings.',{roclet:['Display']},String.raw`{{out_table}} = {{Display}}.table(["Item", "Quantity"], [
    ["Apples", "3"],
    ["Pears", "5"],
])`,rich('table','','2 rows × 2 columns',{columns:['Item','Quantity'],rows:[['Apples','3'],['Pears','5']],row_count:2,column_count:2}),'Apples'),
  entry('markdown','outputs','Computed Markdown','Build formatted text and equations from Roc values.',{roclet:['Display']},'{{area}} = 15\n{{out_markdown}} = {{Display}}.markdown("## Area\\nThe area is **${{{area}}.to_str()}** square metres.")',markdownPreview,'15'),
  entry('text','outputs','Text','Show a string without quotes.',{roclet:['Display']},'{{out_text}} = {{Display}}.text("Hello, Roclet!")',rich('text','','Hello, Roclet!'),'Hello, Roclet!'),
  entry('image','outputs','Image','Display a PNG, JPEG or WebP image from base64 data.',{roclet:['Display']},`{{out_image}} = {{Display}}.image("Green square", "image/png", "${image}")`,rich('image',image,'Green square',{mime:'image/png'}),'Green square'),
  entry('svg','outputs','SVG','Draw a scalable image using SVG markup.',{roclet:['Display']},`{{out_svg}} = {{Display}}.svg("Purple rectangle", ${JSON.stringify(svg)})`,rich('svg',svg,'Purple rectangle'),'220'),
  entry('html','outputs','HTML','Create a formatted output with HTML and CSS.',{roclet:['Display']},String.raw`{{out_html}} = {{Display}}.html("A note", "<article style=\"border-left:4px solid #8050be;padding:16px\"><h2>Hello!</h2><p>Edit this note.</p></article>")`,rich('html','<article style="border-left:4px solid #8050be;padding:16px"><h2>Hello!</h2><p>Edit this note.</p></article>','A note'),'Hello!'),
  entry('random-integer','code','Random integer','Generate a repeatable integer. Change the seed for another result.',{random:['Random']},String.raw`{{seed}} = 42.U32
{{out_random}} = {{Random}}.bounded_i32(1, 100)({{Random}}.seed({{seed}})).value`,'An integer between 1 and 100','42'),
  entry('random-list','code','Random list','Generate ten repeatable random integers.',{random:['Random']},String.raw`{{seed}} = 42.U32
{{out_random}} = {{Random}}.list({{Random}}.bounded_i32(1, 100), 10)({{Random}}.seed({{seed}})).value`,'A list of 10 integers between 1 and 100','42'),
  entry('sequence','code','Number sequence','Create a list of consecutive numbers.',{},'{{out_sequence}} = List.from_iter((0.U64..<10).iter())','[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]','10'),
];
for(const [id,title,mode] of [['line','Line chart','Lines'],['scatter','Scatter plot','Markers'],['bar','Bar chart',''],['pie','Pie chart','']]) {
  const type=id==='bar'?'Bar':id==='pie'?'Pie':'Scatter';
  const data=id==='pie'?'[{ label: "Apples", value: 3 }, { label: "Pears", value: 5 }]':id==='bar'?'[{ x: {{Coordinate}}.from_text("Apples"), y: {{Coordinate}}.from_number(3)? }, { x: {{Coordinate}}.from_text("Pears"), y: {{Coordinate}}.from_number(5)? }]':'[{ x: {{Coordinate}}.from_number(1)?, y: {{Coordinate}}.from_number(3)? }, { x: {{Coordinate}}.from_number(2)?, y: {{Coordinate}}.from_number(5)? }, { x: {{Coordinate}}.from_number(3)?, y: {{Coordinate}}.from_number(4)? }]';
  const trace={type:id==='line'?'scatter':id,...(id==='pie'?{labels:['Apples','Pears'],values:[3,5]}:{x:id==='bar'?['Apples','Pears']:[1,2,3],y:id==='bar'?[3,5]:[3,5,4],...(mode?{mode:mode.toLowerCase()}: {})})};
  snippets.push(entry(id,'charts',title,'Create an interactive chart with Plume.',{roclet:['Display'],plume:['Chart',type,...(id==='pie'?[]:['Coordinate'])]},`{{make_chart}} = || {
    {{series}} = {{${type}}}.new({ data: ${data}${mode?`, mode: ${mode}`:''} })${type==='Scatter'?'':'?'}
    {{chart}} = {{Chart}}.new({ traces: [${type}({{series}})] })
    Ok({{Display}}.plotly("${title}", {{chart}}.to_json()))
}
{{out_chart}} = {{make_chart}}() ?? {{Display}}.text("Check the chart data.")`,rich('plotly',JSON.stringify({data:[trace],layout:{margin:{t:25,b:35,l:35,r:15},height:220}}),title),id==='pie'?'Apples':'3'));
}

// A small lexical scan keeps edits out of comments and quoted URLs/strings.
function tokens(source) {
  return [...source.matchAll(/#[^\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z0-9_!]*|[^\s]/g)].filter(m=>!m[0].startsWith('#')).map(m=>({text:m[0],at:m.index,end:m.index+m[0].length}));
}
export function prepareSnippet(state,snippet,urls) {
  const original=state.preamble || 'app [main!] {}';
  let preamble=tokens(original).some(t=>t.text==='app')?original:`app [main!] {}\n${original}`;
  const code=[original,...state.cells.filter(c=>c.kind!=='markdown').map(c=>c.source)].join('\n');
  const lexed=tokens(code), used=new Set(lexed.map(t=>t.text).filter(t=>/^[A-Za-z_][A-Za-z0-9_]*$/.test(t))), names=new Map(), added=[];
  for(const t of lexed)if(t.text.startsWith('"'))used.add(t.text.slice(1,-1));
  for(const key of Object.keys(state.inputValues??{}))used.add(key);
  const unique=base=>{let name=base,n=2;while(used.has(name))name=`${base}_${n++}`;used.add(name);return name;};
  for(const [dep,modules] of Object.entries(snippet.modules)) {
    const config=dependencies[dep], ts=tokens(preamble), app=ts.findIndex(t=>t.text==='app'), open=ts.findIndex((t,i)=>i>app && t.text==='{');
    if(app<0 || open<0) throw Error('Add a valid app header before inserting this snippet.');
    let depth=1,close=open+1;for(;close<ts.length;close++){if(ts[close].text==='{')depth++;if(ts[close].text==='}' && --depth===0)break;}
    if(close===ts.length)throw Error('Add a valid app header before inserting this snippet.');
    // Only package entries are expected inside the app's package record.
    const entries=[];
    for(let i=open+1;i<close-2;i++)if(ts[i+1].text===':' && ts[i+2].text.startsWith('"'))entries.push({alias:ts[i].text,url:ts[i+2].text.slice(1,-1)});
    let alias=entries.find(e=>e.url.includes(`github.com/${config.repository}/`))?.alias;
    // The built-in Display/Input imports need no extra package declaration.
    const imports=modules.map(module=>({module,existing:new RegExp(`^[ \\t]*import[ \\t]+(?:([a-z][\\w]*)\\.)?${module}(?:[ \\t]+as[ \\t]+([A-Z][\\w]*))?[ \\t]*(?:#[^\\n]*)?$`,'m').exec(preamble)}));
    if(!alias && imports.some(i=>!i.existing)) {
      alias=unique(config.alias);
      if(!urls[dep])throw Error(`${config.label} is unavailable in this distribution.`);
      const body=preamble.slice(ts[open].end,ts[close].at);
      const existing=!body.trim()?'':/^[ \t]*\n/.test(body)?body.replace(/^[ \t]*\n/,'').trimEnd():`    ${body.trim()}`;
      preamble=preamble.slice(0,ts[open].end)+`\n    ${alias}: "${urls[dep]}",\n`+(existing?`${existing}\n`:'')+preamble.slice(ts[close].at);
      added.push(config.label);
    }
    for(const {module,existing} of imports) {
      if(existing && (!existing[1] || existing[1]===alias))names.set(module,existing[2]||module);
      else {
        if(used.has(module))throw Error(`The name ${module} is already used. Rename it before inserting this snippet.`);
        names.set(module,module);used.add(module);
        preamble=preamble.trimEnd()+`\nimport ${alias}.${module}\n`;
      }
    }
  }
  const source=snippet.source.replace(/\{\{(\w+)\}\}/g,(_,base)=>{
    if(!names.has(base))names.set(base,unique(base));return names.get(base);
  });
  const from=source.indexOf(snippet.edit);
  return {preamble,source,added,selection:from<0?null:{anchor:from,head:from+snippet.edit.length}};
}
