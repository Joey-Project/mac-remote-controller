import type { InputCommand } from './remote-input.js';

type Point = Readonly<{ x: number; y: number }>;
type Touch = { start: Point; last: Point };

/** Relative input only: the browser never receives a screen image or cursor position. */
export class LiveTouchpad {
  private readonly points = new Map<number, Touch>();
  private phase: 'point' | 'scroll' | 'drag' | 'settling' = 'point';
  private beganAt = 0;
  private maximumTouches = 0;
  private tapPossible = false;
  private dragging = false;
  private dragX = 0;
  private dragY = 0;

  constructor(private readonly emit: (command: InputCommand) => boolean) {}

  has(id: number): boolean {
    return this.points.has(id);
  }

  begin(id: number, point: Point, at: number): boolean {
    if (
      !Number.isFinite(id) ||
      !validPoint(point) ||
      !Number.isFinite(at) ||
      this.points.has(id) ||
      this.points.size >= 4
    )
      return false;
    if (this.points.size === 0) {
      this.phase = 'point';
      this.beganAt = at;
      this.maximumTouches = 0;
      this.tapPossible = true;
      this.dragX = 0;
      this.dragY = 0;
    }
    this.points.set(id, { start: point, last: point });
    this.maximumTouches = Math.max(this.maximumTouches, this.points.size);
    if (this.phase === 'settling') {
      this.tapPossible = false;
      return true;
    }
    if (this.points.size === 2) this.phase = 'scroll';
    if (this.points.size === 3) {
      this.phase = 'drag';
      this.tapPossible = false;
    }
    if (this.points.size === 4) {
      this.phase = 'settling';
      this.tapPossible = false;
      this.releaseDrag();
    }
    return true;
  }

  move(id: number, point: Point): boolean {
    const touch = this.points.get(id);
    if (!touch || !validPoint(point)) return false;
    const x = point.x - touch.last.x;
    const y = point.y - touch.last.y;
    touch.last = point;
    if (Math.hypot(point.x - touch.start.x, point.y - touch.start.y) > 8) this.tapPossible = false;
    switch (this.phase) {
      case 'point':
        return this.emit({ name: 'pointer.move', x: x * 1.5, y: y * 1.5 });
      case 'scroll':
        return this.emit({ name: 'pointer.scroll', x: x / 2, y: y / 2 });
      case 'drag':
        if (this.dragging) return this.emit({ name: 'pointer.move', x: x / 2, y: y / 2 });
        this.dragX += x / 2;
        this.dragY += y / 2;
        if (Math.hypot(this.dragX, this.dragY) < 4) return true;
        this.dragging = this.emit({ name: 'pointer.button.down', button: 'left' });
        return this.dragging && this.emit({ name: 'pointer.move', x: this.dragX, y: this.dragY });
      case 'settling':
        return true;
    }
  }

  end(id: number, at: number): void {
    if (!this.points.delete(id)) return;
    if (this.dragging) this.releaseDrag();
    this.phase = 'settling';
    if (this.points.size !== 0) return;
    if (this.tapPossible && Number.isFinite(at) && at >= this.beganAt && at - this.beganAt <= 500) {
      this.emit({ name: 'pointer.click', button: this.maximumTouches === 2 ? 'right' : 'left' });
    }
    this.tapPossible = false;
  }

  cancel(): void {
    this.releaseDrag();
    this.points.clear();
    this.tapPossible = false;
    this.phase = 'settling';
  }

  private releaseDrag(): void {
    if (!this.dragging) return;
    this.dragging = false;
    this.emit({ name: 'pointer.button.up', button: 'left' });
  }
}

function validPoint(point: Point): boolean {
  return Number.isFinite(point.x) && Number.isFinite(point.y);
}
