export interface SnapshotInput {
  targetId: string;
  title: string;
  idle: boolean;
  position: number | null;
  duration: number | null;
  mpvVolumePercent: number;
  maximumMpvPercent: number;
  muted: boolean;
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

export function gainRatioFromMpvPercent(value: number): number | null {
  if (!Number.isFinite(value) || value < 0) return null;
  const ratio = value / 100;
  return Number.isFinite(ratio) ? ratio : null;
}

export function mpvPercentFromGainRatio(value: number, maximumMpvPercent: number): number | null {
  const maximumGainRatio = gainRatioFromMpvPercent(maximumMpvPercent);
  if (
    maximumGainRatio === null ||
    maximumMpvPercent <= 0 ||
    !Number.isFinite(value) ||
    value < 0 ||
    value > maximumGainRatio
  ) {
    return null;
  }
  if (value === maximumGainRatio) return maximumMpvPercent;
  const mpvPercent = value * 100;
  return Number.isFinite(mpvPercent) && mpvPercent <= maximumMpvPercent ? mpvPercent : null;
}

export function iinaFormData(value: Record<string, unknown>): { payload: string } {
  return { payload: JSON.stringify(value) };
}

/**
 * Build a per-window routing label without browser cryptography APIs. This is
 * an identifier, not an authentication token; bridge authentication uses the
 * separate companion-issued token.
 */
export function createTargetID(nowMilliseconds = Date.now(), random = Math.random): string {
  const randomPart = (): string => Math.floor(random() * 0x1_0000_0000).toString(36);
  return `iina:${Math.floor(nowMilliseconds).toString(36)}-${randomPart()}-${randomPart()}`;
}

export function canNavigatePlaylist(
  action: 'next' | 'previous',
  playlistCount: number,
  playlistPosition: number,
): boolean {
  if (
    !Number.isInteger(playlistCount) ||
    playlistCount < 2 ||
    !Number.isInteger(playlistPosition) ||
    playlistPosition < 0 ||
    playlistPosition >= playlistCount
  ) {
    return false;
  }
  return action === 'next' ? playlistPosition < playlistCount - 1 : playlistPosition > 0;
}

export function effectiveMpvVolumePercent(value: number, muted: boolean): number | null {
  if (muted) return 0;
  return Number.isFinite(value) && value >= 0 ? value : null;
}

export function shouldUnmuteForGainRatio(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

export function targetSnapshot(input: SnapshotInput): IINATargetSnapshot {
  const title = input.title.trim() || 'IINA';
  const maximum = gainRatioFromMpvPercent(input.maximumMpvPercent);
  const maximumGainRatio = maximum !== null && maximum > 0 ? maximum : null;
  const effectiveVolume = effectiveMpvVolumePercent(input.mpvVolumePercent, input.muted);
  const volume = effectiveVolume === null ? null : gainRatioFromMpvPercent(effectiveVolume);
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
        playerVolumeMaximum: maximumGainRatio,
      },
      playerVolume:
        maximumGainRatio !== null &&
        volume !== null &&
        input.mpvVolumePercent <= input.maximumMpvPercent
          ? volume
          : null,
    },
    volume,
    position:
      input.position !== null && Number.isFinite(input.position) && input.position >= 0
        ? input.position
        : null,
  };
}

function truncateUTF8(value: string, maximum: number): string {
  let result = '';
  let byteCount = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0)!;
    const characterBytes =
      codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
    if (byteCount + characterBytes > maximum) break;
    result += character;
    byteCount += characterBytes;
  }
  return result;
}

export function validateAction(
  action: string,
  value: number | undefined,
  maximumMpvPercent: number,
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
      if (typeof value !== 'number' || mpvPercentFromGainRatio(value, maximumMpvPercent) === null) {
        throw new Error('Volume is outside the current IINA player range.');
      }
      return;
    default:
      throw new Error('Unsupported media action.');
  }
}
