export type WebRemoteMode = 'touchpad' | 'keyboard';

/** Fragments never reach the gateway or change its strict route/Origin policy. */
export function entryMode(hash: string): WebRemoteMode | null {
  if (hash === '#touchpad') return 'touchpad';
  if (hash === '#keyboard') return 'keyboard';
  return null;
}
