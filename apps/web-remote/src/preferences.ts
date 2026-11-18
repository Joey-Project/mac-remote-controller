export const SEEK_INTERVALS = [5, 10, 15, 30] as const;
export type SeekInterval = (typeof SEEK_INTERVALS)[number];
export type WebPreferences = Readonly<{ seekSeconds: SeekInterval; threeFingerDrag: boolean }>;
export type PreferenceStorage = Pick<Storage, 'getItem' | 'setItem'>;
export const PREFERENCES_KEY = 'sofa-remote.preferences.v1';
const DEFAULTS: WebPreferences = { seekSeconds: 10, threeFingerDrag: true };

export function isSeekInterval(value: unknown): value is SeekInterval {
  return typeof value === 'number' && SEEK_INTERVALS.some((interval) => interval === value);
}

/** Non-secret local preferences only; never read or write a pairing credential. */
export class WebPreferenceStore {
  private current: WebPreferences = { ...DEFAULTS };
  private warning: string | null = null;

  constructor(private readonly storage: () => PreferenceStorage) {
    try {
      const text = storage().getItem(PREFERENCES_KEY);
      if (text === null) return;
      if (text.length > 2048) throw new Error('Settings exceed the local size limit.');
      const value: unknown = JSON.parse(text);
      if (!value || typeof value !== 'object' || Array.isArray(value)) return;
      const fields = value as Record<string, unknown>;
      this.current = {
        seekSeconds: isSeekInterval(fields['seekSeconds']) ? fields['seekSeconds'] : 10,
        threeFingerDrag:
          typeof fields['threeFingerDrag'] === 'boolean' ? fields['threeFingerDrag'] : true,
      };
    } catch {
      this.warning = 'Saved settings are unavailable. Changes apply in this tab.';
    }
  }

  get values(): WebPreferences {
    return { ...this.current };
  }
  get persistenceWarning(): string | null {
    return this.warning;
  }

  setSeekSeconds(value: unknown): boolean {
    if (!isSeekInterval(value)) return false;
    this.save({ ...this.current, seekSeconds: value });
    return true;
  }

  setThreeFingerDrag(value: unknown): boolean {
    if (typeof value !== 'boolean') return false;
    this.save({ ...this.current, threeFingerDrag: value });
    return true;
  }

  private save(value: WebPreferences): void {
    this.current = value;
    try {
      this.storage().setItem(PREFERENCES_KEY, JSON.stringify(value));
      this.warning = null;
    } catch {
      this.warning = 'Changes apply in this tab, but this browser could not save them.';
    }
  }
}
