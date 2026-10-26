import assert from 'node:assert/strict';
import { stringify as formStringify, parse as formParse } from 'node:querystring';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import {
  bridgeConfiguration,
  canNavigatePlaylist,
  createTargetID,
  gainRatioFromMpvPercent,
  effectiveMpvVolumePercent,
  iinaFormData,
  maximumCommandsPerPoll,
  mpvPercentFromGainRatio,
  shouldUnmuteForGainRatio,
  targetSnapshot,
  validateAction,
} from '../dist/iina-controls.js';

// This generated non-secret sentinel satisfies the plugin's length guard in
// the isolated harness; it is never sent to a real bridge.
const BRIDGE_LENGTH_SENTINEL = Array.from({ length: 32 }, (_, index) =>
  String.fromCharCode(65 + (index % 26)),
).join('');

function createMainHarness({
  port,
  token,
  commands = [],
  httpLatency = 0,
  idleBeforeFirstCommand = false,
  playlistCount = 1,
  playlistPosition = 0,
}) {
  let now = 1_800_000_000_000;
  let targetId = '';
  let paused = false;
  let idle = false;
  let firstCommandRead = false;
  let activeRequests = 0;
  let maximumConcurrentRequests = 0;
  const calls = [];
  const results = [];
  const sideEffects = [];
  const handlers = new Map();
  const timers = [];
  const preferences = { bridge_port: port, bridge_token: token };
  const record = async (method, path, options) => {
    activeRequests += 1;
    maximumConcurrentRequests = Math.max(maximumConcurrentRequests, activeRequests);
    now += httpLatency;
    const call = { method, path, options };
    calls.push(call);
    if (path.endsWith('/update')) {
      targetId = JSON.parse(options.data.payload).id;
    }
    if (path.endsWith('/result')) results.push(JSON.parse(options.data.payload));
    await Promise.resolve();
    activeRequests -= 1;
    if (method === 'get') {
      if (idleBeforeFirstCommand && !firstCommandRead) {
        idle = true;
        firstCommandRead = true;
      }
      const command = commands.shift() ?? undefined;
      return {
        statusCode: 200,
        data: {
          command: command?.targetId === '$current' ? { ...command, targetId } : command,
        },
      };
    }
    return { statusCode: 204, data: undefined };
  };
  const iina = {
    preferences: { get: (key) => preferences[key] },
    event: { on: (name, handler) => handlers.set(name, handler) },
    http: {
      post: (path, options) => record('post', path, options),
      get: (path, options) => record('get', path, options),
    },
    core: {
      status: {
        title: 'Episode',
        get idle() {
          return idle;
        },
        position: 5,
        duration: 60,
        get paused() {
          return paused;
        },
      },
      audio: { volume: 60, muted: false },
      pause: () => {
        sideEffects.push('pause');
        paused = true;
      },
      resume: () => {
        sideEffects.push('resume');
        paused = false;
      },
      seek: (value, relative) => sideEffects.push({ type: 'seek', value, relative }),
    },
    mpv: {
      getNumber: (name) => (name === 'volume-max' ? 130 : playlistPosition),
    },
    playlist: {
      count: () => playlistCount,
      playNext: () => sideEffects.push('next'),
      playPrevious: () => sideEffects.push('previous'),
    },
  };
  Object.defineProperty(iina.core.audio, 'volume', {
    get: () => 60,
    set: (value) => sideEffects.push({ type: 'volume', value }),
  });
  Object.defineProperty(iina.core.audio, 'muted', {
    get: () => false,
    set: (value) => sideEffects.push({ type: 'muted', value }),
  });
  const context = vm.createContext({
    iina,
    Date: { now: () => now },
    setTimeout: (resolve, delay) => {
      timers.push({ resolve, delay });
      return timers.length;
    },
  });
  return {
    calls,
    commands,
    context,
    handlers,
    maximumConcurrentRequests: () => maximumConcurrentRequests,
    preferences,
    results,
    sideEffects,
    targetID: () => targetId,
    advanceTime: (milliseconds) => {
      now += milliseconds;
    },
    timers,
    time: () => now,
  };
}

