import assert from 'node:assert/strict';
import test from 'node:test';
import { OfflinePreviewModel } from '../dist/preview-model.js';

const point = (x, y, width = 100, height = 100) => ({ x, y, width, height });

test('one pointer controls the local cursor until it ends', () => {
  const model = new OfflinePreviewModel();

  assert.equal(model.beginPointer(11, point(10, 10)), true);
  assert.equal(model.movePointer(12, point(80, 80)), false);
  assert.equal(model.movePointer(11, point(60, 30)), true);
  assert.equal(model.endPointer(11), 'drag');
  assert.equal(model.beginPointer(12, point(20, 20)), true);
  assert.equal(model.endPointer(12), 'tap');
});

test('a second pointer switches to scroll and cannot be counted as a tap', () => {
  const model = new OfflinePreviewModel();

  assert.equal(model.beginPointer(21, point(30, 40)), true);
  assert.equal(model.beginPointer(22, point(60, 40)), true);
  assert.equal(model.beginPointer(23, point(75, 40)), false);
  assert.equal(model.movePointer(21, point(30, 60)), true);
  assert.equal(model.snapshot.scrollDelta, 10);
  assert.equal(model.endPointer(22), 'scroll');
  assert.equal(model.movePointer(21, point(30, 80)), false);
  assert.equal(model.endPointer(21), null);
  assert.equal(model.snapshot.leftClicks, 0);
});

test('a short tap records one local click while a drag records none', () => {
  const model = new OfflinePreviewModel();

  assert.equal(model.beginPointer(1, point(20, 20)), true);
  assert.equal(model.movePointer(1, point(23, 24)), true);
  assert.equal(model.endPointer(1), 'tap');
  assert.equal(model.snapshot.leftClicks, 1);

  assert.equal(model.beginPointer(2, point(20, 20)), true);
  assert.equal(model.movePointer(2, point(40, 20)), true);
  assert.equal(model.endPointer(2), 'drag');
  assert.equal(model.snapshot.leftClicks, 1);
});

test('cancel clears pointer ownership without recording a tap', () => {
  const model = new OfflinePreviewModel();

  assert.equal(model.beginPointer(5, point(30, 30)), true);
  assert.equal(model.cancelPointer(6), false);
  assert.equal(model.cancelPointer(5), true);
  assert.equal(model.endPointer(5), null);
  assert.equal(model.snapshot.leftClicks, 0);
  assert.equal(model.beginPointer(6, point(30, 30)), true);
  assert.equal(model.cancelPointer(), true);
});

test('preview controls reject invalid values and keep the cursor bounded', () => {
  const model = new OfflinePreviewModel();

  assert.equal(model.beginPointer(2, point(50, 50)), true);
  assert.equal(model.movePointer(2, point(500, -500)), true);
  assert.equal(model.snapshot.cursorX, 100);
  assert.equal(model.snapshot.cursorY, 0);
  assert.equal(model.endPointer(2), 'drag');

  assert.equal(model.setVolume(0.75), true);
  assert.equal(model.setVolume(Number.NaN), false);
  assert.equal(model.setVolume(1.01), false);
  assert.equal(model.recordScroll(30), true);
  assert.equal(model.recordScroll(Number.POSITIVE_INFINITY), false);
  assert.equal(model.pressKey('left'), true);
  assert.equal(model.pressKey('delete-all'), false);
});
