import assert from 'node:assert/strict';
import test from 'node:test';
import {
  MediaControlsModel,
  PlayerVolumeSender,
  readMediaTargets,
  snapPlayerVolume,
  validMediaRequest,
} from '../dist/media-model.js';

function player(overrides = {}) {
  return {
    id: 'iina:fixture',
    name: 'Fixture player',
    kind: 'iina',
    capabilities: {
      playPause: true,
      seek: true,
      previous: true,
      next: true,
      playerVolumeMaximum: 4,
    },
    playerVolume: 0.6,
    ...overrides,
  };
}
function selected() {
  const model = new MediaControlsModel();
  model.update(readMediaTargets([player()]));
  model.select('iina:fixture');
  return model;
}

test('media snapshots accept native volume ranges and copy only presentation fields', () => {
  assert.equal(readMediaTargets(undefined), null);
  assert.equal(readMediaTargets(null), null);
  const original = player({ name: '<img src=x onerror=bad()>', privateField: 'ignored' });
  const [parsed] = readMediaTargets([original]);
  assert.equal(parsed.name, original.name);
  assert.equal(parsed.capabilities.playerVolumeMaximum, 4);
  assert.equal('privateField' in parsed, false);
  assert.notEqual(parsed.capabilities, original.capabilities);
});

test('media snapshots reject duplicate IDs, UTF-8 overflow, invalid caps and impossible volume', () => {
  for (const value of [
    {},
    Array(65).fill(player()),
    [player(), player()],
    [player({ id: '中'.repeat(43) })],
    [player({ name: '中'.repeat(86) })],
    [player({ kind: 'unknown' })],
    [player({ playerVolume: -1 })],
    [player({ playerVolume: 4.1 })],
    [player({ playerVolume: Infinity })],
    [player({ playerVolume: NaN })],
    [player({ capabilities: { ...player().capabilities, seek: 'true' } })],
    [player({ capabilities: { ...player().capabilities, playerVolumeMaximum: 0 } })],
    [player({ capabilities: { ...player().capabilities, playerVolumeMaximum: null } })],
  ])
    assert.throws(() => readMediaTargets(value), /media|volume|capabilities|source/i);
});

test('media requires explicit selection and honors each capability', () => {
  const model = new MediaControlsModel();
  model.update(
    readMediaTargets([player({ capabilities: { ...player().capabilities, next: false } })]),
  );
  assert.equal(model.target, null);
  assert.equal(model.control('playPause'), null);
  model.select('iina:fixture');
  assert.equal(model.control('next'), null);
  assert.deepEqual(model.control('seek', -10), {
    name: 'media.control',
    mediaRequest: { targetId: 'iina:fixture', action: 'seek', value: -10 },
  });
  assert.equal(model.control('seek', 0), null);
  assert.equal(model.control('playPause').mediaRequest.action, 'playPause');
});

test('a disappearing player never retargets actions to the remaining source', () => {
  const model = selected();
  assert.equal(
    model.update(readMediaTargets([player({ id: 'chrome:other', kind: 'youtube' })])),
    true,
  );
  assert.equal(model.selectedID, null);
  assert.equal(model.control('playPause'), null);
  assert.equal(model.volume(80), null);
});

test('player volume uses 10% increments, a strong 100% detent, and the full advertised range', () => {
  for (const [proposed, maximum, expected] of [
    [94, 400, 100],
    [107.5, 400, 100],
    [108, 400, 110],
    [91, 400, 90],
    [124, 400, 120],
    [401, 400, 400],
    [-1, 400, 0],
    [125, 125, 125],
    [4, 5, 5],
    [20, 5, 5],
    [97, 99, 99],
  ])
    assert.equal(snapPlayerVolume(proposed, maximum), expected);
  assert.equal(snapPlayerVolume(NaN, 100), null);
  assert.equal(snapPlayerVolume(30, Infinity), null);
  const model = selected();
  assert.equal(model.volume(119).mediaRequest.value, 1.2);
  assert.equal(model.volume(400).mediaRequest.value, 4);
  assert.equal(model.volume(60), null);
});

test('range changes discard optimistic values and preserve non-decimal maximum endpoints', () => {
  const model = selected();
  const pending = model.volume(400);
  model.requested(pending);
  assert.equal(model.volumePercent, 400);
  model.update(
    readMediaTargets([
      player({
        capabilities: { ...player().capabilities, playerVolumeMaximum: 1.25 },
        playerVolume: 1.2,
      }),
    ]),
  );
  model.complete(pending, null);
  assert.equal(model.volumePercent, 120);
  assert.equal(model.volumeMaximumPercent, 125);
  assert.equal(model.volume(125).mediaRequest.value, 1.25);
});

test('decimal percentage rounding does not repeatedly send the same gain', () => {
  const model = selected();
  const command = model.volume(110);
  model.requested(command);
  assert.equal(model.volume(110), null);
  model.complete(command, null);
  assert.equal(model.volume(110), null);
  model.update(readMediaTargets([player({ playerVolume: 1.1 })]));
  assert.equal(model.volume(110), null);
});

