const assert = require('node:assert/strict');
const { test } = require('node:test');
const Policy = require('../Policy.js');

function parse(settings = {}) {
  return Policy.parseConfig(JSON.stringify({ version: 1, plugins: [{ id: 'foamy.idle-suspend', ...settings }] }));
}

test('omitted options give a battery-only laptop policy that works without hibernation', () => {
  assert.deepEqual(parse(), { valid: true, settings: {
    batteryTimeoutSec: 900, acTimeoutSec: null, laptopsOnly: true, suspendAction: 'auto',
    pauseForMedia: true, lockBeforeSuspend: true
  }, error: '' });
});

test('independent power timeouts and supported sleep actions are configurable', () => {
  for (const suspendAction of ['auto', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate']) {
    const result = parse({ batteryTimeoutSec: null, acTimeoutSec: 1800, laptopsOnly: false, suspendAction });
    assert.equal(result.valid, true);
    assert.deepEqual(result.settings, { batteryTimeoutSec: null, acTimeoutSec: 1800, laptopsOnly: false, suspendAction,
      pauseForMedia: true, lockBeforeSuspend: true });
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
  assert.equal(parse({ pauseForMedia: 'no' }).valid, false);
  assert.equal(parse({ lockBeforeSuspend: 0 }).valid, false);
  assert.equal(parse({ suspendAction: 'poweroff' }).valid, false);
  assert.equal(parse({ suspendAction: 'Auto' }).valid, false);
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

test('unavailable actions fall back to suspend; unknown answers are trusted', () => {
  assert.deepEqual(Policy.chooseAction('suspend', {}), { action: 'suspend', fallback: false });
  assert.deepEqual(Policy.chooseAction('suspend-then-hibernate', { 'suspend-then-hibernate': 'na', suspend: 'yes' }),
    { action: 'suspend', fallback: true });
  assert.deepEqual(Policy.chooseAction('hibernate', { hibernate: 'challenge' }), { action: 'hibernate', fallback: false });
  assert.deepEqual(Policy.chooseAction('hibernate', { hibernate: 'no', suspend: 'na' }), { action: '', fallback: false });
  assert.deepEqual(Policy.chooseAction('suspend', { suspend: 'na' }), { action: '', fallback: false });
  for (const action of Policy.ACTIONS) assert.match(Policy.CAN_METHODS[action], /^Can[A-Za-z]+$/);
});

test('logind idle or sleep block inhibitors defer sleep; delay-only lists do not', () => {
  assert.equal(Policy.blockedByInhibitor('idle'), true);
  assert.equal(Policy.blockedByInhibitor('handle-lid-switch:sleep'), true);
  assert.equal(Policy.blockedByInhibitor(''), false);
  assert.equal(Policy.blockedByInhibitor('shutdown:handle-power-key'), false);
  assert.equal(Policy.blockedByInhibitor('sleeping'), false);
});

test('media-is-playing semantics match the contract shared with foamy-lock', () => {
  const vectors = require('./media-playing.json');
  for (const { players, playing } of vectors.cases)
    assert.equal(Policy.mediaPlaying(players), playing, JSON.stringify(players));
  assert.equal(Policy.mediaPlaying(undefined), false);
});

test('retries back off from one minute to at most fifteen', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 9].map(n => Policy.retryDelayMs(n)), [60000, 120000, 240000, 480000, 900000, 900000]);
  assert.equal(Policy.retryDelayMs(1, 700), 1400);
});

test('only effective changes count as a new configuration', () => {
  const a = parse(), b = parse();
  assert.equal(Policy.sameConfiguration(a, b), true);
  assert.equal(Policy.sameConfiguration(a, parse({ batteryTimeoutSec: 600 })), false);
  assert.equal(Policy.sameConfiguration(a, Policy.parseConfig('{')), false);
  assert.equal(Policy.sameConfiguration(null, a), false);
});

test('notifications stay quiet where the plugin never sleeps', () => {
  const policy = Policy.defaults();
  assert.equal(Policy.active(policy, true, true, true), true);
  assert.equal(Policy.active(policy, true, true, false), false);
  assert.equal(Policy.active({ ...policy, batteryTimeoutSec: null }, true, true, true), false);
  assert.equal(Policy.active(policy, false, true, true), false);
});

test('every notification string has an English and Norwegian catalog entry', () => {
  const fs = require('node:fs'), path = require('node:path');
  const service = fs.readFileSync(path.join(__dirname, '../Service.qml'), 'utf8');
  const en = require('../i18n/en.json'), no = require('../i18n/no.json');
  const keys = [...service.matchAll(/FoamyI18n\.t\("((?:[^"\\]|\\.)*)"/g)].map(m => JSON.parse('"' + m[1] + '"'));
  assert.ok(keys.length >= 10);
  const tokens = s => [...s.matchAll(/%[1-9]/g)].map(m => m[0]).sort();
  for (const key of keys) {
    assert.equal(en[key], key, key);
    assert.ok(no[key], key);
    assert.deepEqual(tokens(no[key]), tokens(key), key);
  }
  assert.ok(!/\bIpcHandler\s*\{/.test(service), 'IPC goes through FoamyIpc');
});

test('auto uses suspend-then-hibernate only where logind says yes, else suspend', () => {
  const yes = { suspend: 'yes', 'suspend-then-hibernate': 'yes' };
  assert.deepEqual(Policy.chooseAction('auto', yes), { action: 'suspend-then-hibernate', fallback: false });
  for (const answer of ['na', 'no', 'challenge', '', undefined])
    assert.deepEqual(Policy.chooseAction('auto', { suspend: 'yes', 'suspend-then-hibernate': answer }),
      { action: 'suspend', fallback: false }, String(answer));
  assert.deepEqual(Policy.chooseAction('auto', {}), { action: 'suspend', fallback: false });
  assert.deepEqual(Policy.chooseAction('auto', { suspend: 'na', 'suspend-then-hibernate': 'na' }), { action: '', fallback: false });
  // Explicit values are unchanged by the new default.
  assert.deepEqual(Policy.chooseAction('suspend', yes), { action: 'suspend', fallback: false });
  assert.deepEqual(Policy.chooseAction('suspend-then-hibernate', yes), { action: 'suspend-then-hibernate', fallback: false });
  assert.deepEqual(Policy.chooseAction('hibernate', { hibernate: 'na', suspend: 'yes' }), { action: 'suspend', fallback: true });
  assert.deepEqual(Policy.CHOICES, ['auto', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate']);
});
