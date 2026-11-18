import type { InputCommand, PointerButton } from './remote-input.js';
import type { MagnifyFrame } from './pinch-gesture.js';
import { clientTapTimestamp, reportsPressure, type FeedbackKind } from './touch-feedback.js';

type Point = Readonly<{ x: number; y: number }>;
type Touch = { start: Point; last: Point };

/** Relative input only: the browser never receives a screen image or cursor position. */
export class LiveTouchpad {
  private readonly points = new Map<number, Touch>();
  private phase: 'point' | 'two' | 'scroll' | 'magnify' | 'drag' | 'settling' = 'point';
  private beganAt = 0;
  private maximumTouches = 0;
  private tapPossible = false;
  private dragging = false;
  private dragX = 0;
  private dragY = 0;
  private magnificationEnabled = false;
  private threeFingerDragEnabled = true;
  private gesture: MagnifyFrame | null = null;
  private twoPending = false;
  private initialSpan = 0;
  private initialCenter: Point = { x: 0, y: 0 };
  private previousCenter: Point = { x: 0, y: 0 };
  private at = 0;
  private forceClickEnabled = true;
  private pressureKnown = false;

  constructor(
    private readonly emit: (command: InputCommand) => boolean,
    private readonly requestFrame: () => void = () => {},
    private readonly feedback: (kind: FeedbackKind) => void = () => {},
    private readonly pressureDetected: () => void = () => {},
  ) {}

  setForceClickEnabled(enabled: boolean): void {
    if (enabled === this.forceClickEnabled) return;
    this.forceClickEnabled = enabled;
    if (this.points.size) this.cancel();
  }

  setMagnificationEnabled(enabled: boolean): void {
    if (enabled === this.magnificationEnabled) return;
    this.magnificationEnabled = enabled;
    if (this.points.size === 0) return;
    this.finishMagnify('cancelled');
    this.releaseDrag();
    this.twoPending = false;
    this.tapPossible = false;
    this.phase = 'settling';
  }

