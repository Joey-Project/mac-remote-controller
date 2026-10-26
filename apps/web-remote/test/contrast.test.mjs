import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const css = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');
function luminance(name) {
  const color = css.match(new RegExp(`--${name}:\\s*(#[0-9a-f]{6});`, 'i'))?.[1];
  assert.ok(color, `Missing color ${name}`);
  const channels = [1, 3, 5].map((offset) => {
    const channel = Number.parseInt(color.slice(offset, offset + 2), 16) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

test('small muted instructions retain normal-text contrast on each preview panel', () => {
  const foreground = luminance('muted-2');
  for (const background of ['bg', 'panel', 'panel-2', 'panel-3']) {
    const value = luminance(background);
    const contrast = (Math.max(foreground, value) + 0.05) / (Math.min(foreground, value) + 0.05);
    assert.ok(contrast >= 4.5, `${background} contrast was ${contrast.toFixed(2)}`);
  }
});
