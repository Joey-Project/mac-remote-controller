import assert from 'node:assert/strict';
import test from 'node:test';
import {
  desktopActionsAvailable,
  isSystemShortcut,
  sendDesktopAction,
} from '../dist/desktop-controls.js';
import { RemoteInputBuffer } from '../dist/remote-input.js';

const available = { connected: true, supportsGestures: true, accessibilityGranted: true };
function fixture(sender) {
  const sent = [];
  let cancelled = 0;
  let failure = 0;
  const input = new RemoteInputBuffer({ request: () => 1, cancel() {} }, () => {
    failure++;
  });
  input.connect((command) => {
    sent.push(command);
    return sender?.(command) ?? true;
  });
  const cancelPad = () => {
    cancelled++;
    // LiveTouchpad.cancel emits a release too; the buffer must not send two mouse-ups.
    input.enqueue({ name: 'pointer.button.up', button: 'left' });
  };
  return { input, sent, cancelPad, cancelled: () => cancelled, failure: () => failure };
}

test('desktop actions require a live supported companion and Accessibility', () => {
  assert.equal(desktopActionsAvailable(available), true);
  for (const state of [
    { ...available, connected: false },
    { ...available, supportsGestures: false },
    { ...available, accessibilityGranted: false },
  ]) {
    const f = fixture();
    assert.equal(sendDesktopAction(state, 'mission-control', f.input, f.cancelPad), false);
    assert.deepEqual(f.sent, []);
    assert.equal(f.cancelled(), 0);
  }
});

test('only the four native desktop actions are accepted; keyboard modifiers never enter a command', () => {
  for (const action of ['previous-space', 'mission-control', 'app-expose', 'next-space']) {
    const f = fixture();
    assert.equal(isSystemShortcut(action), true);
    assert.equal(sendDesktopAction(available, action, f.input, f.cancelPad), true);
    assert.deepEqual(f.sent, [{ name: 'system.shortcut', shortcut: action }]);
  }
  for (const action of ['control+up', 'shell', '', null, {}, 1]) {
    const f = fixture();
    assert.equal(sendDesktopAction(available, action, f.input, f.cancelPad), false);
    assert.equal(f.cancelled(), 0);
    assert.deepEqual(f.sent, []);
  }
  const f = fixture();
  assert.equal(
    f.input.enqueue({ name: 'system.shortcut', shortcut: 'mission-control', key: 'up' }),
    false,
  );
});

test('a desktop action cancels queued motion and releases a local drag once before dispatch', () => {
  const f = fixture();
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  f.input.enqueue({ name: 'pointer.move', x: 20, y: 10 });
  sendDesktopAction(available, 'next-space', f.input, f.cancelPad);
  assert.deepEqual(f.sent, [
    { name: 'pointer.button.down', button: 'left' },
    { name: 'pointer.button.up', button: 'left' },
    { name: 'system.shortcut', shortcut: 'next-space' },
  ]);
  assert.deepEqual(f.input.heldButtons, []);
  assert.equal(f.cancelled(), 1);
  f.input.flush();
  assert.equal(f.sent.length, 3);
});

test('desktop dispatch does not wait for media acknowledgements or replay on reconnect', () => {
  const f = fixture();
  f.input.enqueue({
    name: 'media.control',
    mediaRequest: { targetId: 'iina:fixture', action: 'setVolume', value: 1.2 },
  });
  sendDesktopAction(available, 'app-expose', f.input, () => {});
  assert.deepEqual(
    f.sent.map((command) => command.name),
    ['media.control', 'system.shortcut'],
  );
  f.input.disconnect();
  f.input.connect((command) => {
    f.sent.push(command);
    return true;
  });
  f.input.flush();
  assert.equal(f.sent.length, 2);
});

test('failed drag release prevents the desktop action and never leaves input held', () => {
  const f = fixture((command) => command.name !== 'pointer.button.up');
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  assert.equal(sendDesktopAction(available, 'mission-control', f.input, f.cancelPad), false);
  assert.equal(
    f.sent.some((command) => command.name === 'system.shortcut'),
    false,
  );
  assert.deepEqual(f.input.heldButtons, []);
  assert.equal(f.failure(), 1);
});
