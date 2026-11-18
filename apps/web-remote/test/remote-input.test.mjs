import assert from 'node:assert/strict';
import test from 'node:test';
import { RemoteInputBuffer } from '../dist/remote-input.js';
import { MediaControlsModel, readMediaTargets } from '../dist/media-model.js';

function fixture() {
  let next = 0;
  const callbacks = new Map();
  const sent = [];
  let failures = 0;
  const input = new RemoteInputBuffer(
    {
      request(callback) {
        callbacks.set(++next, callback);
        return next;
      },
      cancel(identifier) {
        callbacks.delete(identifier);
      },
    },
    () => {
      failures += 1;
    },
  );
  input.connect((command) => {
    sent.push(command);
    return true;
  });
  return {
    input,
    sent,
    callbacks,
    failures: () => failures,
    frame() {
      const values = Array.from(callbacks.values());
      callbacks.clear();
      values.forEach((callback) => callback());
    },
  };
}

test('desktop actions are immediate ordering barriers and are not repeated on the next frame', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.move', x: 12, y: 7 });
  for (const shortcut of ['previous-space', 'mission-control', 'app-expose', 'next-space'])
    assert.equal(f.input.enqueue({ name: 'system.shortcut', shortcut }), true);
  f.frame();
  assert.deepEqual(
    f.sent.map((command) => command.name),
    ['pointer.move', 'system.shortcut', 'system.shortcut', 'system.shortcut', 'system.shortcut'],
  );
  assert.deepEqual(
    f.sent.slice(1).map((command) => command.shortcut),
    ['previous-space', 'mission-control', 'app-expose', 'next-space'],
  );
});

test('session actions send exactly one parameterless command immediately', () => {
  const f = fixture();
  const names = [
    'session.lock',
    'session.unlock',
    'display.off',
    'display.wake',
    'session.lock-display-off',
  ];
  for (const name of names) assert.equal(f.input.enqueue({ name }), true);
  f.frame();
  assert.deepEqual(
    f.sent,
    names.map((name) => ({ name })),
  );
  f.input.disconnect();
  f.input.connect(() => assert.fail('a session action must never replay'));
  f.frame();
});

test('session actions reject extra fields and arbitrary power commands', () => {
  const f = fixture();
  for (const name of [
    'session.lock',
    'session.unlock',
    'display.off',
    'display.wake',
    'session.lock-display-off',
  ]) {
    assert.equal(f.input.enqueue({ name, value: 1 }), false);
    assert.equal(f.input.enqueue({ name, key: 'return' }), false);
    assert.equal(f.input.enqueue({ name, value: undefined }), false);
  }
  for (const name of ['system.sleep', 'session.login', 'display.shell'])
    assert.equal(f.input.enqueue({ name }), false);
  assert.deepEqual(f.sent, []);
});

test('gesture cancellation preserves queued media volume but target cancellation drops it', () => {
  const f = fixture();
  const command = {
    name: 'media.control',
    mediaRequest: { targetId: 'iina:test', action: 'setVolume', value: 1.2 },
  };
  f.input.enqueue(command);
  f.input.cancelGesture();
  f.frame();
  assert.equal(f.sent[0].mediaRequest, command.mediaRequest);
  f.input.enqueue(command);
  f.input.cancelMediaVolume();
  f.frame();
  assert.equal(f.sent.length, 1);
  f.input.enqueue({ name: 'pointer.move', x: 10, y: 5 });
  f.input.cancelMediaVolume();
  f.frame();
  assert.equal(f.sent.at(-1).name, 'pointer.move');
});

test('coalesced volume ack retains request identity and disconnect never replays it', () => {
  const f = fixture();
  const model = new MediaControlsModel();
  model.update(
    readMediaTargets([
      {
        id: 'iina:test',
        name: 'Fixture',
        kind: 'iina',
        capabilities: {
          playPause: true,
          seek: true,
          next: true,
          previous: true,
          playerVolumeMaximum: 4,
        },
        playerVolume: 0.6,
      },
    ]),
  );
  model.select('iina:test');
  const command = model.volume(120);
  f.input.enqueue(command);
  model.requested(command);
  f.frame();
  model.complete(f.sent[0], 'fixture error');
  assert.equal(model.volumePercent, 60);
  f.input.enqueue(command);
  f.input.disconnect();
  f.input.connect(() => {
    throw new Error('Must not replay');
  });
  f.frame();
  assert.equal(f.failures(), 0);
});

test('adjacent movement waits at most one frame and preserves total displacement', () => {
  const f = fixture();
  for (let index = 0; index < 20; index += 1)
    f.input.enqueue({ name: 'pointer.move', x: 40, y: -25 });
  assert.equal(f.callbacks.size, 1);
  assert.equal(f.sent.length, 0);
  f.frame();
  assert.equal(f.sent.length, 2);
  assert.equal(
    f.sent.reduce((sum, command) => sum + command.x, 0),
    800,
  );
  assert.equal(
    f.sent.reduce((sum, command) => sum + command.y, 0),
    -500,
  );
  assert(f.sent.every((command) => Math.abs(command.x) <= 500 && Math.abs(command.y) <= 500));
});

test('clicks and keyboard actions flush prior motion without a frame delay', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.move', x: 10, y: 20 });
  f.input.enqueue({ name: 'pointer.click', button: 'left' });
  f.input.enqueue({ name: 'pointer.scroll', x: 0, y: 230 });
  f.input.enqueue({ name: 'keyboard.key', key: 'escape' });
  assert.deepEqual(
    f.sent.map((command) => command.name),
    [
      'pointer.move',
      'pointer.click',
      'pointer.scroll',
      'pointer.scroll',
      'pointer.scroll',
      'keyboard.key',
    ],
  );
  assert.equal(f.callbacks.size, 0);
});

