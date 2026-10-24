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
  begins, a finger-count change cancels the sequence. Active
  drags release on cancellation, surface teardown, and Mac session close/revoke.
  The Mac attempts release after eight seconds without valid client activity.
  It removes a held button only after creating and posting its release event;
  unavailable event context retains the state for another timer tick. Disconnect
  cleanup retains pending button state and pointer ownership until release posts.
- Pressure click requires iOS to report Force Touch capability and falls back
  to an ordinary tap. Haptic feedback is separately configurable and defaults
  off.
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
  fresh drag attempt. Movement is discarded while the matching button-down is
  pending and enabled only after its successful result; a late result after
  lift cannot revive movement.
- Tap history survives staggered finger lifts; a replacement finger after
  lifting begins cancels the sequence. Taps must finish within 0.5 seconds,
  while holding and later moving can still start scrolling or dragging.
- Pointer ownership covers pointer actions, while system keyboard shortcuts
  remain available to another authenticated remote.
- Four-finger actions emit public macOS keyboard shortcuts. The matching system
  shortcuts must be enabled on the Mac; custom mappings can change the action.
  No private macOS API or arbitrary keyboard code is sent over the wire.
- Local validation passes strict Swift format/SwiftLint, 118 AppleCore/MacSupport
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

- Verify touch feel, pressure support, haptics, and standard shortcut mappings
  on supported physical devices. Keep this separate from package tests and
  Simulator UI coverage.
