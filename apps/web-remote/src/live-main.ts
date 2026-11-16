import './live.css';
import { RemoteInputBuffer, type RemoteKey } from './remote-input.js';
import { LiveTouchpad } from './live-touchpad.js';
import { WebRemoteConnection, type WebRemoteState } from './web-connection.js';
import { WebRemoteLifecycle } from './web-lifecycle.js';
import { normalizeWheelDeltaY, shouldHandleWindowShortcut } from './preview-model.js';

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error('The remote interface could not be loaded.');
  return value as T;
}

const surface = element<HTMLElement>('touch-surface');
const controls = element<HTMLElement>('controls');
const statusLabel = element<HTMLElement>('status');
const errorLabel = element<HTMLElement>('error');
const nameLabel = element<HTMLElement>('mac-name');
const volume = element<HTMLElement>('volume');
const volumeRange = element<HTMLInputElement>('volume-range');
const volumeValue = element<HTMLOutputElement>('volume-value');
const showVolume = element<HTMLInputElement>('show-volume');
const touchpadPanel = element<HTMLElement>('touchpad-panel');
const keyboardPanel = element<HTMLElement>('keyboard-panel');
const touchpadMode = element<HTMLButtonElement>('touchpad-mode');
const keyboardMode = element<HTMLButtonElement>('keyboard-mode');
const textInput = element<HTMLTextAreaElement>('text-input');
const sendText = element<HTMLButtonElement>('send-text-button');
const pairing = element<HTMLElement>('pairing');
const confirmForm = element<HTMLFormElement>('confirm-pairing');
const codeInput = element<HTMLInputElement>('pairing-code');
const menu = element<HTMLDetailsElement>('menu');
const captures = new Set<number>();
let keyboard = false;
let connected = false;
let requestID: string | null = null;
const lifecycle = new WebRemoteLifecycle();

const input = new RemoteInputBuffer(
  {
    request: (callback) => requestAnimationFrame(callback),
    cancel: (id) => cancelAnimationFrame(id),
  },
  () => connection.fail(),
);
const pad = new LiveTouchpad((command) => input.enqueue(command));
const connection = new WebRemoteConnection({
  origin: location.origin,
  input,
  active: () => !document.hidden,
  onStatus(status) {
    lifecycle.update(status);
    connected = status === 'connected';
    controls.inert = !connected;
    pairing.hidden = !lifecycle.showPairing;
    controls.hidden = !lifecycle.showControls;
    statusLabel.textContent = {
      disconnected: 'Disconnected',
      connecting: 'Connecting…',
      connected: 'Connected',
      pairing: 'Pair this browser',
      reconnecting: 'Reconnecting…',
    }[status];
    if (!connected) {
      pad.cancel();
      sendText.disabled = false;
    } else {
      requestID = null;
      codeInput.value = '';
      confirmForm.hidden = true;
      clearError();
    }
  },
  onState(state) {
    renderState(state);
  },
  onError(message) {
    showError(message);
  },
  onResult(command, error) {
    if (error && command.name.startsWith('pointer.')) cancelPad();
    if (command.name !== 'keyboard.text') return;
    sendText.disabled = false;
    if (!error && textInput.value === command.text) textInput.value = '';
  },
});

function showError(message: string): void {
  errorLabel.textContent = message;
  errorLabel.hidden = false;
}
function clearError(): void {
  errorLabel.textContent = '';
  errorLabel.hidden = true;
}
function renderState(state: WebRemoteState): void {
  nameLabel.textContent = state.deviceName;
  volumeRange.disabled = state.systemVolume === null;
  if (state.systemVolume !== null) {
    volumeRange.value = String(Math.round(state.systemVolume * 100));
    volumeValue.value = `${Math.round(state.systemVolume * 100)}%`;
  } else volumeValue.value = 'Unavailable';
  surface.setAttribute('aria-disabled', String(!state.accessibilityGranted));
  if (!state.accessibilityGranted)
    showError('Allow Accessibility in the Mac companion for pointer and keyboard control.');
}

function cancelPad(): void {
  pad.cancel();
  input.cancelGesture();
  for (const id of captures) if (surface.hasPointerCapture(id)) surface.releasePointerCapture(id);
  captures.clear();
}

function selectMode(value: boolean): void {
  cancelPad();
  keyboard = value;
  keyboardPanel.hidden = !keyboard;
  touchpadPanel.hidden = keyboard;
  touchpadMode.setAttribute('aria-pressed', String(!keyboard));
  keyboardMode.setAttribute('aria-pressed', String(keyboard));
  touchpadMode.classList.toggle('selected', !keyboard);
  keyboardMode.classList.toggle('selected', keyboard);
  volume.hidden = !keyboard && !showVolume.checked;
}
touchpadMode.addEventListener('click', () => selectMode(false));
keyboardMode.addEventListener('click', () => selectMode(true));
showVolume.addEventListener('change', () => {
  volume.hidden = !keyboard && !showVolume.checked;
  menu.open = false;
});

