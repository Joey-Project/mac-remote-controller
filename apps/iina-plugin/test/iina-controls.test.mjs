import assert from 'node:assert/strict';
import { stringify as formStringify, parse as formParse } from 'node:querystring';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import {
  canNavigatePlaylist,
  createTargetID,
  gainRatioFromMpvPercent,
  effectiveMpvVolumePercent,
  iinaFormData,
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
  assert.equal(getCalls.length, 1);
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
