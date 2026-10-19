import {assert} from '../tests/harness.mjs';
import {DocumentSession} from './document-session.mjs';
import {renderMarkdown} from './markdown-view.mjs';
import {renderDisplay} from './display-view.mjs';
import {exportReport} from './sharing.mjs';
const status=document.querySelector('#status'),log=document.querySelector('#log'),preview=document.querySelector('#preview');
let count=0,session;
const pass=name=>{log.textContent+=`PASS ${name}\n`;status.textContent=`${++count} checks passed…`;};
try {
  session=new DocumentSession(await fetch('../artifacts/roclet.wasm').then(r=>r.arrayBuffer()));
  const render=async source=>{const r=await session.request({operation:'markdown',source});assert.equal(r.status,'ok');return {events:r.events,view:renderMarkdown(r.events)};};
  const source=String.raw`Inline $E=mc^2$ and $\alpha_i + \frac{1}{2}$.

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

$$\begin{aligned}a &= b + c \\ d &= \sqrt{x}\end{aligned}$$`;
  const rendered=await render(source);preview.append(rendered.view);
  assert.equal(rendered.view.querySelectorAll('.katex').length,4);assert.equal(rendered.view.querySelectorAll('.katex-display').length,2);
  assert.equal(rendered.view.querySelectorAll('math').length,4);assert.match(rendered.view.querySelector('annotation').textContent,/E=mc\^2/);
  pass('inline and display math, fractions, Greek letters, aligned equations, and accessible MathML');
  for(const literal of [String.raw`Cost $5 and $10. Escaped \$x\$.`, '`$x$`', '```tex\n$$x$$\n```', '<span>$x$</span>']) {
    const {view}=await render(literal);
    if(!literal.startsWith('<span>')) assert.equal(view.querySelectorAll('.katex').length,0);
    assert.equal(view.querySelectorAll('script').length,0);
  }
  pass('currency, escaped delimiters, inline code and fenced code stay literal');
  const unfinished=await render('$x +');assert.equal(unfinished.view.textContent,'$x +');
  const broken=await render(String.raw`$\frac{1}{$`);assert.equal(broken.view.querySelectorAll('.roclet-math-fallback').length,1);assert.equal(broken.view.textContent,String.raw`$\frac{1}{$`);
  pass('unfinished or invalid equations keep readable source without a diagnostic banner');
  const malicious=await render(String.raw`$\href{javascript:alert(1)}{x}$ $\includegraphics{https://example.invalid/a.png}$ $\htmlStyle{color:red}{x}$`);
  assert.equal(malicious.view.querySelectorAll('a,img,[style*="color:red"]').length,0);
  const html=await render(String.raw`$\text{<img src=x onerror=alert(1)>}$`);assert.equal(html.view.querySelectorAll('img,script,[onerror]').length,0);
  const recursive=await render(String.raw`$\def\a{\a}\a$`);assert(recursive.view.querySelector('.roclet-math-fallback'));
  const macros=await render(String.raw`$\gdef\myroclet{7}\myroclet$ $\myroclet$`);assert.equal(macros.view.querySelectorAll('.roclet-math-fallback').length,1);
  pass('unsafe commands stay inert; macro expansion is bounded and definitions are isolated');
  const richSource='import Display\n# %%\nDisplay.markdown("The area is $A = 15$.")';
  const rich=await session.request({operation:'document',action:'evaluate',format:'roc',source:richSource});assert.equal(rich.status,'ok');
  const value=rich.evaluation.values[0],richView=renderDisplay(value.display,value.text);assert(richView.querySelector('.katex'));preview.append(richView);
  pass('computed Display.markdown outputs use the same math renderer');
  const notebook='# %%\n'+source.split('\n').map(line=>'# '+line).join('\n');
  const exported=await session.request({operation:'document',action:'export',format:'roc',source:notebook,render:true});assert.equal(exported.status,'ok');
  const md=await session.request({operation:'document',action:'convert',format:'roc',target:'markdown',source:notebook});assert.equal(md.status,'ok');
  const back=await session.request({operation:'document',action:'convert',format:'markdown',target:'roc',source:md.source});assert.equal(back.status,'ok');assert.equal(back.model.cells[0].source,exported.model.cells[0].source);
  pass('math source survives Roc/Markdown conversion');
  const capture={document:{title:'Math report'},source:notebook,createdAt:'test',compiler:{commit:'test'},model:exported.model,rendering:exported.rendering,snapshots:[],events:[]};
  const report=await (await exportReport(capture)).text(),doc=new DOMParser().parseFromString(report,'text/html');
  assert.equal(doc.querySelectorAll('.katex').length,4);assert.equal(doc.querySelectorAll('script,link').length,0);assert.match(report,/data:font\/woff2;base64,/);assert.match(doc.querySelector('meta[http-equiv]').content,/font-src data:/);
  // Load the exported document with its actual CSP, with no external styles or scripts.
  const frame=document.createElement('iframe');frame.title='Self-contained math report';frame.style.cssText='width:100%;height:350px';
  const loaded=new Promise(resolve=>frame.onload=resolve);frame.srcdoc=report;document.body.append(frame);await loaded;await frame.contentDocument.fonts.ready;
  assert(frame.contentDocument.fonts.check('16px KaTeX_Main'));assert(frame.contentDocument.querySelector('.katex').getBoundingClientRect().width>0);
  pass('static HTML report embeds styles and fonts and renders with its restrictive CSP');
  await document.fonts.ready;await document.fonts.load('16px KaTeX_Main');assert(document.fonts.check('16px KaTeX_Main'));
  status.textContent=`PASS — ${count} math contracts`;document.documentElement.dataset.result='pass';
} catch(error) {status.textContent='FAIL';log.textContent+=error.stack??error.message;document.documentElement.dataset.result='fail';}
finally {session?.stop();}
