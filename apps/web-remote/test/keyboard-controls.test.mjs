import assert from 'node:assert/strict';
import test from 'node:test';
import { keyboardKeyCommand, keyboardShortcutCommand } from '../dist/keyboard-controls.js';

test('legacy keys remain usable while only new controls need the capability', () => {
  for (const key of ['return', 'escape', 'backspace', 'space', 'left', 'right', 'up', 'down'])
    assert.deepEqual(keyboardKeyCommand(key, false), { name: 'keyboard.key', key });
  for (const key of ['tab', 'forward-delete', 'home', 'end', 'page-up', 'page-down']) {
    assert.equal(keyboardKeyCommand(key, false), null);
    assert.deepEqual(keyboardKeyCommand(key, true), { name: 'keyboard.key', key });
  }
});

test('shortcuts use a fixed one-shot allowlist and never accept modifier state', () => {
  for (const keyboardShortcut of [
    'copy',
    'cut',
    'paste',
    'select-all',
    'undo',
    'redo',
    'find',
    'previous-field',
  ]) {
    assert.equal(keyboardShortcutCommand(keyboardShortcut, false), null);
    assert.deepEqual(keyboardShortcutCommand(keyboardShortcut, true), {
      name: 'keyboard.shortcut',
      keyboardShortcut,
    });
  }
  for (const value of ['command', 'command-down', 'shell.run', 8, null, undefined, ['copy'], {}]) {
    assert.equal(keyboardKeyCommand(value, true), null);
    assert.equal(keyboardShortcutCommand(value, true), null);
  }
});