async function loadMainSource() {
  return readFile(new URL('../dist/SofaRemote.iinaplugin/main.js', import.meta.url), 'utf8');
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100 && !predicate(); attempt += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(predicate(), true, 'Expected asynchronous IINA work to complete');
}

async function resolveNextTimer(harness) {
  await waitFor(() => harness.timers.length > 0);
  const [{ resolve, delay }] = harness.timers.splice(0, 1);
  harness.advanceTime(delay);
  resolve();
  return delay;
}

function commandFor(targetId, index) {
  return { requestId: `request-${index}`, targetId, action: 'playPause' };
}

test('IINA state exposes exact target ID and gain-ratio volume range', () => {
  const state = targetSnapshot({
    targetId: 'iina:window-1',
    title: 'Episode',
    idle: false,
    position: 5,
    duration: 60,
    mpvVolumePercent: 110,
    maximumMpvPercent: 130,
    muted: false,
    playlistCount: 2,
    playlistPosition: 0,
  });
  assert.equal(state.target.id, 'iina:window-1');
  assert.equal(state.target.capabilities.playerVolumeMaximum, 1.3);
  assert.equal(state.target.playerVolume, 1.1);
  assert.equal(state.volume, 1.1);
  assert.equal(state.target.capabilities.next, true);
  assert.equal(state.target.capabilities.previous, false);
  const later = targetSnapshot({
    targetId: 'iina:window-a',
    title: 'Episode',
    idle: false,
    position: 5,
    duration: 60,
    mpvVolumePercent: 90,
    maximumMpvPercent: 130,
    muted: false,
    playlistCount: 2,
    playlistPosition: 1,
  });
  assert.equal(later.target.capabilities.next, false);
  assert.equal(later.target.capabilities.previous, true);
});

test('IINA converts gain-ratio commands to mpv percentages within the raw range', () => {
  assert.equal(gainRatioFromMpvPercent(130), 1.3);
  validateAction('setVolume', 1.1, 130);
  assert.ok(Math.abs(mpvPercentFromGainRatio(1.1, 130) - 110) < 1e-12);
  assert.equal(mpvPercentFromGainRatio(1.3, 130), 130);
  assert.throws(
    () => validateAction('setVolume', 1.31, 130),
    /outside the current IINA player range/,
  );
  assert.throws(() => validateAction('seek', 0, 130), /finite nonzero interval/);
});

test('IINA rejects malformed volume inputs and non-finite conversions', () => {
  assert.equal(gainRatioFromMpvPercent(Number.NaN), null);
  assert.equal(gainRatioFromMpvPercent(Number.POSITIVE_INFINITY), null);
  assert.equal(gainRatioFromMpvPercent(-1), null);
  assert.equal(mpvPercentFromGainRatio(Number.POSITIVE_INFINITY, 130), null);
  assert.equal(mpvPercentFromGainRatio(-0.1, 130), null);
  assert.equal(mpvPercentFromGainRatio(1.31, 130), null);
  assert.equal(mpvPercentFromGainRatio(1.1, Number.NaN), null);
});

test('IINA disables unavailable playlist controls and exposes volume as gain ratio', () => {
  const state = targetSnapshot({
    targetId: 'iina:window-2',
    title: '',
    idle: false,
    position: null,
    duration: null,
    mpvVolumePercent: 5,
    maximumMpvPercent: 130,
    muted: false,
    playlistCount: 1,
    playlistPosition: 0,
  });
  assert.equal(state.target.capabilities.next, false);
  assert.equal(state.target.capabilities.previous, false);
  assert.equal(state.target.capabilities.playerVolumeMaximum, 1.3);
  assert.equal(state.target.playerVolume, 0.05);
});

