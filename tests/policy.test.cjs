const assert = require('node:assert/strict');
const { test } = require('node:test');
const Policy = require('../Policy.js');

function parse(settings = {}) {
  return Policy.parseConfig(JSON.stringify({ version: 1, plugins: [{ id: 'foamy.idle-suspend', ...settings }] }));
}

test('omitted options preserve the original battery-only laptop policy', () => {
  assert.deepEqual(parse(), { valid: true, settings: {
    batteryTimeoutSec: 900, acTimeoutSec: null, laptopsOnly: true, suspendAction: 'suspend-then-hibernate'
  }, error: '' });
});

test('independent power timeouts and supported sleep actions are configurable', () => {
  for (const suspendAction of ['suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate']) {
    const result = parse({ batteryTimeoutSec: null, acTimeoutSec: 1800, laptopsOnly: false, suspendAction });
    assert.equal(result.valid, true);
    assert.deepEqual(result.settings, { batteryTimeoutSec: null, acTimeoutSec: 1800, laptopsOnly: false, suspendAction });
  }
});

test('invalid overrides disable the policy instead of silently applying defaults', () => {
  for (const key of ['batteryTimeoutSec', 'acTimeoutSec']) {
    for (const value of [-1, 0, 0.5, '900', 'null', true, 2147484]) {
      const result = parse({ [key]: value });
      assert.equal(result.valid, false);
      assert.match(result.error, new RegExp(key));
    }
  }
  assert.equal(parse({ laptopsOnly: 'false' }).valid, false);
  assert.equal(parse({ suspendAction: 'poweroff' }).valid, false);
  assert.equal(parse({ suspendAction: 'suspend; touch /tmp/unwanted' }).valid, false);
});

test('malformed, missing, duplicate, and unsupported configuration is rejected', () => {
  for (const text of ['', '{', 'null', '{}', '{"version":2,"plugins":[]}',
    '{"version":1,"plugins":[]}',
    '{"version":1,"plugins":[{"id":"foamy.idle-suspend"},{"id":"foamy.idle-suspend"}]}']) {
    assert.equal(Policy.parseConfig(text).valid, false);
  }
});

test('Stay awake, unknown chassis, desktops and configuration errors block sleep', () => {
  const policy = Policy.defaults();
  assert.equal(Policy.allowed(policy, true, true, true, true), true);
  assert.equal(Policy.allowed(policy, false, true, true, true), false);
  assert.equal(Policy.allowed(policy, true, false, true, true), false);
  assert.equal(Policy.allowed(policy, true, true, false, true), false);
  assert.equal(Policy.allowed(policy, true, true, true, false), false);
  policy.laptopsOnly = false;
  assert.equal(Policy.allowed(policy, true, false, false, true), true);
  assert.equal(Policy.allowed(policy, true, true, false, false), false);
});


test('null explicitly disables either timeout while omission retains its default', () => {
  const disabled = parse({ batteryTimeoutSec: null, acTimeoutSec: null });
  assert.equal(disabled.valid, true);
  assert.equal(disabled.settings.batteryTimeoutSec, null);
  assert.equal(disabled.settings.acTimeoutSec, null);
  assert.equal(parse({ acTimeoutSec: 1200 }).settings.batteryTimeoutSec, 900);
  assert.equal(parse({ batteryTimeoutSec: 1200 }).settings.acTimeoutSec, null);
});
