import './live.css';
import { RemoteInputBuffer, type RemoteKey } from './remote-input.js';
import { LiveTouchpad } from './live-touchpad.js';
import { LiveControlPanels } from './live-controls.js';
import { LiveSessionControls } from './live-session.js';
import { LiveSettings } from './live-settings.js';
import { LiveKeyboardControls } from './live-keyboard.js';
import { LiveConnectionDetails } from './live-connection.js';
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
const settingsPanel = element<HTMLElement>('settings-panel');
const connectionPanel = element<HTMLElement>('connection-panel');
const captures = new Set<number>();
let keyboard = false;
let connected = false;
let settingsOpen = false;
let connectionOpen = false;
let magnificationAvailable = false;
let threeFingerDragEnabled = true;
let requestID: string | null = null;
const lifecycle = new WebRemoteLifecycle();

const input = new RemoteInputBuffer(
  {
    request: (callback) => requestAnimationFrame(callback),
    cancel: (id) => cancelAnimationFrame(id),
  },
  () => connection.fail(),
  () => pad.flush(),
);
const pad = new LiveTouchpad(
  (command) => input.enqueue(command),
  () => input.requestFlush(),
);
const panels = new LiveControlPanels(input, cancelPad);
const sessionControls = new LiveSessionControls(input, cancelPad, menu);
const keyboardControls = new LiveKeyboardControls((command) => input.enqueue(command), cancelPad);
const connectionDetails = new LiveConnectionDetails((signal) => connection.probe(signal));
new LiveSettings((value) => {
  threeFingerDragEnabled = value.threeFingerDrag;
  pad.setThreeFingerDragEnabled(value.threeFingerDrag);
  panels.setSeekInterval(value.seekSeconds);
  renderTouchHint();
});
const connection = new WebRemoteConnection({
  origin: location.origin,
  input,
  active: () => !document.hidden,
  onStatus(status) {
    lifecycle.update(status);
    connected = status === 'connected';
    panels.setConnected(connected);
    sessionControls.setConnected(connected);
    keyboardControls.setConnected(connected);
    connectionDetails.updateStatus(status);
    renderScreen();
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
    panels.complete(command, error);
    sessionControls.complete(command);
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
function renderScreen(): void {
  settingsPanel.hidden = !settingsOpen;
  connectionPanel.hidden = !connectionOpen;
  const pageOpen = settingsOpen || connectionOpen;
  controls.inert = !connected || pageOpen;
  pairing.hidden = pageOpen || !lifecycle.showPairing;
  controls.hidden = pageOpen || !lifecycle.showControls;
}
function renderState(state: WebRemoteState): void {
  nameLabel.textContent = state.deviceName;
  element<HTMLElement>('open-connection').setAttribute(
    'aria-label',
    `Connection details for ${state.deviceName}`,
  );
  panels.update(state);
  sessionControls.update(state);
  keyboardControls.update(state);
  connectionDetails.update(state);
  const canMagnify =
    state.accessibilityGranted &&
    state.supportsGestures &&
    state.capabilities.includes('simulatedGestures.v1');
  magnificationAvailable = canMagnify;
  pad.setMagnificationEnabled(canMagnify);
  renderTouchHint();
  surface.setAttribute('aria-disabled', String(!state.accessibilityGranted));
  if (!state.accessibilityGranted)
    showError('Allow Accessibility in the Mac companion for pointer and keyboard control.');
}
function renderTouchHint(): void {
  element<HTMLElement>('two-finger-hint').textContent = magnificationAvailable
    ? 'Two fingers to scroll, pinch or right-click'
    : 'Two fingers to scroll or tap for right click';
  element<HTMLElement>('three-finger-hint').textContent = threeFingerDragEnabled
    ? 'Three fingers to drag'
    : 'Three-finger drag is off';
  surface.setAttribute(
    'aria-label',
    `Mac touchpad: one finger moves, two fingers ${magnificationAvailable ? 'scroll, pinch or tap for right click' : 'scroll or tap for right click'}, ${threeFingerDragEnabled ? 'three fingers drag' : 'three-finger drag is off'}`,
  );
}

function cancelPad(): void {
  pad.cancel();
  input.cancelGesture();
  for (const id of captures) if (surface.hasPointerCapture(id)) surface.releasePointerCapture(id);
  captures.clear();
}

function selectMode(value: boolean): void {
  cancelPad();
  settingsOpen = false;
  connectionOpen = false;
  connectionDetails.leave();
  renderScreen();
  keyboard = value;
  keyboardPanel.hidden = !keyboard;
  touchpadPanel.hidden = keyboard;
  touchpadMode.setAttribute('aria-pressed', String(!keyboard));
  keyboardMode.setAttribute('aria-pressed', String(keyboard));
  touchpadMode.classList.toggle('selected', !keyboard);
  keyboardMode.classList.toggle('selected', keyboard);
  panels.setKeyboard(keyboard);
}
touchpadMode.addEventListener('click', () => selectMode(false));
keyboardMode.addEventListener('click', () => selectMode(true));
element<HTMLButtonElement>('open-settings').addEventListener('click', () => {
  cancelPad();
  menu.open = false;
  if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
  settingsOpen = true;
  connectionOpen = false;
  connectionDetails.leave();
  renderScreen();
  element<HTMLElement>('settings-title').focus({ preventScroll: true });
});
element<HTMLButtonElement>('open-connection').addEventListener('click', () => {
  cancelPad();
  menu.open = false;
  if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
  settingsOpen = false;
  connectionOpen = true;
  renderScreen();
  element<HTMLElement>('connection-title').focus({ preventScroll: true });
});
element<HTMLButtonElement>('close-connection').addEventListener('click', () => {
  connectionOpen = false;
  connectionDetails.leave();
  renderScreen();
  element<HTMLElement>('open-connection').focus({ preventScroll: true });
});
element<HTMLButtonElement>('connection-disconnect').addEventListener('click', () => {
  connectionDetails.leave();
  connectionOpen = false;
  lifecycle.stop();
  connection.disconnect();
});
element<HTMLButtonElement>('close-settings').addEventListener('click', () => {
  settingsOpen = false;
  renderScreen();
  menu.querySelector('summary')?.focus({ preventScroll: true });
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
  pad.move(event.pointerId, { x: event.clientX, y: event.clientY }, event.timeStamp);
});
surface.addEventListener('pointerup', (event) => {
  pad.end(event.pointerId, event.timeStamp, { x: event.clientX, y: event.clientY });
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
    event.target.closest('button, input, select, textarea, summary, a, [contenteditable]');
  if (
    !connected ||
    settingsOpen ||
    connectionOpen ||
    !shouldHandleWindowShortcut(event.key, target ? 'control' : 'page', event) ||
    event.repeat
  )
    return;
  const key = keys[event.key];
  if (key && input.enqueue({ name: 'keyboard.key', key })) event.preventDefault();
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