test('IINA POST data survives the documented form-encoded options.data wire path', () => {
  const request = {
    targetId: 'iina:window-1',
    name: 'Episode + A & B = C',
    capabilities: { playPause: true },
  };
  const optionsData = iinaFormData(request);
  const wireBody = formStringify(optionsData);
  assert.match(wireBody, /^payload=%7B/);
  assert.deepEqual(JSON.parse(formParse(wireBody).payload), request);
});

test('IINA target IDs are locally unique routing labels and not browser crypto tokens', () => {
  const randomValues = [0.25, 0.5, 0.75, 0.125];
  let index = 0;
  const first = createTargetID(1_800_000_000_000, () => randomValues[index++]);
  const second = createTargetID(1_800_000_000_000, () => randomValues[index++]);
  assert.match(first, /^iina:[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$/);
  assert.notEqual(first, second);
});

test('IINA target names are UTF-8 byte bounded without browser encoders', () => {
  const state = targetSnapshot({
    targetId: 'iina:window-unicode',
    title: '😀'.repeat(100),
    idle: false,
    position: 0,
    duration: 1,
    mpvVolumePercent: 0,
    maximumMpvPercent: 100,
    muted: false,
    playlistCount: 1,
    playlistPosition: 0,
  });
  assert.ok(Buffer.byteLength(state.target.name, 'utf8') <= 256);
  assert.ok(state.target.name.endsWith('😀'));
});

test('IINA bridge settings are re-read and an invalid setup stays recoverable', async () => {
  const mainSource = await loadMainSource();
  const harness = createMainHarness({ port: 0, token: '' });
  vm.runInContext(mainSource, harness.context, { timeout: 1_000 });
  await waitFor(() => harness.timers.length === 1);
  assert.equal(harness.calls.length, 0);

  // The window-loaded event must not start a second poll loop.
  harness.handlers.get('iina.window-loaded')();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(harness.timers.length, 1);
  assert.equal(harness.calls.length, 0);

  harness.preferences.bridge_port = 47623;
  harness.preferences.bridge_token = BRIDGE_LENGTH_SENTINEL;
  await resolveNextTimer(harness);
  await waitFor(() => harness.calls.length === 2 && harness.timers.length === 1);

  const rotatedToken = BRIDGE_LENGTH_SENTINEL.split('').reverse().join('');
  harness.preferences.bridge_port = 47624;
  harness.preferences.bridge_token = rotatedToken;
  harness.handlers.get('iina.window-loaded')();
  await resolveNextTimer(harness);
  await waitFor(() => harness.calls.length === 4 && harness.timers.length === 1);

  const updates = harness.calls.filter((call) => call.path.endsWith('/update'));
  assert.equal(updates.length, 2);
  assert.match(updates[0].path, /^http:\/\/127\.0\.0\.1:47623\//);
  assert.equal(updates[0].options.headers.Authorization, `Bearer ${BRIDGE_LENGTH_SENTINEL}`);
  assert.match(updates[1].path, /^http:\/\/127\.0\.0\.1:47624\//);
  assert.equal(updates[1].options.headers.Authorization, `Bearer ${rotatedToken}`);
  assert.equal(harness.maximumConcurrentRequests(), 1);

  harness.handlers.get('iina.window-will-close')();
  await waitFor(() => harness.calls.some((call) => call.path.endsWith('/unregister')));
  assert.equal(harness.maximumConcurrentRequests(), 1);
});

test('IINA drains eight queued commands within the deadline without replay', async () => {
  const mainSource = await loadMainSource();
  const harness = createMainHarness({
    port: 47623,
    token: BRIDGE_LENGTH_SENTINEL,
    httpLatency: 100,
  });
  vm.runInContext(mainSource, harness.context, { timeout: 1_000 });
  await waitFor(() => harness.calls.length === 2 && harness.timers.length === 1);
  const queuedAt = harness.time();
  for (let index = 0; index < maximumCommandsPerPoll; index += 1) {
    harness.commands.push(commandFor(harness.targetID(), index));
  }

  await resolveNextTimer(harness);
  await waitFor(
    () => harness.results.length === maximumCommandsPerPoll && harness.timers.length === 1,
  );
  assert.ok(harness.time() - queuedAt < 2_000);
  assert.equal(harness.results.length, 8);
  assert.deepEqual(
    harness.results.map((result) => result.requestId),
    Array.from({ length: 8 }, (_, index) => `request-${index}`),
  );
  assert.equal(harness.timers[0].delay, 0);

  // The next bounded poll observes an empty queue and does not replay results.
  await resolveNextTimer(harness);
  await waitFor(() => harness.calls.filter((call) => call.path.includes('/next?')).length === 10);
  assert.equal(harness.results.length, 8);
  assert.equal(harness.commands.length, 0);
  assert.equal(harness.maximumConcurrentRequests(), 1);
});

test('IINA rejects queued media commands if playback becomes idle before execution', async () => {
  const mainSource = await loadMainSource();
  const cases = [
    { action: 'playPause' },
    { action: 'seek', value: 10 },
    { action: 'next' },
    { action: 'previous' },
    { action: 'setVolume', value: 0.5 },
  ];

  for (const [index, { action, value }] of cases.entries()) {
    const harness = createMainHarness({
      port: 47623,
      token: BRIDGE_LENGTH_SENTINEL,
      commands: [{ requestId: `idle-${index}`, targetId: '$current', action, value }],
      idleBeforeFirstCommand: true,
      playlistCount: 3,
      playlistPosition: 1,
    });
    vm.runInContext(mainSource, harness.context, { timeout: 1_000 });
    await waitFor(() => harness.results.length === 1 && harness.timers.length === 1);

    const update = harness.calls.find((call) => call.path.endsWith('/update'));
    assert.ok(update);
    assert.equal(JSON.parse(update.options.data.payload).capabilities.playPause, true);
    assert.equal(harness.results[0].requestId, `idle-${index}`);
    assert.equal(harness.results[0].targetId, harness.targetID());
    assert.equal(harness.results[0].ok, false, `${action} should fail after playback stops`);
    assert.match(harness.results[0].error, /IINA is idle/);
    assert.deepEqual(harness.sideEffects, [], `${action} must not affect an idle player`);
    assert.equal(harness.results.length, 1, `${action} should produce exactly one result`);
    assert.equal(harness.commands.length, 0, `${action} should not be replayed`);

    harness.handlers.get('iina.window-will-close')();
  }
});

test('IINA still executes a queued media command while playback remains active', async () => {
  const mainSource = await loadMainSource();
  const harness = createMainHarness({
    port: 47623,
    token: BRIDGE_LENGTH_SENTINEL,
    commands: [{ requestId: 'active-1', targetId: '$current', action: 'playPause' }],
  });
  vm.runInContext(mainSource, harness.context, { timeout: 1_000 });
  await waitFor(() => harness.results.length === 1 && harness.timers.length === 1);

  assert.equal(harness.results[0].requestId, 'active-1');
  assert.equal(harness.results[0].ok, true);
  assert.deepEqual(harness.sideEffects, ['pause']);
  harness.handlers.get('iina.window-will-close')();
});

test('IINA rejects invalid bridge settings without making a loopback request', () => {
  assert.equal(bridgeConfiguration(0, BRIDGE_LENGTH_SENTINEL), null);
  assert.equal(bridgeConfiguration(65_536, BRIDGE_LENGTH_SENTINEL), null);
  assert.equal(bridgeConfiguration(47623.5, BRIDGE_LENGTH_SENTINEL), null);
  assert.equal(bridgeConfiguration(47623, ''), null);
  assert.deepEqual(bridgeConfiguration(47623, BRIDGE_LENGTH_SENTINEL), {
    port: 47623,
    token: BRIDGE_LENGTH_SENTINEL,
  });
});

test('IINA playlist availability is checked against the execution-time position', async () => {
  assert.equal(canNavigatePlaylist('next', 3, 0), true);
  assert.equal(canNavigatePlaylist('next', 3, 2), false);
  assert.equal(canNavigatePlaylist('previous', 3, 0), false);
  assert.equal(canNavigatePlaylist('previous', 3, 2), true);
  assert.equal(canNavigatePlaylist('next', 3, Number.NaN), false);

  const mainSource = await readFile(
    new URL('../dist/SofaRemote.iinaplugin/main.js', import.meta.url),
    'utf8',
  );
  const handlers = new Map();
  const posts = [];
  const getCalls = [];
  let playlistPositionReads = 0;
  let commandReturned = false;
  let nextCalls = 0;
  const iina = {
    preferences: { get: (key) => (key === 'bridge_port' ? 47623 : BRIDGE_LENGTH_SENTINEL) },
    event: { on: (name, handler) => handlers.set(name, handler) },
    http: {
      post: async (path, options) => {
        posts.push({ path, options });
        return { statusCode: 204, data: undefined };
      },
      get: async (path, options) => {
        getCalls.push({ path, options });
        if (commandReturned) return { statusCode: 200, data: {} };
        commandReturned = true;
        return {
          statusCode: 200,
          data: {
            command: {
              requestId: 'request-1',
              targetId: posts.find((post) => post.path.endsWith('/update'))
                ? JSON.parse(
                    posts.find((post) => post.path.endsWith('/update')).options.data.payload,
                  ).id
                : '',
              action: 'next',
            },
          },
        };
      },
    },
    core: {
      status: { title: 'Episode', idle: false, position: 3, duration: 30, paused: false },
      audio: { volume: 60, muted: false },
      pause: () => undefined,
      resume: () => undefined,
      seek: () => undefined,
    },
    mpv: {
      getNumber: (name) => {
        if (name === 'volume-max') return 130;
        playlistPositionReads += 1;
        return playlistPositionReads === 1 ? 0 : 2;
      },
    },
    playlist: {
      count: () => 3,
      playNext: () => {
        nextCalls += 1;
      },
      playPrevious: () => undefined,
    },
  };
  const context = vm.createContext({
    iina,
    setTimeout: () => 1,
    clearTimeout: () => undefined,
  });
  assert.equal('crypto' in context, false);
  assert.equal('TextEncoder' in context, false);
  assert.equal('URLSearchParams' in context, false);
  vm.runInContext(mainSource, context, { timeout: 1_000 });

  for (let attempt = 0; attempt < 20 && getCalls.length === 0; attempt += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(getCalls.length, 2);
  assert.equal(nextCalls, 0);
  const update = posts.find((post) => post.path.endsWith('/update'));
  assert.ok(update);
  const target = JSON.parse(update.options.data.payload);
  assert.match(target.id, /^iina:/);
  assert.equal(playlistPositionReads, 2);
  assert.equal(
    posts.some((post) => post.path.endsWith('/result')),
    true,
  );
  const result = JSON.parse(
    posts.find((post) => post.path.endsWith('/result')).options.data.payload,
  );
  assert.equal(result.ok, false);
  assert.match(result.error, /no next playlist item/);

  handlers.get('iina.window-will-close')();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(
    posts.some((post) => post.path.endsWith('/unregister')),
    true,
  );
});

test('IINA snapshots report zero effective volume while muted', () => {
  assert.equal(effectiveMpvVolumePercent(72, true), 0);
  assert.equal(effectiveMpvVolumePercent(72, false), 72);
  assert.equal(effectiveMpvVolumePercent(Number.NaN, false), null);
  const state = targetSnapshot({
    targetId: 'iina:window-muted',
    title: 'Muted',
    idle: false,
    position: 5,
    duration: 60,
    mpvVolumePercent: 72,
    maximumMpvPercent: 130,
    muted: true,
    playlistCount: 1,
    playlistPosition: 0,
  });
  assert.equal(state.volume, 0);
  assert.equal(state.target.playerVolume, 0);
});

test('only positive player-volume commands request clearing IINA mute', () => {
  assert.equal(shouldUnmuteForGainRatio(0), false);
  assert.equal(shouldUnmuteForGainRatio(0.01), true);
  assert.equal(shouldUnmuteForGainRatio(Number.NaN), false);
});