surface.addEventListener('pointerdown', (event) => {
  if (
    !connected ||
    event.button !== 0 ||
    !pad.begin(event.pointerId, { x: event.clientX, y: event.clientY }, event.timeStamp)
  )
    return;
  event.preventDefault();
  surface.focus({ preventScroll: true });
  surface.setPointerCapture(event.pointerId);
  captures.add(event.pointerId);
});
surface.addEventListener('pointermove', (event) => {
  pad.move(event.pointerId, { x: event.clientX, y: event.clientY });
});
surface.addEventListener('pointerup', (event) => {
  pad.move(event.pointerId, { x: event.clientX, y: event.clientY });
  pad.end(event.pointerId, event.timeStamp);
  captures.delete(event.pointerId);
  if (surface.hasPointerCapture(event.pointerId)) surface.releasePointerCapture(event.pointerId);
});
surface.addEventListener('pointercancel', cancelPad);
surface.addEventListener('lostpointercapture', (event) => {
  if (pad.has(event.pointerId)) cancelPad();
});
surface.addEventListener('contextmenu', (event) => event.preventDefault());
surface.addEventListener(
  'wheel',
  (event) => {
    if (!connected) return;
    const y = normalizeWheelDeltaY(
      event.deltaY,
      event.deltaMode,
      24,
      surface.clientHeight,
      event.ctrlKey,
    );
    const x = normalizeWheelDeltaY(
      event.deltaX,
      event.deltaMode,
      24,
      surface.clientWidth,
      event.ctrlKey,
    );
    if (x === null || y === null) return;
    event.preventDefault();
    input.enqueue({ name: 'pointer.scroll', x: -x, y: -y });
  },
  { passive: false },
);

document.querySelectorAll<HTMLButtonElement>('[data-button]').forEach((button) => {
  button.addEventListener('click', () => {
    const value = button.dataset['button'];
    if (value === 'left' || value === 'right')
      input.enqueue({ name: 'pointer.click', button: value });
  });
});
document.querySelectorAll<HTMLButtonElement>('[data-key]').forEach((button) => {
  button.addEventListener('click', () =>
    input.enqueue({ name: 'keyboard.key', key: button.dataset['key'] as RemoteKey }),
  );
});
const keys: Readonly<Record<string, RemoteKey>> = {
  ArrowLeft: 'left',
  ArrowRight: 'right',
  ArrowUp: 'up',
  ArrowDown: 'down',
  Enter: 'return',
  Escape: 'escape',
  Backspace: 'backspace',
  ' ': 'space',
};
window.addEventListener('keydown', (event) => {
  const target =
    event.target instanceof Element &&
    event.target.closest('button, input, textarea, summary, a, [contenteditable]');
  if (
    !connected ||
    !shouldHandleWindowShortcut(event.key, target ? 'control' : 'page', event) ||
    event.repeat
  )
    return;
  const key = keys[event.key];
  if (key && input.enqueue({ name: 'keyboard.key', key })) event.preventDefault();
});
volumeRange.addEventListener('input', () => {
  volumeValue.value = `${volumeRange.value}%`;
  input.enqueue({ name: 'system.volume.set', value: Number(volumeRange.value) / 100 });
});
element<HTMLFormElement>('send-text').addEventListener('submit', (event) => {
  event.preventDefault();
  if (new TextEncoder().encode(textInput.value).length > 4096) {
    showError('Send at most 4096 bytes of text at a time.');
    return;
  }
  if (input.enqueue({ name: 'keyboard.text', text: textInput.value })) sendText.disabled = true;
});
element<HTMLFormElement>('start-pairing').addEventListener('submit', (event) => {
  event.preventDefault();
  clearError();
  const button = element<HTMLFormElement>('start-pairing').querySelector('button');
  if (button) button.disabled = true;
  void connection
    .beginPairing(element<HTMLInputElement>('browser-name').value)
    .then((id) => {
      requestID = id;
      confirmForm.hidden = false;
      codeInput.value = '';
      codeInput.focus();
    })
    .catch((error: unknown) =>
      showError(error instanceof Error ? error.message : 'Pairing failed.'),
    )
    .finally(() => {
      if (button) button.disabled = false;
    });
});
confirmForm.addEventListener('submit', (event) => {
  event.preventDefault();
  if (!requestID) return;
  const button = confirmForm.querySelector('button');
  if (button) button.disabled = true;
  void connection
    .confirmPairing(requestID, codeInput.value)
    .catch((error: unknown) => {
      codeInput.value = '';
      showError(error instanceof Error ? error.message : 'Pairing failed.');
    })
    .finally(() => {
      if (button) button.disabled = false;
    });
});
element<HTMLButtonElement>('connect').addEventListener('click', () => {
  menu.open = false;
  clearError();
  void connection.connect();
});
element<HTMLButtonElement>('disconnect').addEventListener('click', () => {
  menu.open = false;
  lifecycle.stop();
  connection.disconnect();
});
element<HTMLButtonElement>('forget').addEventListener('click', () => {
  menu.open = false;
  void connection
    .forget()
    .catch(() => showError('Could not forget pairing. Try again when the Mac is available.'));
});
document.addEventListener('visibilitychange', () => {
  cancelPad();
  if (document.hidden) {
    lifecycle.suspend();
    connection.disconnect();
  } else if (lifecycle.resume()) {
    void connection.connect();
  }
});
window.addEventListener('pagehide', () => {
  cancelPad();
  lifecycle.suspend();
  connection.disconnect();
});
window.addEventListener('pageshow', () => {
  if (!document.hidden && lifecycle.resume()) {
    void connection.connect();
  }
});
window.addEventListener('blur', cancelPad);
function resize(): void {
  document.documentElement.style.setProperty(
    '--viewport-height',
    `${window.visualViewport?.height ?? innerHeight}px`,
  );
  cancelPad();
}
window.visualViewport?.addEventListener('resize', resize);
window.addEventListener('resize', resize);
resize();
void connection.connect();
