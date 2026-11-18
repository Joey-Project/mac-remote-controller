import assert from 'node:assert/strict';
import test from 'node:test';
import { LiveTouchpad } from '../dist/live-touchpad.js';

function fixture() {
  const commands = [];
  const pad = new LiveTouchpad((command) => {
    commands.push(command);
    return true;
  });
  return { pad, commands };
}

test('two stationary fingers emit one right click after both have lifted', () => {
  const { pad, commands } = fixture();
  pad.begin(1, { x: 10, y: 10 }, 0);
  pad.begin(2, { x: 20, y: 10 }, 10);
  pad.end(1, 80);
  assert.deepEqual(commands, []);
  pad.end(2, 90);
  assert.deepEqual(commands, [{ name: 'pointer.click', button: 'right' }]);
});

test('two-finger scroll preserves centroid displacement without moving the cursor', () => {
  const { pad, commands } = fixture();
  pad.begin(1, { x: 10, y: 10 }, 0);
  pad.begin(2, { x: 20, y: 10 }, 1);
  pad.move(1, { x: 10, y: 30 });
  pad.move(2, { x: 20, y: 30 });
  pad.end(1, 100);
  pad.end(2, 110);
  assert(commands.every((command) => command.name === 'pointer.scroll'));
  assert.equal(
    commands.reduce((sum, command) => sum + command.y, 0),
    20,
  );
});

test('three-finger drag has ordered down/move/up and no trailing pointer motion', () => {
  const { pad, commands } = fixture();
  for (let id = 1; id <= 3; id += 1) pad.begin(id, { x: id * 10, y: 10 }, id);
  pad.move(1, { x: 22, y: 10 });
  pad.end(1, 50);
  pad.move(2, { x: 50, y: 10 });
  pad.end(2, 60);
  pad.end(3, 70);
  assert.deepEqual(
    commands.map((command) => command.name),
    ['pointer.button.down', 'pointer.move', 'pointer.button.up'],
  );
});

test('a fourth finger and page cancellation release a drag at most once', () => {
  const { pad, commands } = fixture();
  for (let id = 1; id <= 3; id += 1) pad.begin(id, { x: id * 10, y: 10 }, id);
  pad.move(1, { x: 22, y: 10 });
  pad.begin(4, { x: 40, y: 10 }, 20);
  pad.cancel();
  pad.cancel();
  assert.equal(commands.filter((command) => command.name === 'pointer.button.up').length, 1);
});

test('late taps and mixed contacts after a lift never become accidental clicks', () => {
  const { pad, commands } = fixture();
  pad.begin(1, { x: 10, y: 10 }, 0);
  pad.end(1, 501);
  pad.begin(1, { x: 10, y: 10 }, 1000);
  pad.begin(2, { x: 20, y: 10 }, 1001);
  pad.end(1, 1020);
  pad.begin(3, { x: 30, y: 10 }, 1030);
  pad.end(2, 1040);
  pad.end(3, 1050);
  assert.deepEqual(commands, []);
});

function pinchFixture(emit) {
  const commands = [];
  let requested = 0;
  const pad = new LiveTouchpad(
    (command) => {
      commands.push(command);
      return emit?.(command) ?? true;
    },
    () => {
      requested += 1;
    },
  );
  pad.setMagnificationEnabled(true);
  pad.begin(1, { x: 100, y: 100 }, 1);
  pad.begin(2, { x: 200, y: 100 }, 2);
  return { pad, commands, requested: () => requested };
}

