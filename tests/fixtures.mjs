export const fixtureNames = ['forward', 'dependencies', 'anonymous', 'recursion', 'types', 'imports', 'debug'];
export function permutations(items) {
  return items.length < 2 ? [items] : items.flatMap((item, index) => permutations(items.filter((_, i) => i !== index)).map(rest => [item, ...rest]));
}
export function snapshot(fixture, overrides = {}) {
  return { requestId: 'test-1', documentRevision: 1, inputRevision: 0, workerGeneration: 1, cells: fixture.cells, roots: fixture.roots, modules: fixture.modules ?? [], ...overrides };
}