  setThreeFingerDragEnabled(enabled: boolean): void {
    if (enabled === this.threeFingerDragEnabled) return;
    this.threeFingerDragEnabled = enabled;
    if (this.points.size === 0) return;
    this.finishMagnify('cancelled');
    this.releaseDrag();
    this.twoPending = false;
    this.tapPossible = false;
    this.phase = 'settling';
  }

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
    this.at = Math.max(this.at, at);
    this.maximumTouches = Math.max(this.maximumTouches, this.points.size);
    if (this.phase === 'settling') {
      this.tapPossible = false;
      return true;
    }
    if (this.points.size === 2) {
      this.phase = this.magnificationEnabled ? 'two' : 'scroll';
      const geometry = this.geometry();
      this.initialSpan = geometry.span;
      this.initialCenter = geometry.center;
      this.previousCenter = geometry.center;
    }
    if (this.points.size === 3) {
      const pinching = this.gesture !== null;
      this.finishMagnify('cancelled');
      this.phase = pinching || !this.threeFingerDragEnabled ? 'settling' : 'drag';
      this.twoPending = false;
      this.tapPossible = false;
    }
    if (this.points.size === 4) {
      this.phase = 'settling';
      this.tapPossible = false;
      this.releaseDrag();
      this.finishMagnify('cancelled');
      this.twoPending = false;
    }
    return true;
  }

  move(id: number, point: Point, at = performance.now(), pressure?: number): boolean {
    const touch = this.points.get(id);
    if (!touch || !validPoint(point) || !Number.isFinite(at) || at < 0) return false;
    this.at = Math.max(this.at, at);
    const x = point.x - touch.last.x;
    const y = point.y - touch.last.y;
    touch.last = point;
    if (reportsPressure(pressure)) {
      if (!this.pressureKnown) {
        this.pressureKnown = true;
        this.pressureDetected();
      }
      if (
        this.forceClickEnabled &&
        this.phase === 'point' &&
        this.points.size === 1 &&
        pressure >= 0.78
      ) {
        this.tapPossible = false;
        this.phase = 'settling';
        if ((x || y) && !this.emit({ name: 'pointer.move', x: x * 1.5, y: y * 1.5 })) return false;
        return this.emitTap('left', at, 'pressure');
      }
    }
    if (Math.hypot(point.x - touch.start.x, point.y - touch.start.y) > 8) this.tapPossible = false;
    switch (this.phase) {
      case 'point':
        return this.emit({ name: 'pointer.move', x: x * 1.5, y: y * 1.5 });
      case 'scroll':
      case 'two':
      case 'magnify':
        this.twoPending = true;
        this.requestFrame();
        return true;
      case 'drag':
        if (this.dragging) return this.emit({ name: 'pointer.move', x: x / 2, y: y / 2 });
        this.dragX += x / 2;
        this.dragY += y / 2;
        if (Math.hypot(this.dragX, this.dragY) < 4) return true;
        this.dragging = this.emit({ name: 'pointer.button.down', button: 'left' });
        if (this.dragging) this.feedback('drag');
        return this.dragging && this.emit({ name: 'pointer.move', x: this.dragX, y: this.dragY });
      case 'settling':
        return true;
    }
  }

  /** Pointer events arrive per contact; classify their shared frame, not each half-update. */
  flush(): void {
    if (!this.twoPending || this.points.size !== 2) return;
    this.twoPending = false;
    const { span, center } = this.geometry();
    if (!Number.isFinite(span)) {
      this.cancel();
      return;
    }
    if (this.phase === 'two') {
      const pan = Math.hypot(center.x - this.initialCenter.x, center.y - this.initialCenter.y);
      const separation = Math.abs(span - this.initialSpan);
      // Same thresholds as native TwoFingerGesturePolicy; keep the selected kind until lift.
      if (Math.max(this.initialSpan, span) >= 8 && separation >= 7 && separation > pan * 1.25) {
        this.phase = 'magnify';
        this.tapPossible = false;
        this.gesture = {
          id: crypto.randomUUID(),
          kind: 'magnify',
          phase: 'began',
          value: 0,
          timestamp: this.at / 1000,
        };
        if (!this.emit({ name: 'gesture.frame', gesture: this.gesture })) {
          this.gesture = null;
          this.phase = 'settling';
          return;
        }
      } else if (pan >= 7 && pan > separation * 0.8) {
        this.phase = 'scroll';
        this.tapPossible = false;
      } else return;
    }
    if (this.phase === 'magnify') {
      const value = this.magnification(span);
      if (this.gesture && value !== this.gesture.value) {
        this.gesture = { ...this.gesture, phase: 'changed', value, timestamp: this.at / 1000 };
        if (!this.emit({ name: 'gesture.frame', gesture: this.gesture })) {
          this.gesture = null;
          this.phase = 'settling';
        }
      }
    } else if (this.phase === 'scroll') {
      const x = center.x - this.previousCenter.x;
      const y = center.y - this.previousCenter.y;
      if (x || y) this.emit({ name: 'pointer.scroll', x, y });
    }
    this.previousCenter = center;
  }

  end(id: number, at: number, point?: Point): void {
    if (!this.points.has(id)) return;
    if (point && validPoint(point)) {
      if (this.phase === 'magnify') this.points.get(id)!.last = point;
      else this.move(id, point, at);
    }
    if (Number.isFinite(at) && at >= 0) this.at = Math.max(this.at, at);
    if (this.phase !== 'magnify') this.flush();
    if (this.gesture) this.finishMagnify('ended', this.magnification(this.geometry().span));
    this.twoPending = false;
    if (!this.points.delete(id)) return;
    if (this.dragging) this.releaseDrag();
    this.phase = 'settling';
    if (this.points.size !== 0) return;
    if (this.tapPossible && Number.isFinite(at) && at >= this.beganAt && at - this.beganAt <= 500) {
      this.emitTap(this.maximumTouches === 2 ? 'right' : 'left', at, 'tap');
    }
    this.tapPossible = false;
  }

  cancel(): void {
    this.finishMagnify('cancelled');
    this.twoPending = false;
    this.releaseDrag();
    this.points.clear();
    this.tapPossible = false;
    this.phase = 'settling';
  }

  private geometry(): { span: number; center: Point } {
    const [a, b] = this.points.values();
    if (!a || !b) return { span: 0, center: { x: 0, y: 0 } };
    return {
      span: Math.hypot(b.last.x - a.last.x, b.last.y - a.last.y),
      center: { x: a.last.x / 2 + b.last.x / 2, y: a.last.y / 2 + b.last.y / 2 },
    };
  }

  private emitTap(button: PointerButton, at: number, feedback: FeedbackKind): boolean {
    const timestamp = clientTapTimestamp(at);
    if (
      !this.emit({
        name: 'pointer.click',
        button,
        ...(timestamp === null ? {} : { tapTimestamp: timestamp }),
      })
    )
      return false;
    this.feedback(feedback);
    return true;
  }

  private magnification(span: number): number {
    return Math.min(4, Math.max(-4, Math.log(Math.max(8, span) / Math.max(8, this.initialSpan))));
  }

  private finishMagnify(phase: 'ended' | 'cancelled', value = this.gesture?.value ?? 0): void {
    const gesture = this.gesture;
    this.gesture = null;
    if (gesture)
      this.emit({
        name: 'gesture.frame',
        gesture: { ...gesture, phase, value, timestamp: this.at / 1000 },
      });
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
