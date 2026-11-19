import assert from 'node:assert/strict';
import test from 'node:test';
import { clientTapTimestamp, reportsPressure, TouchFeedback } from '../dist/touch-feedback.js';
import { entryMode } from '../dist/entry-points.js';

test('client timing uses seconds and rejects values outside the native wire range', () => {
  assert.equal(clientTapTimestamp(321), 0.321);
  assert.equal(clientTapTimestamp(0), 0);
  assert.equal(clientTapTimestamp(1_000_000_000_000), 1_000_000_000);
  for (const value of [NaN, Infinity, -1, 1_000_000_000_001, '10', null])
    assert.equal(clientTapTimestamp(value), null);
});

test('pressure support cannot be inferred from the standard unsupported 0.5/0 defaults', () => {
  for (const value of [0, 0.5, NaN, Infinity, -1, 1.1, '1', undefined, null])
    assert.equal(reportsPressure(value), false);
  for (const value of [0.1, 0.78, 1]) assert.equal(reportsPressure(value), true);
});

test('feedback is opt-in, local and bounded to a short tap or pressure pulse', () => {
  const calls = [];
  const feedback = new TouchFeedback((milliseconds) => {
    calls.push(milliseconds);
    return true;
  });
  feedback.pulse('tap');
  assert.deepEqual(calls, []);
  feedback.setEnabled(true);
  for (const kind of ['tap', 'drag', 'pressure']) feedback.pulse(kind);
  assert.deepEqual(calls, [10, 10, 20]);
  feedback.setEnabled(false);
  feedback.pulse('tap');
  assert.equal(calls.length, 3);
});

test('missing or refused vibration never throws or retries during later touches', () => {
  const missing = new TouchFeedback(null);
  missing.setEnabled(true);
  missing.pulse('tap');
  assert.equal(missing.available, false);
  assert.match(missing.notice, /does not provide/);
  for (const mode of ['false', 'throw']) {
    let calls = 0;
    let warnings = 0;
    const feedback = new TouchFeedback(
      () => {
        calls++;
        if (mode === 'throw') throw new Error('Browser policy');
        return false;
      },
      () => warnings++,
    );
    feedback.setEnabled(true);
    feedback.pulse('tap');
    feedback.pulse('drag');
    assert.equal(calls, 1);
    assert.equal(warnings, 1);
    assert.match(feedback.notice, /still work/);
    feedback.setEnabled(false);
    feedback.setEnabled(true);
    feedback.pulse('tap');
    assert.equal(calls, 2);
  }
});

test('entry links select only a remote mode and cannot encode remote actions or credentials', () => {
  assert.equal(entryMode('#keyboard'), 'keyboard');
  assert.equal(entryMode('#touchpad'), 'touchpad');
  for (const hash of [
    '',
    '#unlock',
    '#keyboard?unlock=true',
    '#keyboard&token=x',
    '#Keyboard',
    '#https://other.test',
  ])
    assert.equal(entryMode(hash), null);
});
