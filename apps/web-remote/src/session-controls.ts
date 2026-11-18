import type { RemoteInputBuffer } from './remote-input.js';

export type SessionAction =
  'session.lock' | 'session.unlock' | 'display.off' | 'display.wake' | 'session.lock-display-off';
export type SessionState = Readonly<{
  capabilities: readonly string[];
  sessionLocked: boolean | null;
  unlockAvailable: boolean | null;
  displayAsleep: boolean | null;
}>;
const ACTIONS = new Set([
  'session.lock',
  'session.unlock',
  'display.off',
  'display.wake',
  'session.lock-display-off',
]);

export function isSessionAction(value: unknown): value is SessionAction {
  return typeof value === 'string' && ACTIONS.has(value);
}

/** Mirrors native SessionControlPolicy; unknown state never means unlocked/awake. */
export function allowsSessionAction(action: SessionAction, state: SessionState): boolean {
  const lock = state.capabilities.includes('sessionLock.v1');
  const display = state.capabilities.includes('displayPower.v1');
  switch (action) {
    case 'session.unlock':
      return (
        state.capabilities.includes('sessionUnlock.v1') &&
        state.sessionLocked === true &&
        state.unlockAvailable === true
      );
    case 'session.lock':
      return lock && state.sessionLocked === false;
    case 'display.off':
      return display && state.sessionLocked !== null && state.displayAsleep === false;
    case 'display.wake':
      return display && state.sessionLocked !== null && state.displayAsleep === true;
    case 'session.lock-display-off':
      return (
        lock &&
        display &&
        state.sessionLocked !== null &&
        state.displayAsleep !== null &&
        !(state.sessionLocked && state.displayAsleep)
      );
  }
}

export function visibleSessionActions(state: SessionState | null): readonly SessionAction[] {
  if (!state) return [];
  const actions: SessionAction[] = [];
  const lock = state.capabilities.includes('sessionLock.v1');
  if (state.sessionLocked === true || !lock) {
    if (state.capabilities.includes('sessionUnlock.v1')) actions.push('session.unlock');
  } else actions.push('session.lock');
  if (state.capabilities.includes('displayPower.v1')) {
    actions.push(state.displayAsleep === true ? 'display.wake' : 'display.off');
    if (lock) actions.push('session.lock-display-off');
  }
  return actions;
}

/** Tracks only explicit menu requests; ordinary input never waits for this model. */
export class SessionControlsModel {
  state: SessionState | null = null;
  pending: SessionAction | null = null;
  private connected = false;

  update(state: SessionState): void {
    this.state = state;
  }
  setConnected(value: boolean): void {
    this.connected = value;
    if (!value) {
      this.state = null;
      this.pending = null;
    }
  }
  allows(action: SessionAction): boolean {
    return (
      this.connected &&
      !this.pending &&
      this.state !== null &&
      allowsSessionAction(action, this.state)
    );
  }
  send(action: unknown, input: RemoteInputBuffer, cancelPad: () => void): boolean {
    if (!isSessionAction(action) || !this.allows(action)) return false;
    this.pending = action;
    input.cancelGesture();
    cancelPad();
    if (input.enqueue({ name: action })) return true;
    this.pending = null;
    return false;
  }
  complete(action: string): void {
    if (this.pending === action) this.pending = null;
  }
}