test('pinch uses one cumulative identity and includes the final lifted location', () => {
  const { pad, commands } = pinchFixture();
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  assert.deepEqual(commands, [], 'classify both contacts together');
  pad.flush();
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began', 'changed'],
  );
  assert.equal(commands[1].gesture.value, Math.log(1.2));
  pad.end(1, 20, { x: 80, y: 100 });
  pad.move(2, { x: 250, y: 100 }, 21);
  pad.end(2, 22);
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began', 'changed', 'ended'],
  );
  assert.equal(commands[2].gesture.value, Math.log(1.3));
  assert.equal(new Set(commands.map((c) => c.gesture.id)).size, 1);
  assert(commands.every((c) => c.name === 'gesture.frame' && c.gesture.kind === 'magnify'));
  assert.deepEqual(
    commands.map((c) => c.gesture.timestamp),
    [0.011, 0.011, 0.02],
  );
});

test('staggered per-pointer pan samples become scrolling, never false pinch', () => {
  const { pad, commands } = pinchFixture();
  pad.move(1, { x: 120, y: 100 }, 10);
  pad.move(2, { x: 220, y: 100 }, 11);
  pad.flush();
  assert.deepEqual(commands, [{ name: 'pointer.scroll', x: 20, y: 0 }]);
  // Once scrolling wins, later separation changes cannot switch the same sequence.
  pad.move(1, { x: 80, y: 100 }, 20);
  pad.move(2, { x: 260, y: 100 }, 21);
  pad.flush();
  pad.end(1, 30);
  pad.end(2, 31);
  assert(commands.every((c) => c.name === 'pointer.scroll'));
});

test('pinch stays magnification during later translation and cancels on a third finger', () => {
  const { pad, commands } = pinchFixture();
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  pad.flush();
  pad.move(1, { x: 130, y: 120 }, 20);
  pad.move(2, { x: 250, y: 120 }, 21);
  pad.flush();
  pad.begin(3, { x: 180, y: 120 }, 30);
  pad.move(3, { x: 220, y: 120 }, 31);
  for (const id of [1, 2, 3]) pad.end(id, 40 + id);
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began', 'changed', 'cancelled'],
  );
  assert(commands.every((c) => c.name === 'gesture.frame'));
});

test('losing permission/capability cancels once and ignores remaining fingers until lift', () => {
  const { pad, commands } = pinchFixture();
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  pad.flush();
  pad.setMagnificationEnabled(false);
  pad.setMagnificationEnabled(false);
  pad.begin(3, { x: 180, y: 100 }, 20);
  pad.move(3, { x: 200, y: 100 }, 21);
  pad.flush();
  for (const id of [1, 2, 3]) pad.end(id, 30 + id);
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began', 'changed', 'cancelled'],
  );
});

test('a rejected pinch begin never sends changes, clicks or a new drag', () => {
  const { pad, commands } = pinchFixture(() => false);
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  pad.flush();
  pad.begin(3, { x: 180, y: 100 }, 20);
  pad.move(3, { x: 250, y: 100 }, 21);
  pad.flush();
  for (const id of [1, 2, 3]) pad.end(id, 30 + id);
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began'],
  );
});

test('page/mode cancellation discards the pending sample and is idempotent', () => {
  const { pad, commands } = pinchFixture();
  pad.move(1, { x: 90, y: 100 }, 10);
  pad.move(2, { x: 210, y: 100 }, 11);
  pad.flush();
  pad.move(1, { x: 50, y: 100 }, 20);
  pad.cancel();
  pad.cancel();
  pad.flush();
  assert.deepEqual(
    commands.map((c) => c.gesture.phase),
    ['began', 'changed', 'cancelled'],
  );
  assert.equal(commands.at(-1).gesture.value, Math.log(1.2));
});

test('older companions retain scrolling and right tap without phased commands', () => {
  const { pad, commands } = fixture();
  pad.begin(1, { x: 100, y: 100 }, 1);
  pad.begin(2, { x: 200, y: 100 }, 2);
  pad.move(1, { x: 100, y: 120 }, 10);
  pad.move(2, { x: 200, y: 120 }, 11);
  pad.flush();
  pad.end(1, 20);
  pad.end(2, 21);
  assert.deepEqual(commands, [{ name: 'pointer.scroll', x: 0, y: 20 }]);
});
