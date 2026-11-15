import assert from 'node:assert/strict';
import test from 'node:test';
import { RemoteInputBuffer } from '../dist/remote-input.js';

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
