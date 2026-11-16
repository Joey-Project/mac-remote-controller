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
