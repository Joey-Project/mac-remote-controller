---
id: 20261024-device-acceptance-01a1464a
title: iPhone Acceptance and Stable Mac Installation
status: active
created: 2026-10-24
updated: 2026-10-24
branch: codex/device-acceptance-fixes
pr:
supersedes: []
superseded_by:
---

# iPhone Acceptance and Stable Mac Installation

## Installation

- The user selected `/Users/joey/Applications/SofaRemoteMac.app` as the permanent
  local installation path and moved the companion there. The running executable
  was verified at that path. Future updates must replace that bundle in place
  and retain a stable development signing identity.
- The installed iPhone XS candidate was built from `cb2adbb` and launched without
  Simulator fixtures. App installation replaced the existing bundle without
  uninstalling it first.

## Physical Feedback

- The user reports BLE benchmark round trips of tens of milliseconds and Wi-Fi
  results below one millisecond. These are user observations, not independently
  captured measurements. The benchmark measures authenticated application ping
  and pong, not touch-to-pointer or display latency.
- BLE currently sends framed encrypted messages using serial GATT writes with
  response and returns notifications. Actual negotiated connection parameters
  and packet traces have not been captured. Fragment acknowledgements and radio
  scheduling are candidates for optimization, not proven timing attribution.
- The user reports no four-finger swipe action. This Mac's Control-arrow window
  and Spaces shortcuts were verified enabled. The user confirmed the relevant
  mobile settings are enabled. End-to-end shortcut execution remains to verify.
- On the installed `cb2adbb` candidate, haptic feedback defaults off and only
  emits for supported pressure clicks; ordinary taps, right-clicks, drags, and
  four-finger swipes do not emit feedback even when the toggle is enabled.

## Local Follow-up

- An active one-, two-, or three-finger sequence may promote to a four-finger
  shortcut when another finger joins and shortcuts are enabled. An active drag
  queues its release before promotion. Rejected, cancelled, and partially lifted
  sequences stay blocked. Other active finger-count changes still cancel.
- Four-finger shortcuts fire once when movement reaches the distance threshold,
  rather than waiting for fingers to lift. Further movement remains blocked until
  the complete physical sequence ends.
- Enabled haptics now cover ordinary taps, right-clicks, drag acquisition, and
  recognized shortcuts, as well as pressure clicks. Reusable generators prepare
  when a fresh touch sequence begins. Local feedback indicates recognition, not
  confirmed execution on the Mac.
- The gesture view has its own explicit Xcode source entry. Strict Swift format,
  SwiftLint, 165 package tests including three promotion regressions, macOS build,
  and generic iOS Simulator build pass. This does not verify physical tactile
  output or end-to-end four-finger behavior. The installed phone still has the
  earlier candidate while the user accepts the media adapters.

## Next Steps

- Install the touchpad follow-up after the current media acceptance session and
  verify four-finger recognition, Mac actions, and physical tactile feedback.
- Evaluate lower-latency BLE scheduling and framing while preserving authenticated
  ordering and cleanup; compare against Wi-Fi on the same physical devices.
