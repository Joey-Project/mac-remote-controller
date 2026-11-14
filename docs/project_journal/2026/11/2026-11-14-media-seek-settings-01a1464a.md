---
id: 20261114-media-seek-settings-01a1464a
title: Persistent Media Skip Interval Settings
status: completed
created: 2026-11-14
updated: 2026-11-14
branch: codex/media-seek-settings-20261114
pr:
supersedes: []
superseded_by:
---

# Persistent Media Skip Interval Settings

## Changes

- Add a Media playback section in Settings with a 5, 10, 15 or 30 second
  skip interval. Ten seconds remains the default; unsupported saved values
  fall back to that default. Preferences apply immediately, work offline and
  persist across app launches.
- Both seek buttons use the selected duration, including their SF Symbols and
  accessibility labels. The accepted five-button media row, source selection,
  keyboard, touchpad and volume controls remain in place.
- Keep the existing relative-seek wire command. Browser and IINA adapters need
  no protocol change or corresponding deployment for this preference.

## Validation

- AppleCore/MacSupport executes 357 tests with no failures and one pre-existing
  optional signed-app fixture skip. The new tests validate forward/backward
  command round trips and fallback for invalid or missing saved values.
- Swift format and strict SwiftLint checks pass for the changed Swift files.
- The Settings UI regression selects a value offline, relaunches the app,
  checks both button labels and their actual signed seek commands, then restores
  the original preference. It uses a Debug Simulator-only media target and
  neither connects to a production bridge nor plays audio.
- Physical phone/player acceptance remains separate from these automated checks.

## Follow-up Order

- IINA diagnostics/recovery and this preference are independent PRs.
- Accessibility and physical iPad adaptation are deferred. A real Web client
  takes priority over Android implementation; the existing Web preview alone
  does not provide remote control.
