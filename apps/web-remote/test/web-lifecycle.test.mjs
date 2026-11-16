import assert from 'node:assert/strict';
import test from 'node:test';
import { WebRemoteLifecycle } from '../dist/web-lifecycle.js';

test('unpaired background/foreground keeps the pairing page and rechecks authorization', () => {
  const lifecycle = new WebRemoteLifecycle();
  lifecycle.update('pairing');
  lifecycle.suspend();
  lifecycle.update('disconnected');
  // pagehide can follow visibilitychange after disconnect already notified UI.
  lifecycle.suspend();
  assert.equal(lifecycle.showPairing, true);
  assert.equal(lifecycle.showControls, false);
  assert.equal(lifecycle.resume(), true);
  lifecycle.update('connecting');
  assert.equal(lifecycle.showPairing, true);
  assert.equal(lifecycle.showControls, false);
  assert.equal(lifecycle.resume(), false, 'pageshow must not duplicate reconnect');
  lifecycle.update('pairing');
  assert.equal(lifecycle.showPairing, true);
  assert.equal(lifecycle.showControls, false);
});

test('paired controls appear only after a new connection is confirmed', () => {
  const lifecycle = new WebRemoteLifecycle();
  assert.equal(lifecycle.showControls, false);
  lifecycle.update('connected');
  assert.equal(lifecycle.showControls, true);
  lifecycle.suspend();
  lifecycle.update('disconnected');
  assert.equal(lifecycle.showControls, false);
  assert.equal(lifecycle.resume(), true);
  lifecycle.update('reconnecting');
  assert.equal(lifecycle.showControls, false);
  lifecycle.update('connected');
  assert.equal(lifecycle.showControls, true);
});

test('an explicit disconnect cancels pending automatic reconnect', () => {
  const lifecycle = new WebRemoteLifecycle();
  lifecycle.update('connected');
  lifecycle.suspend();
  lifecycle.stop();
  lifecycle.update('disconnected');
  lifecycle.suspend();
  assert.equal(lifecycle.resume(), false);
  assert.equal(lifecycle.showControls, false);
});

test('successful pairing replaces the pairing page only after welcome', () => {
  const lifecycle = new WebRemoteLifecycle();
  lifecycle.update('pairing');
  lifecycle.update('connecting');
  assert.equal(lifecycle.showPairing, true);
  assert.equal(lifecycle.showControls, false);
  lifecycle.update('connected');
  assert.equal(lifecycle.showPairing, false);
  assert.equal(lifecycle.showControls, true);
});
