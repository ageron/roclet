// Tiny browser assertion helpers; intentionally independent of Node and npm.
function fail(message) { throw new Error(message); }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
export function assert(value, message = 'Assertion failed') { if (!value) fail(message); }
// Cache counters depend on target width and prior requests. An empty resolver
// notification carries no semantic difference; preserve real missing packages.
export function compilerSemantics(result) {
  const {workspaceCache,transportMetrics,workerMs,packagesRequired,...value}=result;
  if(packagesRequired?.length)value.packagesRequired=packagesRequired;
  if(value.evaluation)value.evaluation=compilerSemantics(value.evaluation);
  return value;
}
assert.equal = (actual, expected) => assert(Object.is(actual, expected), `Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
assert.notEqual = (actual, expected) => assert(!Object.is(actual, expected), `Unexpected ${JSON.stringify(actual)}`);
assert.deepEqual = (actual, expected) => assert(JSON.stringify(canonical(actual)) === JSON.stringify(canonical(expected)), `Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
assert.match = (value, pattern) => assert(pattern.test(value), `Expected ${pattern} in ${value}`);
assert.doesNotMatch = (value, pattern) => assert(!pattern.test(value), `Unexpected ${pattern} in ${value}`);
function matches(error, expected) {
  if (!expected) return;
  if (expected instanceof RegExp) assert.match(error.message, expected);
  else for (const [key, value] of Object.entries(expected)) assert.equal(error[key], value);
}
assert.throws = (run, expected) => {
  try { run(); } catch (error) { matches(error, expected); return; }
  fail('Expected an exception');
};
assert.rejects = async (promise, expected) => {
  try { await promise; } catch (error) { matches(error, expected); return; }
  fail('Expected a rejected promise');
};
