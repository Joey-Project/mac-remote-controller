import assert from 'node:assert/strict';
import test from 'node:test';
import { WebPreferenceStore, PREFERENCES_KEY, SEEK_INTERVALS } from '../dist/preferences.js';

const defaults = () => ({
  seekSeconds: 10,
  threeFingerDrag: true,
  forceClick: true,
  haptics: false,
  panels: { volume: false, media: false, desktop: false },
});

function fixture(raw = null) {
  const values = new Map(raw === null ? [] : [[PREFERENCES_KEY, raw]]);
  const writes = [];
  const storage = {
    getItem(key) {
      return values.get(key) ?? null;
    },
    setItem(key, value) {
      writes.push({ key, value });
      values.set(key, value);
    },
  };
  return { values, writes, storage, load: () => new WebPreferenceStore(() => storage) };
}

test('missing preferences use native defaults without writing during initialization', () => {
  const f = fixture();
  assert.deepEqual(f.load().values, defaults());
  assert.equal(f.writes.length, 0);
  assert.deepEqual(SEEK_INTERVALS, [5, 10, 15, 30]);
});

test('every native skip interval and disabled drag survive a fresh store', () => {
  for (const seconds of SEEK_INTERVALS) {
    const f = fixture();
    const store = f.load();
    assert(store.setSeekSeconds(seconds));
    assert(store.setThreeFingerDrag(false));
    assert.deepEqual(f.load().values, {
      ...defaults(),
      seekSeconds: seconds,
      threeFingerDrag: false,
    });
  }
});

test('invalid changes cannot save unsupported intervals or coerce drag values', () => {
  const f = fixture();
  const store = f.load();
  for (const value of [0, -10, 5.5, 20, NaN, Infinity, '10', null, {}, true])
    assert.equal(store.setSeekSeconds(value), false);
  for (const value of [0, 1, 'false', null, undefined, {}])
    assert.equal(store.setThreeFingerDrag(value), false);
  assert.deepEqual(store.values, defaults());
  assert.deepEqual(f.writes, []);
});

test('saved fields fall back independently and malformed shapes never escape initialization', () => {
  for (const raw of ['null', 'false', '[]', '"10"', '{}', '{broken', ' '.repeat(2049)])
    assert.deepEqual(fixture(raw).load().values, defaults());
  assert.deepEqual(fixture('{"seekSeconds":20,"threeFingerDrag":false}').load().values, {
    ...defaults(),
    seekSeconds: 10,
    threeFingerDrag: false,
  });
  assert.deepEqual(fixture('{"seekSeconds":15,"threeFingerDrag":"false"}').load().values, {
    ...defaults(),
    seekSeconds: 15,
    threeFingerDrag: true,
  });
});

test('unavailable storage keeps changes usable in memory and reports their lifetime', () => {
  const store = new WebPreferenceStore(() => {
    throw new Error('Storage unavailable');
  });
  assert(store.persistenceWarning);
  store.setSeekSeconds(30);
  store.setThreeFingerDrag(false);
  assert.deepEqual(store.values, { ...defaults(), seekSeconds: 30, threeFingerDrag: false });
  assert.match(store.persistenceWarning, /this tab/);
});

test('failed writes keep changes in memory and later successful user changes recover persistence', () => {
  const f = fixture();
  let blocked = true;
  const store = new WebPreferenceStore(() => ({
    getItem: f.storage.getItem,
    setItem(key, value) {
      if (blocked) throw new Error('Quota');
      f.storage.setItem(key, value);
    },
  }));
  store.setThreeFingerDrag(false);
  assert.equal(store.values.threeFingerDrag, false);
  assert(store.persistenceWarning);
  blocked = false;
  store.setSeekSeconds(5);
  assert.equal(store.persistenceWarning, null);
  assert.deepEqual(f.load().values, { ...defaults(), seekSeconds: 5, threeFingerDrag: false });
});

test('preferences only write their own key and non-secret preference fields', () => {
  const f = fixture();
  f.values.set('unrelated-setting', 'keep-existing-data');
  const store = f.load();
  store.setSeekSeconds(15);
  assert.equal(f.values.get('unrelated-setting'), 'keep-existing-data');
  assert.deepEqual(
    f.writes.map((w) => w.key),
    [PREFERENCES_KEY],
  );
  assert.deepEqual(JSON.parse(f.writes[0].value), { ...defaults(), seekSeconds: 15 });
  const snapshot = store.values;
  snapshot.seekSeconds = 999;
  assert.equal(store.values.seekSeconds, 15);
  snapshot.panels.volume = true;
  assert.equal(store.values.panels.volume, false);
});

test('all eight panel combinations survive settings changes and fresh stores', () => {
  for (let bits = 0; bits < 8; bits++) {
    const f = fixture();
    const store = f.load();
    const panels = { volume: !!(bits & 1), media: !!(bits & 2), desktop: !!(bits & 4) };
    for (const [name, value] of Object.entries(panels))
      assert(store.setPanelVisibility(name, value));
    store.setSeekSeconds(30);
    store.setThreeFingerDrag(false);
    store.setForceClick(false);
    store.setHaptics(true);
    assert.deepEqual(f.load().values, {
      seekSeconds: 30,
      threeFingerDrag: false,
      forceClick: false,
      haptics: true,
      panels,
    });
    store.hidePanels();
    assert.deepEqual(f.load().values, {
      ...defaults(),
      seekSeconds: 30,
      threeFingerDrag: false,
      forceClick: false,
      haptics: true,
    });
  }
});

test('old preferences migrate without rewriting and malformed new fields fall back independently', () => {
  const f = fixture('{"seekSeconds":15,"threeFingerDrag":false}');
  assert.deepEqual(f.load().values, { ...defaults(), seekSeconds: 15, threeFingerDrag: false });
  assert.equal(f.writes.length, 0);
  assert.deepEqual(
    fixture('{"forceClick":false,"haptics":"true","panels":{"volume":true,"media":"false"}}').load()
      .values,
    { ...defaults(), forceClick: false, panels: { volume: true, media: false, desktop: false } },
  );
});

test('new preference setters reject malformed values without writing or clobbering other fields', () => {
  const f = fixture();
  const store = f.load();
  for (const value of ['true', 1, null, {}, undefined]) {
    assert.equal(store.setHaptics(value), false);
    assert.equal(store.setForceClick(value), false);
    assert.equal(store.setPanelVisibility('volume', value), false);
  }
  for (const panel of ['unknown', '__proto__', 'constructor', null, {}])
    assert.equal(store.setPanelVisibility(panel, true), false);
  assert.deepEqual(store.values, defaults());
  assert.deepEqual(f.writes, []);
});
