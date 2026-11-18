export type FeedbackKind = 'tap' | 'drag' | 'pressure';

/** The protocol uses seconds on the client's monotonic event timeline. */
export function clientTapTimestamp(milliseconds: number): number | null {
  return Number.isFinite(milliseconds) && milliseconds >= 0 && milliseconds <= 1_000_000_000_000
    ? milliseconds / 1000
    : null;
}

/** Pointer Events mandates 0.5/0 for devices without pressure support. */
export function reportsPressure(value: number | undefined): value is number {
  return (
    typeof value === 'number' && Number.isFinite(value) && value > 0 && value <= 1 && value !== 0.5
  );
}

/** Best-effort opt-in local vibration; rejection never affects remote input. */
export class TouchFeedback {
  private enabled = false;
  private refused = false;

  constructor(
    private readonly vibrate: ((milliseconds: number) => boolean) | null,
    private readonly changed: () => void = () => {},
  ) {}

  get available(): boolean {
    return this.vibrate !== null;
  }
  get notice(): string {
    return !this.available
      ? 'This browser does not provide vibration feedback. Standard taps remain available.'
      : this.refused
        ? 'This browser did not provide vibration. Taps and dragging still work; toggle feedback off and on to retry.'
        : 'Short local vibration when supported by this browser and device.';
  }

  setEnabled(enabled: boolean): void {
    if (enabled === this.enabled) return;
    this.enabled = enabled;
    this.refused = false;
  }

  pulse(kind: FeedbackKind): void {
    if (!this.enabled || !this.vibrate || this.refused) return;
    try {
      if (this.vibrate(kind === 'pressure' ? 20 : 10)) return;
    } catch {
      // Browser policy or hardware can refuse vibration even with an exposed API.
    }
    this.refused = true;
    this.changed();
  }
}
