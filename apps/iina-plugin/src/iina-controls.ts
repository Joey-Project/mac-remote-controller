export interface SnapshotInput {
  targetId: string;
  title: string;
  idle: boolean;
  position: number | null;
  duration: number | null;
  volume: number;
  maximumVolume: number;
  playlistCount: number;
  playlistPosition: number;
}

export interface IINATargetSnapshot {
  target: {
    id: string;
    name: string;
    kind: 'iina';
    capabilities: {
      playPause: boolean;
      seek: boolean;
      next: boolean;
      previous: boolean;
      playerVolumeMaximum: number | null;
    };
    playerVolume: number | null;
  };
  volume: number | null;
  position: number | null;
}

export function targetSnapshot(input: SnapshotInput): IINATargetSnapshot {
  const title = input.title.trim() || 'IINA';
  const maximum =
    Number.isFinite(input.maximumVolume) && input.maximumVolume > 0 ? input.maximumVolume : null;
  const hasFile = !input.idle;
  return {
    target: {
      id: input.targetId,
      name: truncateUTF8(`IINA · ${title}`, 256),
      kind: 'iina',
      capabilities: {
        playPause: hasFile,
        seek: hasFile && input.duration !== null && Number.isFinite(input.duration),
        next:
          hasFile &&
          Number.isInteger(input.playlistPosition) &&
          input.playlistPosition >= 0 &&
          input.playlistPosition < input.playlistCount - 1,
        previous:
          hasFile &&
          Number.isInteger(input.playlistPosition) &&
          input.playlistPosition > 0 &&
          input.playlistPosition < input.playlistCount,
        playerVolumeMaximum: maximum,
      },
      playerVolume:
        maximum !== null &&
        Number.isFinite(input.volume) &&
        input.volume >= 0 &&
        input.volume <= maximum
          ? input.volume
          : null,
    },
    volume: Number.isFinite(input.volume) && input.volume >= 0 ? input.volume : null,
    position:
      input.position !== null && Number.isFinite(input.position) && input.position >= 0
        ? input.position
        : null,
  };
}

function truncateUTF8(value: string, maximum: number): string {
  let result = '';
  for (const character of value) {
    if (new TextEncoder().encode(result + character).byteLength > maximum) break;
    result += character;
  }
  return result;
}

export function validateAction(
  action: string,
  value: number | undefined,
  maximumVolume: number,
): void {
  switch (action) {
    case 'playPause':
    case 'next':
    case 'previous':
      if (value !== undefined) throw new Error('This action does not take a value.');
      return;
    case 'seek':
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        value === 0 ||
        Math.abs(value) > 3_600
      ) {
        throw new Error('Seek must be a finite nonzero interval of at most one hour.');
      }
      return;
    case 'setVolume':
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        value < 0 ||
        value > maximumVolume
      ) {
        throw new Error('Volume is outside the current IINA player range.');
      }
      return;
    default:
      throw new Error('Unsupported media action.');
  }
}
