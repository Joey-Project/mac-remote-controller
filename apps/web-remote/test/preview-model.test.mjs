import assert from 'node:assert/strict';
import test from 'node:test';
import {
  OfflinePreviewModel,
  countTextCharacters,
  formatScrollDelta,
  normalizeWheelDeltaY,
  shouldAcceptPointerButton,
  shouldHandleWindowShortcut,
} from '../dist/preview-model.js';

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

test('window shortcuts preserve native activation keys on interactive controls', () => {
  for (const key of ['Enter', ' ']) {
    assert.equal(shouldHandleWindowShortcut(key, 'control'), false);
    assert.equal(shouldHandleWindowShortcut(key, 'page'), true);
  }
  assert.equal(shouldHandleWindowShortcut('ArrowLeft', 'control'), false);
  assert.equal(shouldHandleWindowShortcut('NotAKey', 'page'), false);
  for (const modifiers of [
    { shiftKey: true, altKey: false, ctrlKey: false, metaKey: false },
    { shiftKey: false, altKey: true, ctrlKey: false, metaKey: false },
    { shiftKey: false, altKey: false, ctrlKey: true, metaKey: false },
    { shiftKey: false, altKey: false, ctrlKey: false, metaKey: true },
  ]) {
    assert.equal(shouldHandleWindowShortcut('ArrowLeft', 'page', modifiers), false);
    assert.equal(shouldHandleWindowShortcut('Enter', 'page', modifiers), false);
    assert.equal(shouldHandleWindowShortcut(' ', 'page', modifiers), false);
  }
  assert.equal(
    shouldHandleWindowShortcut(' ', 'page', {
      shiftKey: false,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
    }),
    true,
  );
  assert.equal(
    shouldHandleWindowShortcut('ArrowLeft', 'page', {
      shiftKey: false,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
    }),
    true,
  );
});

test('pointer input accepts the primary button without excluding additional touch pointers', () => {
  assert.equal(shouldAcceptPointerButton(0), true);
  assert.equal(shouldAcceptPointerButton(1), false);
  assert.equal(shouldAcceptPointerButton(2), false);
  assert.equal(shouldAcceptPointerButton(5), false);

  const model = new OfflinePreviewModel();
  assert.equal(shouldAcceptPointerButton(0), true);
  assert.equal(model.beginPointer(1, point(20, 20)), true);
  assert.equal(shouldAcceptPointerButton(0), true);
  assert.equal(model.beginPointer(2, point(40, 20)), true);
  assert.equal(model.endPointer(2), 'scroll');
  assert.equal(model.snapshot.leftClicks, 0);
});

test('wheel deltas normalize pixel, line, and page units into CSS pixels', () => {
  assert.equal(normalizeWheelDeltaY(12, 0, 24, 800), 12);
  assert.equal(normalizeWheelDeltaY(2, 1, 24, 800), 48);
  assert.equal(normalizeWheelDeltaY(-0.5, 2, 24, 800), -400);
  assert.equal(normalizeWheelDeltaY(Number.NaN, 0, 24, 800), null);
  assert.equal(normalizeWheelDeltaY(1, 3, 24, 800), null);
  assert.equal(normalizeWheelDeltaY(1, 1, 0, 800), null);
  assert.equal(normalizeWheelDeltaY(1, 2, 24, Number.POSITIVE_INFINITY), null);
  assert.equal(normalizeWheelDeltaY(Number.MAX_VALUE, 2, 24, 2), null);
});

test('scroll preview formats the accumulated direction and distance', () => {
  const model = new OfflinePreviewModel();
  model.recordScroll(48);
  model.recordScroll(-12);
  assert.equal(model.snapshot.scrollDelta, 36);
  assert.equal(formatScrollDelta(model.snapshot.scrollDelta), 'Down · 36');

  model.recordScroll(-60);
  assert.equal(formatScrollDelta(model.snapshot.scrollDelta), 'Up · 24');
  assert.equal(formatScrollDelta(0), 'No scroll yet');
});

test('text count uses grapheme clusters for emoji and combining marks', () => {
  const result = countTextCharacters('👋👨‍👩‍👧‍👦e\u0301🇬🇧');
  assert.equal(result.count, 4);
  assert.equal(result.unit, 'characters');
});

test('text count labels the Unicode code-point fallback honestly', () => {
  const result = countTextCharacters('👋👨‍👩‍👧‍👦', null);
  assert.equal(result.count, 8);
  assert.equal(result.unit, 'Unicode code points');
});