test('new navigation keys and editing shortcuts stay immediate and never replay', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.move', x: 3, y: 7 });
  assert.equal(f.input.enqueue({ name: 'keyboard.key', key: 'tab' }), true);
  assert.equal(f.input.enqueue({ name: 'keyboard.shortcut', keyboardShortcut: 'copy' }), true);
  assert.deepEqual(f.sent, [
    { name: 'pointer.move', x: 3, y: 7 },
    { name: 'keyboard.key', key: 'tab' },
    { name: 'keyboard.shortcut', keyboardShortcut: 'copy' },
  ]);
  f.frame();
  f.input.disconnect();
  f.input.connect(() => assert.fail('keys and shortcuts must never replay'));
  f.frame();
});

test('keyboard actions reject modifier state, key codes and unrelated fields', () => {
  const f = fixture();
  for (const command of [
    { name: 'keyboard.key', key: 'left', modifiers: ['command'] },
    { name: 'keyboard.key', key: 'tab', keyCode: 48 },
    { name: 'keyboard.shortcut', keyboardShortcut: 'copy', key: 'tab' },
    { name: 'keyboard.shortcut', keyboardShortcut: 'command-down' },
    { name: 'keyboard.shortcut', keyboardShortcut: 'copy', text: 'private' },
  ])
    assert.equal(f.input.enqueue(command), false);
  assert.deepEqual(f.sent, []);
});

test('volume retains only the latest value and preserves ordering against text', () => {
  const f = fixture();
  f.input.enqueue({ name: 'system.volume.set', value: 0.1 });
  f.input.enqueue({ name: 'system.volume.set', value: 0.3 });
  f.input.enqueue({ name: 'keyboard.text', text: '你好' });
  assert.deepEqual(f.sent, [
    { name: 'system.volume.set', value: 0.3 },
    { name: 'keyboard.text', text: '你好' },
  ]);
});

test('media buttons flush prior motion and deliver one target-specific action', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.move', x: 12, y: 7 });
  const command = {
    name: 'media.control',
    mediaRequest: { targetId: 'iina:player', action: 'seek', value: -10 },
  };
  assert.equal(f.input.enqueue(command), true);
  assert.deepEqual(f.sent, [{ name: 'pointer.move', x: 12, y: 7 }, command]);
  f.frame();
  assert.equal(f.sent.length, 2);
});

test('player volume coalesces only for the same target and remains an ordering barrier', () => {
  const f = fixture();
  const volume = (targetId, value) => ({
    name: 'media.control',
    mediaRequest: { targetId, action: 'setVolume', value },
  });
  assert.equal(f.input.enqueue(volume('iina:first', 1.2)), true);
  f.input.enqueue(volume('iina:first', 1.5));
  f.input.enqueue(volume('chrome:other', 0.6));
  f.input.enqueue({ name: 'keyboard.key', key: 'left' });
  assert.deepEqual(f.sent, [
    volume('iina:first', 1.5),
    volume('chrome:other', 0.6),
    { name: 'keyboard.key', key: 'left' },
  ]);
});

test('gesture cancellation discards stale motion and releases held buttons once', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  f.input.enqueue({ name: 'pointer.move', x: 5, y: 6 });
  f.input.cancelGesture();
  f.input.cancelGesture();
  assert.deepEqual(f.sent, [
    { name: 'pointer.button.down', button: 'left' },
    { name: 'pointer.button.up', button: 'left' },
  ]);
  f.frame();
  assert.equal(f.sent.length, 2);
});

test('disconnect drops unsent input and never replays it after reconnect', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.move', x: 5, y: 6 });
  f.input.disconnect();
  const reconnected = [];
  f.input.connect((command) => {
    reconnected.push(command);
    return true;
  });
  f.frame();
  assert.deepEqual(f.sent, []);
  assert.deepEqual(reconnected, []);
});

test('a send failure closes the input stream without retrying a click or following text', () => {
  const f = fixture();
  let attempts = 0;
  f.input.connect(() => {
    attempts += 1;
    return false;
  });
  assert.equal(f.input.enqueue({ name: 'pointer.click', button: 'right' }), false);
  assert.equal(f.input.enqueue({ name: 'keyboard.text', text: 'must not arrive' }), false);
  assert.equal(attempts, 1);
  assert.equal(f.failures(), 1);
});

test('invalid values cannot enter the transport; text limits count UTF-8 bytes', () => {
  const f = fixture();
  for (const command of [
    { name: 'pointer.move', x: NaN, y: 1 },
    { name: 'pointer.scroll', x: 0, y: Infinity },
    { name: 'system.volume.set', value: 1.1 },
    { name: 'keyboard.key', key: 'command' },
    { name: 'keyboard.text', text: '' },
    { name: 'keyboard.text', text: '你'.repeat(1366) },
  ])
    assert.equal(f.input.enqueue(command), false);
  assert.equal(f.input.enqueue({ name: 'keyboard.text', text: '你'.repeat(1365) }), true);
  assert.equal(f.sent.length, 1);
});

test('a stalled frame has a bounded movement budget and fails closed on overflow', () => {
  const f = fixture();
  assert.equal(f.input.enqueue({ name: 'pointer.move', x: 16000, y: 0 }), true);
  assert.equal(f.input.enqueue({ name: 'pointer.move', x: 1, y: 0 }), false);
  assert.equal(f.failures(), 1);
  assert.equal(f.callbacks.size, 0);
  assert.deepEqual(f.sent, []);
});
