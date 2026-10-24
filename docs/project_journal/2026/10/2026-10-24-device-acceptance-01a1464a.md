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

- Verify the companion's setup buttons interactively after unlocking the Mac.

- Install the touchpad follow-up after the current media acceptance session and
  verify four-finger recognition, Mac actions, and physical tactile feedback.
- Evaluate lower-latency BLE scheduling and framing while preserving authenticated
  ordering and cleanup; compare against Wi-Fi on the same physical devices.

## Media Adapter Acceptance

- IINA was installed correctly but had an empty local preference store. The user
  configured the bridge token and confirmed that IINA control then worked.
  The token was compared privately during diagnosis and never printed.
- The user observed Chrome seek succeeding while the phone displayed an error
  claiming the tab was closed. The worker used a callback-based Chrome delivery
  channel, but the content script only sent a separate asynchronous action
  result, without replying on the delivery channel.
- The content script now synchronously acknowledges receipt and still sends its
  correlated action result separately. A genuine delivery failure asks the user
  to refresh the tab instead of claiming every transport error means a closed tab.
- Two new regressions fail on the old content script and pass after the fix.
  All 37 Chrome tests and 15 IINA tests pass. Chrome TypeScript and Oxlint checks
  pass. The existing unpacked Chrome extension was verified to load this tree's
  output directory, reloaded through Chrome, and its Bilibili page refreshed.
  Final phone-side acceptance of the revised Chrome action result is pending.

## Bundled Integration Setup

- Mac builds bundle the Chrome extension, IINA plugin, and separately signed
  Native Messaging executable. The Apple CI job installs the pinned Node/pnpm
  dependencies before building, so installers do not depend on a source checkout
  at runtime.
- **Set Up IINA** installs the plugin and updates only its bridge port and token,
  preserving other plugin preferences. Credentials are created with mode `0600`
  before writing and atomically renamed. IINA's plugin preferences are cached;
  an already-running IINA needs plugin reload or restart.
- **Set Up Chrome** copies the extension and helper into stable Application
  Support paths and registers only the fixed Sofa Remote extension origin.
  Chrome's first local-extension load remains a browser-confirmed step. No token
  is included in distributable plugin assets or the Chrome manifest.
- Four installer regressions cover repeated installation, unrelated settings,
  private file permissions, and linked destination rejection. All 169 Swift tests,
  strict Swift format/SwiftLint, Mac packaging, and generic iOS Simulator build pass.
- The opt-in `LiveMediaUITests` uses the normal app, existing pairing, and real
  transport. It sends three seeks and requires matched successful results from
  the Mac without an error alert. The debug-only observation exposes result
  counts, not credentials, and does not enable fixtures. CI skips this test
  unless live acceptance is explicitly enabled.
- A dedicated iPhone simulator was created and a signed normal-mode test build
  prepared. The desktop later locked; automatic unlock and the user's requested
  retry both failed. Live GUI acceptance remains unverified. The user authorized
  continuing implementation and automatic checks while manual unlock is unavailable.
