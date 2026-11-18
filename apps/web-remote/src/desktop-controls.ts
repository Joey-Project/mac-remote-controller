import type { RemoteInputBuffer } from './remote-input.js';

export type SystemShortcut = 'previous-space' | 'mission-control' | 'app-expose' | 'next-space';
export type DesktopAvailability = Readonly<{
  connected: boolean;
  supportsGestures: boolean;
  accessibilityGranted: boolean;
}>;
const SHORTCUTS = new Set(['previous-space', 'mission-control', 'app-expose', 'next-space']);

export function isSystemShortcut(value: unknown): value is SystemShortcut {
  return typeof value === 'string' && SHORTCUTS.has(value);
}
export function desktopActionsAvailable(state: DesktopAvailability): boolean {
  return state.connected && state.supportsGestures && state.accessibilityGranted;
}

/** Finish local held input before one explicit native action; never replay it. */
export function sendDesktopAction(
  state: DesktopAvailability,
  shortcut: unknown,
  input: RemoteInputBuffer,
  cancelPad: () => void,
): boolean {
  if (!desktopActionsAvailable(state) || !isSystemShortcut(shortcut)) return false;
  input.cancelGesture();
  cancelPad();
  return input.enqueue({ name: 'system.shortcut', shortcut });
}
