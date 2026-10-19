// Tiny browser test harness; intentionally independent of Node and npm.
const tests = [];
export function test(name, run) { tests.push({ name, run }); }
function fail(message) { throw new Error(message); }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
export function assert(value, message = 'Assertion failed') { if (!value) fail(message); }
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
export async function runTests(report) {
  for (const { name, run } of tests) {
    await run();
    report(`PASS ${name}`);
  }
  return tests.length;
}
