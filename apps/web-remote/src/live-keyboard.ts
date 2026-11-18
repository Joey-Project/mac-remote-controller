import {
  keyboardKeyCommand,
  keyboardShortcutCommand,
  type KeyboardCommand,
} from './keyboard-controls.js';
import type { WebRemoteState } from './web-connection.js';

/** Buttons act on the Mac; drafts and the browser's own shortcuts remain local. */
export class LiveKeyboardControls {
  private connected = false;
  private accessible = false;
  private extended = false;
  private readonly buttons = Array.from(
    document.querySelectorAll<HTMLButtonElement>('[data-key], [data-keyboard-shortcut]'),
  );
  private readonly availability = document.getElementById('keyboard-availability');

  constructor(send: (command: KeyboardCommand) => boolean, cancelPad: () => void) {
    for (const button of this.buttons)
      button.addEventListener('click', () => {
        if (!this.connected || !this.accessible) return;
        const command =
          button.dataset['key'] !== undefined
            ? keyboardKeyCommand(button.dataset['key'], this.extended)
            : keyboardShortcutCommand(button.dataset['keyboardShortcut'], this.extended);
        if (command) {
          cancelPad();
          send(command);
        }
      });
    this.render();
  }
  setConnected(value: boolean): void {
    this.connected = value;
    if (!value) {
      this.accessible = false;
      this.extended = false;
    }
    this.render();
  }
  update(state: WebRemoteState): void {
    this.accessible = state.accessibilityGranted;
    this.extended = state.capabilities.includes('keyboardControls.v1');
    this.render();
  }
  private render(): void {
    for (const button of this.buttons) {
      const command =
        button.dataset['key'] !== undefined
          ? keyboardKeyCommand(button.dataset['key'], this.extended)
          : keyboardShortcutCommand(button.dataset['keyboardShortcut'], this.extended);
      button.disabled = !this.connected || !this.accessible || !command;
    }
    if (this.availability) {
      this.availability.textContent = !this.connected
        ? 'Connect to your Mac to use the keyboard.'
        : !this.accessible
          ? 'Allow Accessibility on your Mac to use the keyboard.'
          : !this.extended
            ? 'Update the Mac companion to use navigation and editing shortcuts.'
            : '';
      this.availability.hidden = !this.availability.textContent;
    }
  }
}
