import {renderMath} from './math-view.mjs';
// A fixed DOM renderer for the vendored MD4C parser's typed events.
// Raw HTML is text, and images are explicit links (no automatic network loads).
export function decodeEntities(text, doc = document) {
  return text.replace(/&(?:#[0-9]{1,8}|#x[0-9a-f]{1,8}|[a-z][a-z0-9]{1,47});/gi, entity => {
    const decoder = doc.createElement('textarea');
    decoder.innerHTML = entity; // The validated entity contains no markup delimiters.
    return decoder.value;
  });
}
export function safeLink(text, doc = document) {
  const decoded = decodeEntities(text, doc);
  try {
    const url = new URL(decoded, doc.baseURI);
    return ['http:', 'https:', 'mailto:'].includes(url.protocol) ? url.href : null;
  } catch { return null; }
}
export function renderMarkdown(events, doc = document) {
  const root = doc.createElement('div'); root.className = 'markdown';
  const stack = [root];
  const parent = () => stack[stack.length - 1];
  const blockTags = ['div', 'blockquote', 'ul', 'ol', 'li', 'hr', 'h2', 'pre', 'pre', 'p', 'table', 'thead', 'tbody', 'tr', 'th', 'td'];
  const spanTags = ['em', 'strong', 'a', 'a', 'code', 'del'];
  for (const event of events) {
    if (event.event === 'block_start' || event.event === 'span_start') {
      const block = event.event === 'block_start';
      let tag = (block ? blockTags : spanTags)[event.kind] ?? 'span';
      if (block && event.kind === 6) tag = `h${Math.max(1, Math.min(6, event.detail))}`;
      const node = doc.createElement(tag);
      if (block && event.kind === 3 && event.detail) node.start = event.detail;
      if (!block && [2, 3].includes(event.kind)) {
        const href = safeLink(event.text, doc);
        if (href) { node.href = href; node.rel = 'noopener noreferrer'; node.target = '_blank'; }
        if (event.kind === 3) { node.className = 'image-link'; node.append('Image: '); }
      }
      if (!block && [6, 7].includes(event.kind)) node.dataset.mathMode = event.kind === 7 ? 'display' : 'inline';
      parent().append(node); stack.push(node);
    } else if (event.event === 'block_end' || event.event === 'span_end') {
      if (stack.length > 1) {
        const node = stack.pop();
        if (node.dataset.mathMode) {
          renderMath(node, node.textContent, node.dataset.mathMode === 'display', doc);
          delete node.dataset.mathMode;
        }
      }
    } else if (event.event === 'text') {
      if (event.kind === 2) parent().append(doc.createElement('br'));
      else parent().append(event.kind === 4 ? decodeEntities(event.text, doc) : event.kind === 1 ? '\uFFFD' : event.kind === 3 ? '\n' : event.text);
    }
  }
  return root;
}
