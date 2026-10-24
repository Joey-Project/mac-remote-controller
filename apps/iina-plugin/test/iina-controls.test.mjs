import assert from 'node:assert/strict';
import test from 'node:test';
import { targetSnapshot, validateAction } from '../dist/iina-controls.js';

test('IINA state exposes exact target ID and actual player volume maximum', () => {
  const state = targetSnapshot({
    targetId: 'iina:window-1',
    title: 'Episode',
    idle: false,
    position: 5,
    duration: 60,
    volume: 90,
    maximumVolume: 130,
    playlistCount: 2,
    playlistPosition: 0,
  });
  assert.equal(state.target.id, 'iina:window-1');
  assert.equal(state.target.capabilities.playerVolumeMaximum, 130);
  assert.equal(state.target.capabilities.next, true);
  assert.equal(state.target.capabilities.previous, false);
  const later = targetSnapshot({
    targetId: 'iina:window-a',
    title: 'Episode',
    idle: false,
    position: 5,
    duration: 60,
    volume: 90,
    maximumVolume: 130,
    playlistCount: 2,
    playlistPosition: 1,
  });
  assert.equal(later.target.capabilities.next, false);
  assert.equal(later.target.capabilities.previous, true);
});

test('IINA disables unavailable playlist controls and rejects out-of-range volume', () => {
  const state = targetSnapshot({
    targetId: 'iina:window-2',
    title: '',
    idle: false,
    position: null,
    duration: null,
    volume: 5,
    maximumVolume: 130,
    playlistCount: 1,
    playlistPosition: 0,
  });
  assert.equal(state.target.capabilities.next, false);
  assert.equal(state.target.capabilities.previous, false);
  assert.throws(
    () => validateAction('setVolume', 131, 130),
    /outside the current IINA player range/,
  );
  assert.throws(() => validateAction('seek', 0, 130), /finite nonzero interval/);
});
