---
id: 20261106-remote-settings-01a1464a
title: Remote Settings and Connection Navigation
status: completed
created: 2026-11-06
updated: 2026-11-06
branch: codex/remote-settings
pr:
supersedes: []
superseded_by:
---

# Remote Settings and Connection Navigation

## Scope

Organize the iPhone/iPad controls around the existing full touchpad, a separate
keyboard page and the optional volume/playback overlay. Keep the five media
buttons, fixed ten-second seeks, protocol, input dispatch and connection behavior.

## Implementation

- Add an independent Settings page for the four existing gesture/feedback
  preferences. Reuse their existing on-device storage and immediate updates.
  Allow access before connecting and explain unsupported companion/hardware.
- Put one-tap keyboard/touchpad switching in the leading toolbar position;
  the button describes its destination. Keep all existing keyboard controls.
- Make the connected Mac name open connection details. Move transport switching,
  on-demand benchmark and disconnect into that sheet. Reuse the existing
  disconnect/reconnect and benchmark logic; add no automatic probes or retries.
- Put overlay visibility in the touchpad toolbar and retain the keyboard page's
  existing permanent top panel. Keep the more menu for session/display actions
  and Settings. Preserve the existing state/capability policy for those actions.
- Preserve mode, draft, selected player and panel visibility on return. Release
  an active pointer drag and dismiss text focus before presenting another screen.
- Reuse native navigation, forms and adaptive sheet presentation on iPhone/iPad.
  Keep the touchpad outside all page scroll containers.

## Validation

- Simulator fixtures include a disconnected setup screen and a long Mac name;
  the disconnected fixture skips Keychain, discovery and real connections.
- UI assertions cover offline persistence, unsupported options, local-only
  navigation, draft/overlay preservation, header visibility, keyboard commands,
  connection switching and the existing session/display controls.
- Local Apple checks pass: 299 tests, strict Swift formatting/lint, both macOS
  signed builds and the generic iOS Simulator build.
- The complete Simulator suite passes on iPhone (18 passed, 3 expected skips)
  and iPad (19 passed, 2 expected skips). The skips cover opt-in live hardware
  tests and iPhone's unsupported landscape orientation.
- Native hardware lock/display effects and transport benchmarks remain separate
  from Simulator fixture coverage.
- Expand the complete CI UI step to 50 minutes and the Apple job to 75 minutes
  for the added settings/persistence/navigation cases. The preceding full UI run
  used 39m36s of its 40-minute budget. Keep every assertion, required check,
  iPhone/iPad destination and 240-second per-test limit.
