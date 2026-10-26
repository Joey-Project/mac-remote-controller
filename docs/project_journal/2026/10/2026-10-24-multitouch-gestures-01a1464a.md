---
id: 20261024-multitouch-gestures-01a1464a
title: Multitouch Gestures and Held Pointer Cleanup
status: active
created: 2026-10-24
updated: 2026-10-24
branch: wip/multitouch-gestures
pr:
supersedes: []
superseded_by:
---

# Multitouch Gestures and Held Pointer Cleanup

## Summary

- Extend the connected touchpad with capability-gated three-finger drag and
  four-finger Mission Control, App Exposé, and Spaces shortcuts. One-finger
  movement/tap and two-finger right-click/scroll remain available.

## Current State

- The wire protocol uses an optional `supportsGestures` state field, allowlisted
  mouse-button down/up commands, and fixed shortcut actions. Older companions
  omit the capability and the iOS app keeps the new gestures disabled.
- Touch sequences allow staggered finger placement and release while pending;
  threshold crossing preserves the full initial movement delta. After movement
  begins, other finger-count changes cancel, except promotion into a four-finger
  shortcut when enabled. Promotion releases an active drag first. Active
  drags release on cancellation, surface teardown, and Mac session close/revoke.
  The Mac attempts release after eight seconds without valid client activity.
  It removes a held button only after creating and posting its release event;
  unavailable event context retains the state for another timer tick. Disconnect
  cleanup retains pending button state and pointer ownership until release posts.
- Pressure click requires iOS to report Force Touch capability and falls back
  to an ordinary tap. Haptic feedback is separately configurable and defaults
  off. When enabled, ordinary taps, right-clicks, drag acquisition, and recognized
  shortcuts also emit prepared local feedback. Four-finger shortcuts fire once
  at the distance threshold instead of waiting for fingers to lift.
- The Mac marks nearby same-button taps within the system double-click interval
  as native double-click events, tracked independently per remote session.
  iOS taps carry a bounded monotonic touch timestamp so queue and transport
  delay do not alter the result; the Mac compares timestamps only from the
  same client timebase, resets on timebase changes or rollback, and retains
  processing-time classification for older clients.
  Failed click event creation or emission does not update click history.
- Per-finger tap slop prevents opposing two-finger movement from becoming a
  false right-click, while centroid movement can still start scrolling. Held
  right-button movement emits a native right drag. If queue saturation rejects
  a required button release, iOS closes the session so Mac cleanup releases it.
- Local drag state follows the matched button-down result. A rejected start
  clears the local drag; a paired failed button-up does not close the session
  unless the Mac had accepted that start. A failed release after an accepted
  start still closes the session immediately. The caption and accessibility
  hint omit three- or four-finger gestures when unsupported or disabled.
- An unqueueable or rejected drag start blocks movement for the remainder of
  that touch sequence. A sequence-ID check in the model prevents a late UI
  update from sending movement after rejection; lifting the fingers allows a
  fresh drag attempt. Pending displacement is accumulated in bounded scalar
  storage and sent in wire-sized chunks after the matching button-down succeeds,
  before release even if fingers have already lifted. A late result cannot
  reactivate the finger sequence. Rejection or disconnect discards that buffer.
  Backpressure retains unsent chunks and release, protects accepted chunks from
  best-effort queue replacement, and holds later input behind the release barrier.
  The existing three-second acknowledgement deadline tears down stalled sessions.
- Tap history survives staggered finger lifts; a replacement finger after
  lifting begins cancels the sequence. During a partial pending lift, the
  remaining finger continues to be tracked for tap slop without starting a
  one-finger gesture. Taps must finish within 0.5 seconds, while holding and
  later moving can still start scrolling or dragging.
- Pointer ownership covers pointer actions, while fixed system gestures
  remain available to another authenticated remote.
- Four-finger actions no longer synthesize Control-arrow shortcuts. Mission
  Control and App Exposé send the same native Dock notifications used by the
  system launcher. Previous/next Space posts a balanced begin/change/end Dock
  swipe with no keyboard events or modifier flags. The wire action allowlist
  remains unchanged for compatibility; arbitrary events cannot be requested.
- The undocumented Dock/HID ABI is isolated and dynamically resolved from fixed
  system library paths. Missing interfaces report a failure without a keyboard
  fallback. macOS 27 uses an attached HID payload; older macOS uses Dock gesture
  fields. All frames are prepared before any post, including the terminal frame,
  so allocation or payload failure cannot leave a partial gesture. No virtual
  HID device, driver, memory-offset access, or additional entitlement is used.
- Protocol details are cross-checked against Apple's `HIDEvent.m` wrapper and
  the native Dock event consumers in Hammerspoon, yabai, and Spaces Manager.
  Dock notification calls consume no return value; submission does not prove
  completion of the system animation.
  Sources: [Apple HID wrapper](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/HIDEvent.m),
  [Dock notification consumer](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h),
  and [Dock swipe consumer](https://github.com/michaeltorbert/spaces-manager/blob/main/Sources/SpaceSwitcher.swift).
  Package tests inspect real HID payloads without posting them and cover native
  notification routing, both swipe directions, balanced phases, modifier-free
  events, and failure before emission. Live desktop action acceptance remains
  separate from these non-interactive checks.
- Local validation passes strict Swift format/SwiftLint, 150 AppleCore/MacSupport
  tests, and macOS plus generic iOS Simulator app builds. The extracted volume
  card is included in the app target's explicit source list. The UI assertions
  and per-device execution evidence are tracked in the corresponding PR; no
  physical-device acceptance is claimed here.

- The Simulator suite has nine scenarios on iPhone and iPad. The UI step has a
  40-minute limit and the Apple job a 50-minute limit: a six-scenario CI run took
  about 23 minutes, so the added capability and gesture cases need headroom.
  These limits do not assert that a particular run passed.
- A failed Simulator run extracts its XCTest summary and reports up to ten
  failure messages as GitHub annotations, while preserving the original
  `xcodebuild` exit status. Missing summaries produce a diagnostic warning.

## Remaining Acceptance

- Verify touch feel, pressure support, haptics, and native desktop actions
  on supported physical devices. Keep this separate from package tests and
  Simulator UI coverage.

## Termination and Acknowledgement Safety

- The application delegate handles ordinary termination, including menu Quit.
  It synchronously attempts every active and pending disconnected-session button
  release before closing clients. A failed release retains retry state and
  cancels termination with an actionable error; normal timer retries remain
  enabled. Successful preparation is idempotent.
- The drag coordinator lives in AppleCore so deterministic tests exercise the
  actual app state machine: quick lift before acknowledgement, delayed accepted
  start, rejected start, deferred later input, queue saturation and wire chunks,
  reset, fixture mode, and failed release. Additional tests cover protected queue
  prefixes and synchronous termination across all retained sessions.
