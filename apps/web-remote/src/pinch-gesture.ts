export type MagnifyFrame = Readonly<{
  id: string;
  kind: 'magnify';
  phase: 'began' | 'changed' | 'ended' | 'cancelled';
  value: number;
  timestamp: number;
}>;

/** Match RemoteGestureFrame's closed wire shape and native numeric bounds. */
export function validMagnifyFrame(frame: MagnifyFrame): boolean {
  return (
    typeof frame === 'object' &&
    frame !== null &&
    Object.keys(frame).sort().join(',') === 'id,kind,phase,timestamp,value' &&
    typeof frame.id === 'string' &&
    /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i.test(frame.id) &&
    frame.kind === 'magnify' &&
    ['began', 'changed', 'ended', 'cancelled'].includes(frame.phase) &&
    Number.isFinite(frame.value) &&
    Math.abs(frame.value) <= 4 &&
    Number.isFinite(frame.timestamp) &&
    frame.timestamp >= 0 &&
    frame.timestamp <= 1_000_000_000 &&
    (frame.phase !== 'began' || frame.value === 0)
  );
}
