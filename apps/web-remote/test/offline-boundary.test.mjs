import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const source = await readFile(new URL('../src/main.ts', import.meta.url), 'utf8');
const styles = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');
const model = await readFile(new URL('../src/preview-model.ts', import.meta.url), 'utf8');

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

test('window shortcuts are scoped away from browser-interactive key targets', () => {
  assert.match(source, /shouldHandleWindowShortcut\(\s*event\.key/);
  assert.match(source, /isInteractiveKeyTarget\(event\.target\)/);
  assert.match(source, /altKey: event\.altKey, ctrlKey: event\.ctrlKey, metaKey: event\.metaKey/);
  assert.match(source, /closest\(interactiveKeyTargetSelector\)/);
  assert.match(source, /a\[href\], button, input, select, textarea/);
});

test('the touch surface accepts primary pointer buttons without gating touch primacy', () => {
  assert.match(source, /shouldAcceptPointerButton\(event\.button\)/);
  assert.match(model, /export function shouldAcceptPointerButton\(button: number\)/);
  assert.doesNotMatch(source, /event\.isPrimary/);
});

test('the rendered touchpad preview consumes the accumulated scroll delta', () => {
  assert.match(html, /Scroll distance · CSS px/);
  assert.match(html, /aria-label="Accumulated local scroll preview in CSS pixels"/);
  assert.match(source, /scrollPreview\.textContent = formatScrollDelta\(state\.scrollDelta\)/);
});

test('wheel event units and their CSS-pixel conversion inputs reach the preview model', () => {
  assert.match(source, /normalizeWheelDeltaY\(\s*event\.deltaY,\s*event\.deltaMode,/);
  assert.match(source, /--preview-wheel-line-height/);
  assert.match(source, /document\.documentElement\.clientHeight/);
  assert.match(styles, /--preview-wheel-line-height:\s*24px/);
});

test('the typed-text caption uses grapheme-aware counting and a labeled fallback', () => {
  assert.match(source, /countTextCharacters\(localTextInput\.value\)/);
  assert.match(source, /textCount\.unit/);
  assert.doesNotMatch(source, /localTextInput\.value\.length/);
});
