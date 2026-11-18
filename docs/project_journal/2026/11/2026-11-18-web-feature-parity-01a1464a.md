---
id: 20261118-web-feature-parity-01a1464a
title: Browser Feature Parity
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-feature-parity
pr:
supersedes: []
superseded_by:
---

# Browser Feature Parity

## Outcome

- Inventory the iPhone/iPad user actions in [the parity table](../../../WEB_APP_PARITY.md),
  including intentional enrollment/transport and native system-entry differences.
- Persist the Web's three floating groups in the existing local preference
  record. Hide all works in touchpad and keyboard modes, matching the current
  App's optional panels. Settings changes preserve panel choices and vice versa.
- Send click event timestamps in native protocol seconds so the Mac can classify
  double clicks from source timing, retaining server timing for unrepresentable
  event clocks. Keep discrete ordering, existing pointer
  sampling/coalescing and no reconnect replay.
- Add optional one-shot pressure click only for reported touch/pen pressure,
  ignoring unsupported 0.5/0 defaults. Suppress the trailing tap; multi-finger
  gestures remain distinct. Provide opt-in short local vibration with capability
  and refusal guidance; vibration never gates remote input or retries on motion.
- Match native gesture/feedback preference availability on old companions.
  Preserve saved defaults, migrate earlier records and explain storage failures.
- Add allowlisted touchpad/keyboard fragment entries and Home Screen/system
  shortcut guidance using existing web-app metadata. Fragments never reach the
  strict gateway router; launch selects a mode without sending a remote action.
  No service worker, credential cache or extra Mac privilege is added.

## Validation

- Regression first demonstrates missing source tap timestamps.
- Unit tests cover preference migration/all panel combinations, immutable
  snapshots, click timing/validation, pressure defaults, one-shot clicks,
  opt-in/refused feedback and allowlisted mode links.
- Isolated muted-browser checks use mocked vibration and desktop-free remote
  state; exercise persistence, mode entry, pressure and local feedback as well
  as media, keyboard, pinch, desktop/session controls and benchmark regression.
- Real TLS/WSS validation retains companion authorization and framing checks;
  physical Safari and actual Mac effects remain separate acceptance.

## Next Steps

- Deploy only under separate authorization; preserve existing apps, helper grants
  and the daily-renewal payload during source delivery.
- Complete physical Safari multitouch, pressure/feedback hardware, Home Screen
  entry, VoiceOver/Dynamic Type and actual Mac effects. The source parity table
  does not claim those physical checks have passed.
- Keep native-only BLE, discovery/enrollment and Widget/Control Centre features
  explicit; use the App for those paths.
