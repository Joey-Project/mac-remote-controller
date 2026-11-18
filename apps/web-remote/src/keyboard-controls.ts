export type RemoteKey =
  | 'return'
  | 'escape'
  | 'backspace'
  | 'space'
  | 'left'
  | 'right'
  | 'up'
  | 'down'
  | 'tab'
  | 'forward-delete'
  | 'home'
  | 'end'
  | 'page-up'
  | 'page-down';
export type KeyboardShortcut =
  'copy' | 'cut' | 'paste' | 'select-all' | 'undo' | 'redo' | 'find' | 'previous-field';
export type KeyboardCommand =
  | Readonly<{ name: 'keyboard.key'; key: RemoteKey }>
  | Readonly<{ name: 'keyboard.shortcut'; keyboardShortcut: KeyboardShortcut }>;

const LEGACY_KEYS = new Set<unknown>([
  'return',
  'escape',
  'backspace',
  'space',
  'left',
  'right',
  'up',
  'down',
]);
const EXTENDED_KEYS = new Set<unknown>([
  'tab',
  'forward-delete',
  'home',
  'end',
  'page-up',
  'page-down',
]);
const SHORTCUTS = new Set<unknown>([
  'copy',
  'cut',
  'paste',
  'select-all',
  'undo',
  'redo',
  'find',
  'previous-field',
]);

export function isRemoteKey(value: unknown): value is RemoteKey {
  return LEGACY_KEYS.has(value) || EXTENDED_KEYS.has(value);
}
export function isKeyboardShortcut(value: unknown): value is KeyboardShortcut {
  return SHORTCUTS.has(value);
}
export function requiresKeyboardControls(command: KeyboardCommand): boolean {
  return command.name === 'keyboard.shortcut' || EXTENDED_KEYS.has(command.key);
}
export function keyboardKeyCommand(value: unknown, extended: boolean): KeyboardCommand | null {
  return isRemoteKey(value) && (extended || LEGACY_KEYS.has(value))
    ? { name: 'keyboard.key', key: value }
    : null;
}
export function keyboardShortcutCommand(value: unknown, extended: boolean): KeyboardCommand | null {
  return extended && isKeyboardShortcut(value)
    ? { name: 'keyboard.shortcut', keyboardShortcut: value }
    : null;
}
