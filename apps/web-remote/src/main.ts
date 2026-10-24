import './styles.css';
import {
  OfflinePreviewModel,
  countTextCharacters,
  formatScrollDelta,
  shouldHandleWindowShortcut,
  type PadPoint,
} from './preview-model.js';

const model = new OfflinePreviewModel();

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`Missing preview element: ${id}`);
  return found as T;
}

const touchpadMode = element<HTMLButtonElement>('touchpad-mode');
const keyboardMode = element<HTMLButtonElement>('keyboard-mode');
const touchpadPanel = element<HTMLElement>('touchpad-panel');
const keyboardPanel = element<HTMLElement>('keyboard-panel');
const touchSurface = element<HTMLElement>('touch-surface');
const cursor = element<HTMLElement>('preview-cursor');
const coordinate = element<HTMLElement>('stage-coordinate');
const leftClickCount = element<HTMLElement>('left-click-count');
const rightClickCount = element<HTMLElement>('right-click-count');
const scrollPreview = element<HTMLElement>('scroll-preview');
const activity = element<HTMLElement>('activity');
const volumeRange = element<HTMLInputElement>('volume-range');
const volumeValue = element<HTMLElement>('volume-value');
const lastKey = element<HTMLElement>('last-key');
const keyCount = element<HTMLElement>('key-count');
const localTextInput = element<HTMLInputElement>('local-text-input');
const textCaption = element<HTMLElement>('text-caption');
const interactiveKeyTargetSelector =
  'a[href], button, input, select, textarea, summary, [role="button"], [role="checkbox"], [role="link"], [role="menuitem"], [role="radio"], [role="slider"], [role="switch"], [role="tab"]';

function isInteractiveKeyTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  return (
    (target instanceof HTMLElement && target.isContentEditable) ||
    target.closest(interactiveKeyTargetSelector) !== null
  );
}

function render(): void {
  const state = model.snapshot;
  cursor.style.left = `${state.cursorX}%`;
  cursor.style.top = `${state.cursorY}%`;
  coordinate.textContent = `${Math.round(state.cursorX)} · ${Math.round(state.cursorY)}`;
  leftClickCount.textContent = String(state.leftClicks);
  rightClickCount.textContent = String(state.rightClicks);
  scrollPreview.textContent = formatScrollDelta(state.scrollDelta);
  activity.textContent = state.lastAction;
  volumeRange.value = String(Math.round(state.volume * 100));
  volumeValue.textContent = `${Math.round(state.volume * 100)}%`;
  lastKey.textContent = state.lastKey;
  keyCount.textContent = `${state.keyPresses} pressed`;
  const textCount = countTextCharacters(localTextInput.value);
  textCaption.textContent = `${textCount.unit} entered in this tab: ${textCount.count}`;
}

function selectMode(mode: 'touchpad' | 'keyboard'): void {
  const keyboardSelected = mode === 'keyboard';
  touchpadPanel.hidden = keyboardSelected;
  keyboardPanel.hidden = !keyboardSelected;
  touchpadMode.setAttribute('aria-pressed', String(!keyboardSelected));
  keyboardMode.setAttribute('aria-pressed', String(keyboardSelected));
  touchpadMode.classList.toggle('is-active', !keyboardSelected);
  keyboardMode.classList.toggle('is-active', keyboardSelected);
}

function localPoint(event: PointerEvent): PadPoint {
  const bounds = touchSurface.getBoundingClientRect();
  return {
    x: event.clientX - bounds.left,
    y: event.clientY - bounds.top,
    width: bounds.width,
    height: bounds.height,
  };
}

touchpadMode.addEventListener('click', () => selectMode('touchpad'));
keyboardMode.addEventListener('click', () => selectMode('keyboard'));

touchSurface.addEventListener('pointerdown', (event: PointerEvent) => {
  if (!model.beginPointer(event.pointerId, localPoint(event))) return;
  touchSurface.setPointerCapture(event.pointerId);
  render();
});

touchSurface.addEventListener('pointermove', (event: PointerEvent) => {
  if (model.movePointer(event.pointerId, localPoint(event))) render();
});

touchSurface.addEventListener('pointerup', (event: PointerEvent) => {
  model.movePointer(event.pointerId, localPoint(event));
  const result = model.endPointer(event.pointerId);
  if (touchSurface.hasPointerCapture(event.pointerId))
    touchSurface.releasePointerCapture(event.pointerId);
  if (result) render();
});

touchSurface.addEventListener('pointercancel', (event: PointerEvent) => {
  if (model.cancelPointer(event.pointerId)) render();
});

touchSurface.addEventListener('lostpointercapture', (event: PointerEvent) => {
  if (model.cancelPointer(event.pointerId)) render();
});

touchSurface.addEventListener(
  'wheel',
  (event: WheelEvent) => {
    event.preventDefault();
    if (model.recordScroll(event.deltaY)) render();
  },
  { passive: false },
);

document.querySelectorAll<HTMLButtonElement>('[data-button]').forEach((button) => {
  button.addEventListener('click', () => {
    const value = button.dataset['button'];
    if (value === 'left' || value === 'right') model.recordClick(value);
    render();
  });
});

document.querySelectorAll<HTMLButtonElement>('[data-key]').forEach((button) => {
  button.addEventListener('click', () => {
    const key = button.dataset['key'];
    if (key) model.pressKey(key);
    render();
  });
});

const keyboardKeys: Readonly<Record<string, string>> = {
  ArrowLeft: 'left',
  ArrowRight: 'right',
  ArrowUp: 'up',
  ArrowDown: 'down',
  Enter: 'return',
  Escape: 'escape',
  Backspace: 'backspace',
  ' ': 'space',
};

window.addEventListener('keydown', (event: KeyboardEvent) => {
  if (
    event.repeat ||
    !shouldHandleWindowShortcut(
      event.key,
      isInteractiveKeyTarget(event.target) ? 'control' : 'page',
    )
  ) {
    return;
  }
  const key = keyboardKeys[event.key];
  if (!key || !model.pressKey(key)) return;
  event.preventDefault();
  render();
});

volumeRange.addEventListener('input', () => {
  model.setVolume(Number(volumeRange.value) / 100);
  render();
});

localTextInput.addEventListener('input', render);

function cancelForInterruption(): void {
  if (model.cancelPointer()) render();
}

window.addEventListener('blur', cancelForInterruption);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) cancelForInterruption();
});

render();
