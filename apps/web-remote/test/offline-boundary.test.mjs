import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const source = await readFile(new URL('../src/main.ts', import.meta.url), 'utf8');
const styles = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');

test('the page clearly identifies itself as offline and not connected', () => {
  assert.match(html, /Offline preview/);
  assert.match(html, /sends\s+no\s+commands/);
  assert.match(html, /Not connected/);
  assert.match(html, /no Mac control connection/);
});

test('the UI has no endpoint, token, password, or certificate fields', () => {
  assert.doesNotMatch(html, /type=["']password["']/i);
  assert.doesNotMatch(html, /(?:wss?|https?):\/\//i);
  assert.doesNotMatch(
    html,
    /<(?:input|textarea)[^>]*(?:endpoint|token|certificate|invitation|pairing)/i,
  );
});

test('the preview has no network, persistent-storage, or Bluetooth API', () => {
  assert.doesNotMatch(source, /\b(?:WebSocket|fetch|XMLHttpRequest|sendBeacon)\b/);
  assert.doesNotMatch(source, /\b(?:localStorage|sessionStorage|indexedDB|caches)\b/);
  assert.doesNotMatch(source, /navigator\s*\.\s*bluetooth/);
  assert.doesNotMatch(styles, /@import|url\s*\(/i);
});

test('the touch surface releases captured gestures on cancel, blur, and page hiding', () => {
  assert.match(source, /setPointerCapture\(event\.pointerId\)/);
  assert.match(source, /addEventListener\(['"]pointercancel['"]/);
  assert.match(source, /addEventListener\(['"]lostpointercapture['"]/);
  assert.match(source, /addEventListener\(['"]blur['"], cancelForInterruption\)/);
  assert.match(source, /addEventListener\(['"]visibilitychange['"]/);
});
