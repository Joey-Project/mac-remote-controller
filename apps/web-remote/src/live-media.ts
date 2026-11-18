import { MediaControlsModel, type MediaAction } from './media-model.js';
import { type InputCommand, RemoteInputBuffer } from './remote-input.js';
import type { WebRemoteState } from './web-connection.js';

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error('The media interface could not be loaded.');
  return value as T;
}

/** Media UI updates only on snapshots and deliberate actions, never pointer movement. */
export class LiveMediaControls {
  private readonly model = new MediaControlsModel();
  private readonly overlays = element<HTMLElement>('overlays');
  private readonly controls = element<HTMLElement>('controls');
  private readonly volume = element<HTMLElement>('volume');
  private readonly scope = element<HTMLButtonElement>('volume-scope');
  private readonly range = element<HTMLInputElement>('volume-range');
  private readonly value = element<HTMLOutputElement>('volume-value');
  private readonly media = element<HTMLElement>('media');
  private readonly target = element<HTMLSelectElement>('media-target');
  private readonly availability = element<HTMLElement>('media-availability');
  private readonly showVolume = element<HTMLInputElement>('show-volume');
  private readonly showMedia = element<HTMLInputElement>('show-media');
  private readonly buttons = Array.from(
    document.querySelectorAll<HTMLButtonElement>('[data-media]'),
  );
  private readonly observer: ResizeObserver;
  private connected = false;
  private keyboard = false;
  private playerVolume = false;
  private systemVolume: number | null = null;
  private options = '';

  constructor(
    private readonly input: RemoteInputBuffer,
    cancelPad: () => void,
  ) {
    this.observer = new ResizeObserver(() => {
      const height = this.overlays.getBoundingClientRect().height;
      this.controls.style.setProperty('--overlay-height', `${height > 0 ? height + 20 : 0}px`);
    });
    this.observer.observe(this.overlays);
    for (const toggle of [this.showVolume, this.showMedia]) {
      toggle.addEventListener('change', () => {
        cancelPad();
        element<HTMLDetailsElement>('menu').open = false;
        this.render();
      });
    }
    this.target.addEventListener('change', () => {
      this.input.cancelMediaVolume();
      this.model.select(this.target.value);
      this.render();
    });
    this.scope.addEventListener('click', () => {
      this.input.flush();
      this.playerVolume = !this.playerVolume;
      this.render();
    });
    this.buttons.forEach((button) =>
      button.addEventListener('click', () => {
        if (!this.connected) return;
        const action = button.dataset['media'] as Exclude<MediaAction, 'setVolume'>;
        const seconds = button.dataset['seconds'];
        const command = this.model.control(
          action,
          seconds === undefined ? undefined : Number(seconds),
        );
        if (command) this.input.enqueue(command);
      }),
    );
    this.range.addEventListener('input', () => this.setVolume(Number(this.range.value)));
    this.range.addEventListener('keydown', (event) => {
      if (!this.playerVolume || this.range.disabled) return;
      const current = this.model.volumePercent;
      const maximum = this.model.volumeMaximumPercent;
      if (current === null || maximum === null) return;
      const next = {
        ArrowRight: current + 10,
        ArrowUp: current + 10,
        ArrowLeft: current - 10,
        ArrowDown: current - 10,
        Home: 0,
        End: maximum,
      }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      this.setVolume(next);
    });
    this.render();
  }

  setConnected(connected: boolean): void {
    this.connected = connected;
    if (!connected) {
      this.systemVolume = null;
      this.model.disconnect();
    }
    this.render();
  }
  update(state: WebRemoteState): void {
    this.systemVolume = state.systemVolume;
    if (this.model.update(state.mediaTargets)) this.input.cancelMediaVolume();
    this.render();
  }
  setKeyboard(keyboard: boolean): void {
    this.keyboard = keyboard;
    this.render();
  }
  complete(command: InputCommand, error: string | null): void {
    if (command.name !== 'media.control') return;
    this.model.complete(command, error);
    this.render();
  }
  private setVolume(percent: number): void {
    if (!this.connected) return;
    if (this.playerVolume) {
      const command = this.model.volume(percent);
      if (command && this.input.enqueue(command)) this.model.requested(command);
    } else if (this.systemVolume !== null) {
      if (this.input.enqueue({ name: 'system.volume.set', value: percent / 100 }))
        this.systemVolume = percent / 100;
    }
    this.render();
  }
  private render(): void {
    this.volume.hidden = !this.keyboard && !this.showVolume.checked;
    this.media.hidden = !this.showMedia.checked;
    this.overlays.hidden = this.volume.hidden && this.media.hidden;

    const targets = this.model.targets ?? [];
    const signature = JSON.stringify(targets.map(({ id, name }) => [id, name]));
    if (signature !== this.options) {
      this.options = signature;
      this.target.replaceChildren(
        new Option('Choose player', ''),
        ...targets.map(({ id, name }) => new Option(name, id)),
      );
    }
    this.target.value = this.model.selectedID ?? '';
    this.target.disabled = !this.connected || targets.length === 0;
    this.availability.textContent = !this.connected
      ? 'Connect to your Mac to control media.'
      : this.model.targets === null
        ? 'Media control is unavailable on this Mac.'
        : targets.length === 0
          ? 'Open a supported player on your Mac.'
          : this.model.target
            ? ''
            : 'Choose a player to control.';
    this.availability.hidden = !this.availability.textContent;
    this.buttons.forEach((button) => {
      button.disabled =
        !this.connected || !this.model.supports(button.dataset['media'] as MediaAction);
    });

    const label = this.playerVolume ? 'Player volume' : 'System volume';
    this.scope.textContent = `${label} ⇄`;
    this.scope.setAttribute(
      'aria-label',
      `${label}. Switch to ${this.playerVolume ? 'system' : 'player'} volume`,
    );
    this.scope.disabled =
      !this.connected || (!this.playerVolume && !this.model.supports('setVolume'));
    this.volume.setAttribute('aria-label', label);
    this.range.setAttribute('aria-label', label);
    const maximum = this.playerVolume ? this.model.volumeMaximumPercent : 100;
    const percent = this.playerVolume
      ? this.model.volumePercent
      : this.systemVolume === null
        ? null
        : this.systemVolume * 100;
    this.range.max = String(maximum ?? 100);
    this.range.step = this.playerVolume ? 'any' : '1';
    this.range.disabled = !this.connected || percent === null;
    this.range.value = String(percent ?? 0);
    const display = percent === null ? 'Unavailable' : `${Math.round(percent)}%`;
    this.value.value = display;
    this.range.setAttribute('aria-valuetext', display);
  }
}
