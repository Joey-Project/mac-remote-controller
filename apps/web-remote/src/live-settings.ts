import { WebPreferenceStore, type WebPreferences } from './preferences.js';
import type { TouchFeedback } from './touch-feedback.js';

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error('The settings interface could not be loaded.');
  return value as T;
}

/** Local form changes apply once, including without a connection to a Mac. */
export class LiveSettings {
  private readonly interval = element<HTMLSelectElement>('settings-seek');
  private readonly drag = element<HTMLInputElement>('settings-drag');
  private readonly persistence = element<HTMLElement>('settings-persistence');
  private readonly force = element<HTMLInputElement>('settings-force');
  private readonly haptics = element<HTMLInputElement>('settings-haptics');
  private readonly pressureHint = element<HTMLElement>('settings-force-help');
  private readonly hapticsHint = element<HTMLElement>('settings-haptics-help');
  private readonly gestureHint = element<HTMLElement>('settings-gesture-help');
  private pressureAvailable = false;
  private companionSupportsGestures: boolean | null = null;

  constructor(
    private readonly apply: (value: WebPreferences) => void,
    private readonly preferences: WebPreferenceStore,
    private readonly feedback: TouchFeedback,
  ) {
    this.interval.addEventListener('change', () => {
      this.preferences.setSeekSeconds(Number(this.interval.value));
      this.render();
    });
    this.drag.addEventListener('change', () => {
      this.preferences.setThreeFingerDrag(this.drag.checked);
      this.render();
    });
    this.force.addEventListener('change', () => {
      this.preferences.setForceClick(this.force.checked);
      this.render();
    });
    this.haptics.addEventListener('change', () => {
      this.preferences.setHaptics(this.haptics.checked);
      this.render();
    });
    this.render();
  }

  refresh(): void {
    this.render();
  }

  reportPressure(): void {
    if (this.pressureAvailable) return;
    this.pressureAvailable = true;
    this.render();
  }

  setCompanionSupport(supported: boolean | null): void {
    if (supported === this.companionSupportsGestures) return;
    this.companionSupportsGestures = supported;
    this.render();
  }

  private render(): void {
    const value = this.preferences.values;
    this.apply(value);
    this.interval.value = String(value.seekSeconds);
    this.drag.checked = value.threeFingerDrag;
    this.force.checked = value.forceClick;
    this.haptics.checked = value.haptics;
    this.drag.disabled = this.companionSupportsGestures === false;
    this.force.disabled = this.companionSupportsGestures === false || !this.pressureAvailable;
    this.haptics.disabled = this.companionSupportsGestures === false || !this.feedback.available;
    this.pressureHint.textContent = this.pressureAvailable
      ? 'Pressure click is available when this input device reports pressure.'
      : 'Pressure has not been reported by this browser and input device. Standard taps remain available.';
    this.hapticsHint.textContent = this.feedback.notice;
    this.gestureHint.textContent =
      this.companionSupportsGestures === false
        ? 'Update the Mac companion to use these gestures.'
        : '';
    this.gestureHint.hidden = !this.gestureHint.textContent;
    this.persistence.textContent =
      this.preferences.persistenceWarning ??
      'Changes apply immediately and are saved in this browser.';
  }
}
