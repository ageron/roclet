// Panel layout for the notebook editor. Everything here is plain logic over
// the DOM it is given (or plain data), so Node tests can import it.

// Every panel element carries data-part. The primary panel keeps the legacy
// ids (prefix ''), which existing contracts and probes rely on; a second panel
// gets the same names behind its own prefix. Panel code never uses the ids.
export const partId = (prefix, name) => `${prefix}${name}`;
export function assignPanelIds(root, prefix) {
  for (const node of root.querySelectorAll('[data-part]')) node.id = partId(prefix, node.dataset.part);
  for (const node of root.querySelectorAll('[data-for]')) node.htmlFor = partId(prefix, node.dataset.for);
  return root;
}
export function clonePanel(template, prefix) {
  const root = template.content.firstElementChild.cloneNode(true);
  return assignPanelIds(root, prefix);
}
