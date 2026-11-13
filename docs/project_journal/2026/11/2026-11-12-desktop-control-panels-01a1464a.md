---
id: 20261112-desktop-control-panels-01a1464a
title: Independent Control Panels and Desktop Action Buttons
status: active
created: 2026-11-12
updated: 2026-11-13
branch: codex/desktop-control-overlays-20261112
pr:
supersedes: []
superseded_by:
---

# Independent Control Panels and Desktop Action Buttons

## Scope

- Replace four-finger phone gestures with explicit Previous desktop, Mission
  Control, App windows and Next desktop buttons.
- Independently show or hide the volume/playback and desktop groups. Both can
  be hidden, either can be shown alone, or both can be stacked vertically.
- Preserve the separate keyboard page, existing media row and volume behavior,
  pinch/scroll/right-click/drag recognition, and bounded input dispatch.

## Current State

- One toolbar menu controls both groups and offers Hide all controls. Choices
  persist locally across navigation, mode changes, reconnects and launches.
  The touchpad's frame stays unchanged under the panels; keyboard mode places
  visible groups above its existing content and scrolls them together so a
  visible software keyboard cannot crowd out the text field. Both groups default hidden.
- Four-finger recognition is disabled and its settings switch is removed. The
  existing protocol/native executors remain for peer compatibility. The new
  buttons require gesture support and Accessibility, release an active local
  drag and use the existing ordered system-shortcut command route without
  keyboard-event or modifier synthesis.
- New Simulator tests cover every visibility combination, independent stacking,
  persistence and Hide all, exact button commands, and unavailable companions
  or Accessibility. Existing keyboard, settings and touchpad regressions stay
  in the suite. The opt-in live Chrome acceptance test explicitly enables the
  volume/playback group when hidden, so it works with fresh preferences too.
  Compilation and actual UI execution are separate evidence.
- The desktop card has its own accessibility container, preserving each
  button's individual identity and the card's complete bounds. This avoids
  inheriting the card identifier onto its children; visual layout and the
  native system-action route stay unchanged.

## Remaining Acceptance

- Complete physical iPhone/iPad usability acceptance, including the long-name
  toolbar and keyboard page with both panels and the software keyboard visible.
- Validate actual Mission Control, App Exposé and both desktop directions on
  the physical Mac. Command submission and constructed event tests alone do
  not prove native desktop animation or cross-Space navigation.

## Evidence

- Strict Swift formatting/SwiftLint, 340 AppleCore/MacSupport tests, two signed
  macOS builds and a generic iOS/Widget Simulator build passed. The latest
  keyboard/panel layout and the entire UI test bundle compiled with local
  ad-hoc signing and frozen dependencies.
- Initial local UI execution was blocked before tests: CoreSimulator boot timed out
  after 180 seconds. The task-owned temporary device was deleted afterward;
  that attempt is not counted as passed. After a user-performed helper unlock
  on 2026-11-13, the three desktop-card CI failures were reproduced on a local
  iPhone before the accessibility correction. All five desktop-panel tests
  then passed on both iPhone 17 Pro and iPad mini (A17 Pro) Simulators running
  iOS 26.5, with no skips. The iPad executed the same signed test products via
  `test-without-building`. Temporary devices were shut down and deleted.
  Full iPhone/iPad CI execution remains separate from these targeted local tests.
- Source: `apps/ios/SofaRemoteiOS/App/DesktopControlsCard.swift`, `RemoteView.swift`
  and `RemoteToolbar.swift`.
- Regression coverage: `apps/ios/SofaRemoteiOSUITests/DesktopControlsUITests.swift`.
- Local bounded artifacts: `.codex-tmp/desktop-overlays-20261112/`.
