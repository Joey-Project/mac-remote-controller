import { WebPreferenceStore, type WebPreferences } from './preferences.js';

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
  private readonly preferences = new WebPreferenceStore(() => window.localStorage);

  constructor(private readonly apply: (value: WebPreferences) => void) {
    this.interval.addEventListener('change', () => {
      this.preferences.setSeekSeconds(Number(this.interval.value));
      this.render();
    });
    this.drag.addEventListener('change', () => {
      this.preferences.setThreeFingerDrag(this.drag.checked);
      this.render();
    });
    this.render();
  }

  private render(): void {
    const value = this.preferences.values;
    this.interval.value = String(value.seekSeconds);
    this.drag.checked = value.threeFingerDrag;
    this.persistence.textContent =
      this.preferences.persistenceWarning ??
      'Changes apply immediately and are saved in this browser.';
    this.apply(value);
  }
}
