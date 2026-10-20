import katex from './vendor/katex/katex.mjs';

export const mathStylesheet = new URL('./vendor/katex/katex.css', import.meta.url);
const stylesheetReady = new WeakMap();
export function settleMathStyles(doc = document) { return stylesheetReady.get(doc) ?? Promise.resolve(); }
// Each equation gets fresh macros: definitions cannot change another cell.
export function renderMath(node, source, displayMode, doc = document) {
  node.className = `roclet-math${displayMode ? ' roclet-math-display' : ''}`;
  if (doc.defaultView && !doc.querySelector('link[data-roclet-math]')) {
    const link = doc.createElement('link');link.rel = 'stylesheet';link.href = mathStylesheet.href;
    link.dataset.rocletMath = '';
    stylesheetReady.set(doc, new Promise(resolve => {
      link.addEventListener('load', resolve, {once:true});
      link.addEventListener('error', resolve, {once:true});
    }));
    doc.head.append(link);
  }
  try {
    if (source.length > 8192) throw new Error('Equation exceeds the preview size limit.');
    // Only KaTeX-generated markup is inserted. Notebook HTML is never passed here.
    node.innerHTML = katex.renderToString(source, {
      displayMode, output: 'htmlAndMathml', throwOnError: true,
      trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 20, macros: {},
    });
  } catch {
    const delimiter = displayMode ? '$$' : '$';
    node.textContent = `${delimiter}${source}${delimiter}`;
    node.classList.add('roclet-math-fallback');
    node.title = 'Equation preview unavailable; showing the original math source.';
  }
}

export async function embedMathStyles(doc) {
  if (!doc.querySelector('.roclet-math')) return;
  const response = await fetch(mathStylesheet);
  if (!response.ok) throw new Error('Math fonts are unavailable. Reopen Roclet before exporting.');
  const style = doc.createElement('style');style.textContent = await response.text();doc.head.append(style);
}
