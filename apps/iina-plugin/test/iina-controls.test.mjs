import assert from 'node:assert/strict';
import test from 'node:test';
import {
  gainRatioFromMpvPercent,
  effectiveMpvVolumePercent,
  iinaFormData,
  mpvPercentFromGainRatio,
  shouldUnmuteForGainRatio,
  targetSnapshot,
  validateAction,
} from '../dist/iina-controls.js';

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
  const wireBody = new URLSearchParams(optionsData).toString();
  assert.match(wireBody, /^payload=%7B/);
  assert.deepEqual(JSON.parse(new URLSearchParams(wireBody).get('payload')), request);
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