test('old acks and unchanged snapshots cannot replace the latest slider intent', () => {
  const model = selected();
  const old = model.volume(120);
  model.requested(old);
  const latest = model.volume(150);
  model.requested(latest);
  model.complete(old, 'fixture failure');
  model.update(readMediaTargets([player()]));
  assert.equal(model.volumePercent, 150);
  model.complete(latest, null);
  model.update(readMediaTargets([player()]));
  assert.equal(model.volumePercent, 150);
  model.update(readMediaTargets([player({ playerVolume: 1.5 })]));
  assert.equal(model.volumePercent, 150);
  model.update(readMediaTargets([player({ playerVolume: 0.7 })]));
  assert.equal(model.volumePercent, 70);
});

test('failed latest volume restores actual state and old same-value requests cannot win', () => {
  const model = selected();
  const old = model.volume(120);
  model.requested(old);
  model.select('iina:fixture');
  const fresh = model.volume(120);
  model.requested(fresh);
  model.complete(old, null);
  model.complete(fresh, 'fixture failure');
  assert.equal(model.volumePercent, 60);
});

test('disconnect keeps selection only until a fresh snapshot verifies that target', () => {
  const model = selected();
  const old = model.volume(120);
  model.requested(old);
  model.disconnect();
  assert.equal(model.selectedID, 'iina:fixture');
  assert.equal(model.supports('playPause'), false);
  assert.equal(model.volumePercent, null);
  model.update(readMediaTargets([player({ playerVolume: 0.9 })]));
  model.complete(old, null);
  assert.equal(model.volumePercent, 90);
  model.update([]);
  model.update(readMediaTargets([player()]));
  assert.equal(model.selectedID, null);
});

test('unknown volume and unrepresentable percent ranges remain unavailable', () => {
  const model = selected();
  for (const target of [
    player({ playerVolume: null }),
    player({
      capabilities: { ...player().capabilities, playerVolumeMaximum: Number.MAX_VALUE },
    }),
  ]) {
    model.update(readMediaTargets([target]));
    assert.equal(model.supports('setVolume'), false);
    assert.equal(model.volume(20), null);
  }
});

test('media requests reject unexpected fields and invalid seek or gain values', () => {
  for (const request of [
    { targetId: 'iina:test', action: 'seek', value: 0 },
    { targetId: 'iina:test', action: 'seek', value: 3601 },
    { targetId: 'iina:test', action: 'playPause', value: 1 },
    { targetId: 'iina:test', action: 'next', extra: true },
    { targetId: 'iina:test', action: 'setVolume', value: -1 },
    { targetId: 'iina:test', action: 'setVolume', value: Infinity },
    { targetId: '', action: 'previous' },
  ])
    assert.equal(validMediaRequest(request), false);
});

function gain(value, targetId = 'iina:fixture') {
  return { name: 'media.control', mediaRequest: { targetId, action: 'setVolume', value } };
}

test('slow player acknowledgements retain only the latest unsent slider value', () => {
  const sent = [];
  const sender = new PlayerVolumeSender((command) => {
    sent.push(command);
    return true;
  });
  const first = gain(0.1);
  sender.enqueue(first);
  for (let value = 2; value <= 40; value++) assert.equal(sender.enqueue(gain(value / 10)), true);
  assert.deepEqual(sent, [first]);
  sender.complete(first);
  assert.equal(sent.length, 2);
  assert.equal(sent[1].mediaRequest.value, 4);
  sender.complete(first);
  assert.equal(sent.length, 2);
  sender.complete(sent[1]);
  assert.equal(sent.length, 2);
});

test('cancelled volume queues ignore old acknowledgements after reconnect or selection', () => {
  const sent = [];
  const sender = new PlayerVolumeSender((command) => {
    sent.push(command);
    return true;
  });
  const old = gain(1.2);
  sender.enqueue(old);
  sender.enqueue(gain(2));
  sender.cancel();
  const fresh = gain(1.2);
  sender.enqueue(fresh);
  sender.enqueue(gain(3));
  sender.complete(old);
  assert.deepEqual(sent, [old, fresh]);
  sender.complete(fresh);
  assert.equal(sent.at(-1).mediaRequest.value, 3);
});

test('ambiguous volume send failure drops queued intent without replay', () => {
  const sent = [];
  const sender = new PlayerVolumeSender((command) => {
    sent.push(command);
    return sent.length === 1;
  });
  const first = gain(1.2);
  const latest = gain(2);
  sender.enqueue(first);
  sender.enqueue(latest);
  sender.complete(first);
  sender.complete(latest);
  sender.complete(first);
  assert.deepEqual(sent, [first, latest]);
});

test('a volume queue does not accept another target or discrete media actions', () => {
  const sender = new PlayerVolumeSender(() => true);
  sender.enqueue(gain(1.2));
  assert.equal(sender.enqueue(gain(2, 'chrome:other')), false);
  assert.equal(
    sender.enqueue({
      name: 'media.control',
      mediaRequest: { targetId: 'iina:fixture', action: 'next' },
    }),
    false,
  );
});
