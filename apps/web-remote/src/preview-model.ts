export type PadPoint = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type PreviewSnapshot = Readonly<{
  cursorX: number;
  cursorY: number;
  leftClicks: number;
  rightClicks: number;
  scrollDelta: number;
  volume: number;
  lastAction: string;
  lastKey: string;
  keyPresses: number;
}>;

export type TextCountUnit = 'characters' | 'Unicode code points';
export type TextCount = Readonly<{ count: number; unit: TextCountUnit }>;

export type WindowShortcutTarget = 'page' | 'control';

type ActivePointer = {
  id: number;
  startX: number;
  startY: number;
  lastX: number;
  lastY: number;
  width: number;
  height: number;
  moved: boolean;
};

const ALLOWED_KEYS = new Set([
  'return',
  'escape',
  'backspace',
  'space',
  'left',
  'right',
  'up',
  'down',
]);
const TAP_DISTANCE = 8;
const WINDOW_SHORTCUT_KEYS = new Set([
  'ArrowLeft',
  'ArrowRight',
  'ArrowUp',
  'ArrowDown',
  'Enter',
  'Escape',
  'Backspace',
  ' ',
]);
const DEFAULT_GRAPHEME_SEGMENTER =
  typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
    : null;

export function shouldHandleWindowShortcut(key: string, target: WindowShortcutTarget): boolean {
  return target === 'page' && WINDOW_SHORTCUT_KEYS.has(key);
}

export function formatScrollDelta(delta: number): string {
  if (!Number.isFinite(delta) || delta === 0) return 'No scroll yet';
  return `${delta > 0 ? 'Down' : 'Up'} · ${Math.round(Math.abs(delta))}`;
}

export function countTextCharacters(
  text: string,
  segmenter: Intl.Segmenter | null = DEFAULT_GRAPHEME_SEGMENTER,
): TextCount {
  if (segmenter) {
    return { count: Array.from(segmenter.segment(text)).length, unit: 'characters' };
  }
  return { count: Array.from(text).length, unit: 'Unicode code points' };
}

export class OfflinePreviewModel {
  private readonly pointers = new Map<number, ActivePointer>();
  private gestureMode: 'single' | 'scroll' | 'settling' | null = null;
  private primaryPointerID: number | null = null;
  private cursorX = 50;
  private cursorY = 50;
  private leftClicks = 0;
  private rightClicks = 0;
  private scrollDelta = 0;
  private volume = 0.5;
  private lastAction = 'Ready · offline';
  private lastKey = 'None';
  private keyPresses = 0;

  get snapshot(): PreviewSnapshot {
    return {
      cursorX: this.cursorX,
      cursorY: this.cursorY,
      leftClicks: this.leftClicks,
      rightClicks: this.rightClicks,
      scrollDelta: this.scrollDelta,
      volume: this.volume,
      lastAction: this.lastAction,
      lastKey: this.lastKey,
      keyPresses: this.keyPresses,
    };
  }

  beginPointer(id: number, point: PadPoint): boolean {
    if (
      !Number.isFinite(id) ||
      this.gestureMode === 'settling' ||
      this.pointers.size >= 2 ||
      this.pointers.has(id) ||
      !this.validPoint(point)
    ) {
      return false;
    }

    const active: ActivePointer = {
      id,
      startX: point.x,
      startY: point.y,
      lastX: point.x,
      lastY: point.y,
      width: point.width,
      height: point.height,
      moved: false,
    };

    if (this.pointers.size === 0) {
      this.gestureMode = 'single';
      this.primaryPointerID = id;
      this.lastAction = 'Touch started · local preview';
    } else {
      this.gestureMode = 'scroll';
      this.primaryPointerID = null;
      for (const pointer of this.pointers.values()) pointer.moved = true;
      active.moved = true;
      this.lastAction = 'Two-finger scroll started · local preview';
    }
    this.pointers.set(id, active);
    return true;
  }

  movePointer(id: number, point: PadPoint): boolean {
    const active = this.pointers.get(id);
    if (!active || !this.validPoint(point) || this.gestureMode === 'settling') return false;

    if (this.gestureMode === 'scroll') {
      const deltaY = (point.y - active.lastY) / 2;
      active.lastX = point.x;
      active.lastY = point.y;
      this.scrollDelta = this.clamp(this.scrollDelta + deltaY, -10000, 10000);
      this.lastAction = 'Two-finger scroll changed · local preview';
      return true;
    }
    if (this.gestureMode !== 'single' || this.primaryPointerID !== id) return false;

    const deltaX = point.x - active.lastX;
    const deltaY = point.y - active.lastY;
    this.cursorX = this.clamp(this.cursorX + (deltaX / active.width) * 120, 0, 100);
    this.cursorY = this.clamp(this.cursorY + (deltaY / active.height) * 120, 0, 100);
    active.lastX = point.x;
    active.lastY = point.y;
    active.moved ||= Math.hypot(point.x - active.startX, point.y - active.startY) >= TAP_DISTANCE;
    this.lastAction = 'Cursor moved · local preview';
    return true;
  }

  endPointer(id: number): 'tap' | 'drag' | 'scroll' | null {
    const active = this.pointers.get(id);
    if (!active) return null;

    if (this.gestureMode === 'scroll') {
      this.pointers.delete(id);
      this.gestureMode = 'settling';
      this.lastAction = 'Two-finger scroll ended · local preview';
      return 'scroll';
    }

    if (this.gestureMode === 'settling') {
      this.pointers.delete(id);
      if (this.pointers.size === 0) this.gestureMode = null;
      return null;
    }

    if (this.gestureMode !== 'single' || this.primaryPointerID !== id) return null;
    this.pointers.clear();
    this.gestureMode = null;
    this.primaryPointerID = null;
    if (active.moved) {
      this.lastAction = 'Drag ended · local preview';
      return 'drag';
    }
    this.leftClicks += 1;
    this.lastAction = 'Tap recorded · local preview';
    return 'tap';
  }

  cancelPointer(id?: number): boolean {
    if (this.pointers.size === 0 || (id !== undefined && !this.pointers.has(id))) return false;
    this.pointers.clear();
    this.gestureMode = null;
    this.primaryPointerID = null;
    this.lastAction = 'Gesture cancelled · local preview';
    return true;
  }

  recordClick(button: 'left' | 'right'): void {
    if (button === 'left') this.leftClicks += 1;
    else this.rightClicks += 1;
    this.lastAction = `${button === 'left' ? 'Left' : 'Right'} click · local preview`;
  }

  recordScroll(deltaY: number): boolean {
    if (!Number.isFinite(deltaY)) return false;
    this.scrollDelta = this.clamp(this.scrollDelta + deltaY, -10000, 10000);
    this.lastAction = 'Scroll changed · local preview';
    return true;
  }

  setVolume(value: number): boolean {
    if (!Number.isFinite(value) || value < 0 || value > 1) return false;
    this.volume = value;
    this.lastAction = 'Volume slider changed · local preview';
    return true;
  }

  pressKey(key: string): boolean {
    if (!ALLOWED_KEYS.has(key)) return false;
    this.lastKey = key;
    this.keyPresses += 1;
    this.lastAction = 'Key recorded · local preview';
    return true;
  }

  private validPoint(point: PadPoint): boolean {
    return (
      Number.isFinite(point.x) &&
      Number.isFinite(point.y) &&
      Number.isFinite(point.width) &&
      Number.isFinite(point.height) &&
      point.width > 0 &&
      point.height > 0
    );
  }

  private clamp(value: number, minimum: number, maximum: number): number {
    return Math.min(maximum, Math.max(minimum, value));
  }
}
