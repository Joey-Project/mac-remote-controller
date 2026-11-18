import assert from 'node:assert/strict';
import test from 'node:test';
import {
  allowsSessionAction,
  visibleSessionActions,
  SessionControlsModel,
} from '../dist/session-controls.js';
import { RemoteInputBuffer } from '../dist/remote-input.js';

const capabilities = ['sessionLock.v1', 'sessionUnlock.v1', 'displayPower.v1'];
const awake = { capabilities, sessionLocked: false, unlockAvailable: true, displayAsleep: false };
const actions = [
  'session.lock',
  'session.unlock',
  'display.off',
  'display.wake',
  'session.lock-display-off',
];

for (const [name, fields, allowed, visible] of [
  [
    'unlocked and awake',
    {},
    ['session.lock', 'display.off', 'session.lock-display-off'],
    ['session.lock', 'display.off', 'session.lock-display-off'],
  ],
  [
    'locked and awake',
    { sessionLocked: true },
    ['session.unlock', 'display.off', 'session.lock-display-off'],
    ['session.unlock', 'display.off', 'session.lock-display-off'],
  ],
  [
    'locked and dark',
    { sessionLocked: true, displayAsleep: true },
    ['session.unlock', 'display.wake'],
    ['session.unlock', 'display.wake', 'session.lock-display-off'],
  ],
  [
    'unlocked and dark',
    { displayAsleep: true },
    ['session.lock', 'display.wake', 'session.lock-display-off'],
    ['session.lock', 'display.wake', 'session.lock-display-off'],
  ],
  [
    'unlock permission denied',
    { sessionLocked: true, unlockAvailable: false },
    ['display.off', 'session.lock-display-off'],
    ['session.unlock', 'display.off', 'session.lock-display-off'],
  ],
  [
    'unknown login state',
    { sessionLocked: null },
    [],
    ['session.lock', 'display.off', 'session.lock-display-off'],
  ],
  [
    'unknown display state',
    { sessionLocked: true, displayAsleep: null },
    ['session.unlock'],
    ['session.unlock', 'display.off', 'session.lock-display-off'],
  ],
  [
    'unknown unlock permission',
    { sessionLocked: true, unlockAvailable: null },
    ['display.off', 'session.lock-display-off'],
    ['session.unlock', 'display.off', 'session.lock-display-off'],
  ],
  ['old companion', { capabilities: [] }, [], []],
  [
    'display-only companion',
    { capabilities: ['displayPower.v1'], displayAsleep: true },
    ['display.wake'],
    ['display.wake'],
  ],
  [
    'unlock-only companion already unlocked',
    { capabilities: ['sessionUnlock.v1'] },
    [],
    ['session.unlock'],
  ],
  ['unknown future capability', { capabilities: ['future.v1'] }, [], []],
])
  test(`session menu follows native policy: ${name}`, () => {
    const state = { ...awake, ...fields };
    assert.deepEqual(
      actions.filter((action) => allowsSessionAction(action, state)),
      allowed,
    );
    assert.deepEqual(visibleSessionActions(state), visible);
  });

function fixture() {
  const model = new SessionControlsModel();
  const sent = [];
  const frames = new Map();
  let next = 0;
  let cancellations = 0;
  const input = new RemoteInputBuffer(
    {
      request(callback) {
        frames.set(++next, callback);
        return next;
      },
      cancel(id) {
        frames.delete(id);
      },
    },
    () => model.setConnected(false),
  );
  input.connect((command) => {
    sent.push(command);
    return true;
  });
  const send = (action) =>
    model.send(action, input, () => {
      cancellations += 1;
    });
  return { model, input, sent, frames, send, cancellations: () => cancellations };
}

test('controls require a fresh state and connection, then respect permission changes', () => {
  const f = fixture();
  assert.equal(f.send('session.lock'), false);
  f.model.update(awake);
  assert.equal(f.send('session.lock'), false);
  f.model.setConnected(true);
  f.model.update({ ...awake, sessionLocked: true, unlockAvailable: false });
  assert.equal(f.send('session.unlock'), false);
  assert.equal(f.send('system.sleep'), false);
  assert.equal(f.cancellations(), 0);
  assert.deepEqual(f.sent, []);
  f.model.update({ ...awake, sessionLocked: true });
  assert.equal(f.send('session.unlock'), true);
});

test('a session action releases a held drag and discards motion before its single send', () => {
  const f = fixture();
  f.model.update(awake);
  f.model.setConnected(true);
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  f.input.enqueue({ name: 'pointer.move', x: 50, y: 20 });
  assert.equal(f.send('session.lock'), true);
  assert.equal(f.cancellations(), 1);
  assert.equal(f.frames.size, 0);
  assert.deepEqual(f.sent, [
    { name: 'pointer.button.down', button: 'left' },
    { name: 'pointer.button.up', button: 'left' },
    { name: 'session.lock' },
  ]);
});

test('one session operation is allowed while ordinary input stays immediate', () => {
  const f = fixture();
  f.model.update(awake);
  f.model.setConnected(true);
  assert.equal(f.send('session.lock'), true);
  assert.equal(f.send('session.lock'), false);
  assert.equal(f.send('display.off'), false);
  f.model.update({ ...awake, sessionLocked: true });
  assert.equal(f.send('session.unlock'), false);
  assert.equal(f.input.enqueue({ name: 'keyboard.key', key: 'escape' }), true);
  f.model.complete('display.off');
  assert.equal(f.model.pending, 'session.lock');
  f.model.complete('session.lock');
  assert.equal(f.send('session.unlock'), true);
  assert.deepEqual(
    f.sent.map((command) => command.name),
    ['session.lock', 'keyboard.key', 'session.unlock'],
  );
});

test('failed delivery clears busy state and reconnect never replays a session action', () => {
  const f = fixture();
  f.model.update(awake);
  f.model.setConnected(true);
  let attempts = 0;
  f.input.connect(() => {
    attempts += 1;
    return false;
  });
  assert.equal(f.send('session.lock'), false);
  assert.equal(f.model.pending, null);
  assert.equal(attempts, 1);
  f.input.connect((command) => {
    f.sent.push(command);
    return true;
  });
  f.model.setConnected(true);
  assert.equal(f.send('session.lock'), false, 'new welcome state is required');
  f.model.update(awake);
  assert.equal(f.send('display.off'), true);
  f.model.setConnected(false);
  f.model.setConnected(true);
  assert.equal(f.model.pending, null);
  assert.deepEqual(visibleSessionActions(f.model.state), []);
  assert.deepEqual(f.sent, [{ name: 'display.off' }]);
});
