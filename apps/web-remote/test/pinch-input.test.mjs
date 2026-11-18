import assert from 'node:assert/strict';
import test from 'node:test';
import { RemoteInputBuffer } from '../dist/remote-input.js';
import { LiveTouchpad } from '../dist/live-touchpad.js';

function fixture(beforeFlush) {
  const callbacks = new Map();
  const sent = [];
  let serial = 0;
  const input = new RemoteInputBuffer(
    { request: (f) => (callbacks.set(++serial, f), serial), cancel: (id) => callbacks.delete(id) },
    () => assert.fail('unexpected transport failure'),
    beforeFlush,
  );
  input.connect((command) => (sent.push(command), true));
  return {
    input,
    sent,
    callbacks,
    frame() {
      const pending = [...callbacks.values()];
      callbacks.clear();
      pending.forEach((f) => f());
    },
  };
}

function frame(id, phase, value = 0, timestamp = 1) {
  return { name: 'gesture.frame', gesture: { id, kind: 'magnify', phase, value, timestamp } };
}

test('pinch changes coalesce cumulatively between immediate begin and terminal barriers', () => {
  const f = fixture();
  const id = crypto.randomUUID();
  assert.equal(f.input.enqueue(frame(id, 'began')), true);
  f.input.enqueue(frame(id, 'changed', 0.1, 2));
  f.input.enqueue(frame(id, 'changed', 0.3, 3));
  assert.equal(f.sent.length, 1);
  f.frame();
  assert.deepEqual(
    f.sent.map((c) => c.gesture.value),
    [0, 0.3],
  );
  f.input.enqueue(frame(id, 'changed', 0.4, 4));
  f.input.enqueue(frame(id, 'ended', 0.5, 5));
  f.frame();
  assert.deepEqual(
    f.sent.map((c) => c.gesture.phase),
    ['began', 'changed', 'ended'],
  );
  assert.equal(f.sent.at(-1).gesture.value, 0.5);
  assert.equal(f.input.activeGesture, null);
});

test('cancellation drops unsent magnification and releases the last delivered gesture once', () => {
  const f = fixture();
  const id = crypto.randomUUID();
  f.input.enqueue(frame(id, 'began'));
  f.input.enqueue(frame(id, 'changed', 0.7, 2));
  f.input.cancelGesture();
  f.input.cancelGesture();
  f.frame();
  assert.deepEqual(f.sent, [frame(id, 'began'), frame(id, 'cancelled')]);
  f.input.disconnect();
  f.input.connect(() => assert.fail('a cancelled gesture must never replay'));
  f.frame();
});

test('magnification rejects foreign identity, decreasing time, extra fields and non-magnify kinds', () => {
  const f = fixture();
  const id = crypto.randomUUID();
  assert.equal(f.input.enqueue(frame(id, 'changed', 0.1)), false);
  assert.equal(f.input.enqueue(frame(id, 'began', 1)), false);
  assert.equal(f.input.enqueue({ ...frame(id, 'began'), key: 'up' }), false);
  assert.equal(
    f.input.enqueue({
      name: 'gesture.frame',
      gesture: { ...frame(id, 'began').gesture, kind: 'horizontalSwipe' },
    }),
    false,
  );
  assert.equal(
    f.input.enqueue({
      name: 'gesture.frame',
      gesture: { ...frame(id, 'began').gesture, extra: 1 },
    }),
    false,
  );
  assert.equal(f.input.enqueue(frame(id, 'began')), true);
  assert.equal(f.input.enqueue(frame(crypto.randomUUID(), 'changed', 0.2, 2)), false);
  assert.equal(f.input.enqueue(frame(id, 'changed', 0.3, 3)), true);
  assert.equal(f.input.enqueue(frame(id, 'changed', 0.2, 2)), false);
  for (const value of [NaN, Infinity, 4.01, -4.01])
    assert.equal(f.input.enqueue(frame(id, 'changed', value, 4)), false);
  f.input.disconnect();
  assert.equal(f.input.activeGesture, null);
});

test('touch sampling and transmission share one animation frame', () => {
  let f;
  f = fixture(() => f.input.enqueue({ name: 'pointer.scroll', x: 0, y: 12 }));
  f.input.requestFlush();
  f.frame();
  assert.deepEqual(f.sent, [{ name: 'pointer.scroll', x: 0, y: 12 }]);
  assert.equal(f.callbacks.size, 0, 'sampling must not add another input frame');
});

test('real contact sampling sends pinch in one frame and preserves keyboard ordering barriers', () => {
  let pad;
  const f = fixture(() => pad.flush());
  pad = new LiveTouchpad(
    (c) => f.input.enqueue(c),
    () => f.input.requestFlush(),
  );
  pad.setMagnificationEnabled(true);
  pad.begin(1, { x: 100, y: 100 }, 0);
  pad.begin(2, { x: 200, y: 100 }, 1);
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  assert.equal(f.sent.length, 0);
  f.frame();
  assert.deepEqual(
    f.sent.map((c) => c.gesture.phase),
    ['began', 'changed'],
  );
  assert.equal(f.callbacks.size, 0);
  pad.move(1, { x: 80, y: 100 }, 20);
  pad.move(2, { x: 220, y: 100 }, 21);
  f.input.enqueue({ name: 'keyboard.key', key: 'escape' });
  assert.equal(f.sent.at(-2).gesture.value, Math.log(1.4));
  assert.equal(f.sent.at(-1).name, 'keyboard.key');
  pad.cancel();
  f.frame();
  assert.equal(f.sent.at(-1).gesture.phase, 'cancelled');
});
