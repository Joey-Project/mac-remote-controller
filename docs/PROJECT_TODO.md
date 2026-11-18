# Project TODO

- [in_progress] Touchpad experience: validate phased pinch magnification and
  explicit desktop-action buttons on real target apps and the Mac. Four-finger
  touchpad actions are deferred in favor of an independently hideable desktop panel.
  Virtual HID is deferred pending an Apple entitlement; retain pointer/drag efficiency and the
  accepted keyboard, toolbar and volume UI.
  [Gesture workstream](project_journal/2026/10/2026-10-24-multitouch-gestures-01a1464a.md).
  [Control panels](project_journal/2026/11/2026-11-12-desktop-control-panels-01a1464a.md).
- [in_progress] Chrome extension availability: recover existing media tabs after
  service-worker restart with fresh page snapshots. Continue live registration,
  Native Messaging, bridge and tab-delivery acceptance; the reported live failure
  is not yet tied to one observed cause.
  [Chrome workstream](project_journal/2026/11/2026-11-11-chrome-availability-01a1464a.md).
- [pending] IINA stability: investigate the previously deferred intermittent
  disconnect while preserving the existing five-button media row and percentages.
  [Media workstream](project_journal/2026/10/2026-10-24-media-adapters-01a1464a.md).
- [in_progress] Renewal reliability: continue the independent daily observation
  with the approved iOS payload and anti-downgrade checks. Complete expired-probe
  recovery and reboot/network/missed-run coverage. Preserve historical outcomes
  and keep app updates separate from observation-day counts.
- [in_progress] Four-digit pairing physical acceptance: implementation, isolated
  SRP/TLS tests and iPhone/iPad Simulator flows are covered. Verify the actual
  Mac code window, Bonjour enrollment and Keychain persistence on real devices;
  preserve existing pairing records during acceptance.
  [Pairing workstream](project_journal/2026/11/2026-11-09-numeric-pairing-01a1464a.md).
- [in_progress] iOS Control Centre and widget entry points: touchpad/keyboard
  navigation and fixed-extension renewal support are implemented. Complete
  first-device signing, real extension-profile renewal and system-entry acceptance.
  [Entry-point workstream](project_journal/2026/11/2026-11-11-control-centre-01a1464a.md).
- [pending] Further UX: configurable seek duration in Settings, reconnect and
  permission guidance, Dynamic Type and VoiceOver acceptance, and physical iPad
  rotation/multitasking acceptance.
- [in_progress] No-install control: the trusted LAN Web client implements
  four-digit pairing, pointer/keyboard/system-volume controls and reconnect.
  Complete physical Safari/multitouch acceptance and real Mac effect checks;
  retain App Clip evaluation as a later alternative.
  [Web workstream](project_journal/2026/11/2026-11-15-trusted-web-control-01a1464a.md).
- [pending] Implement actual Android pairing, connection and remote control;
  the current Kotlin/Compose app remains a scaffold.
- [in_progress] Web/native feature parity: media/player-volume controls are
  implemented; complete real-player/browser acceptance. Fixed desktop buttons
  are implemented with independent panel visibility; validate their actual Mac
  effects after deployment. Session lock/unlock and display controls are
  implemented using the existing native authorization; complete physical Safari
  acceptance after deployment. Add pinch and richer keyboard/settings in
  separate slices. Keep browser platform limits and each action's
  authorization requirements explicit.
  [Web pairing and acceptance](project_journal/2026/11/2026-11-16-web-pairing-resume-01a1464a.md).
  [Web media controls](project_journal/2026/11/2026-11-18-web-media-controls-01a1464a.md).
  [Web desktop controls](project_journal/2026/11/2026-11-18-web-desktop-controls-01a1464a.md).
  [Web session/display controls](project_journal/2026/11/2026-11-18-web-session-controls-01a1464a.md).
