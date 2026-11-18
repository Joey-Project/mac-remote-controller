import {
  isSessionAction,
  SessionControlsModel,
  visibleSessionActions,
} from './session-controls.js';
import type { InputCommand, RemoteInputBuffer } from './remote-input.js';
import type { WebRemoteState } from './web-connection.js';

export class LiveSessionControls {
  private readonly model = new SessionControlsModel();
  private readonly group = document.querySelector<HTMLElement>('#session-controls')!;
  private readonly guidance = document.querySelector<HTMLElement>('#session-availability')!;
  private readonly buttons = Array.from(
    this.group.querySelectorAll<HTMLButtonElement>('[data-session]'),
  );

  constructor(input: RemoteInputBuffer, cancelPad: () => void, menu: HTMLDetailsElement) {
    for (const button of this.buttons)
      button.addEventListener('click', () => {
        if (this.model.send(button.dataset['session'], input, cancelPad)) menu.open = false;
        this.render();
      });
  }
  setConnected(value: boolean): void {
    this.model.setConnected(value);
    this.render();
  }
  update(state: WebRemoteState): void {
    this.model.update(state);
    this.render();
  }
  complete(command: InputCommand): void {
    if (!isSessionAction(command.name)) return;
    this.model.complete(command.name);
    this.render();
  }
  private render(): void {
    const actions = visibleSessionActions(this.model.state);
    this.group.hidden = actions.length === 0;
    this.group.setAttribute('aria-busy', String(this.model.pending !== null));
    for (const button of this.buttons) {
      const action = button.dataset['session'];
      if (!isSessionAction(action)) continue;
      button.hidden = !actions.includes(action);
      button.disabled = !this.model.allows(action);
      if (action === 'session.unlock')
        button.textContent =
          this.model.state?.sessionLocked === false ? 'Mac unlocked' : 'Unlock Mac';
    }
    const state = this.model.state;
    this.guidance.textContent =
      state?.sessionLocked && actions.includes('session.unlock') && state.unlockAvailable !== true
        ? 'Check Remote unlock setup and allow this browser on the Mac.'
        : state?.sessionLocked === null
          ? 'Waiting for Mac session status.'
          : state?.capabilities.includes('displayPower.v1') && state.displayAsleep === null
            ? 'Waiting for Mac display status.'
            : '';
    this.guidance.hidden = !this.guidance.textContent;
  }
}
