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
  The Mac also releases a button after eight seconds without valid client
  activity, using a monotonic timer and one remote owner for the system pointer.
- Pressure click requires iOS to report Force Touch capability and falls back
  to an ordinary tap. Haptic feedback is separately configurable and defaults
  off.
- The Mac marks nearby same-button taps within the system double-click interval
  as native double-click events, tracked independently per remote session.
- Four-finger actions emit public macOS keyboard shortcuts. The matching system
  shortcuts must be enabled on the Mac; custom mappings can change the action.
  No private macOS API or arbitrary keyboard code is sent over the wire.
- Local validation passes strict Swift format/SwiftLint, 66 AppleCore/MacSupport
  tests, and macOS plus generic iOS Simulator app builds. The extracted volume
  card is included in the app target's explicit source list. The UI assertions
  and per-device execution evidence are tracked in the corresponding PR;
  no physical-device acceptance is claimed here.

## Remaining Acceptance

- Verify touch feel, pressure support, haptics, and standard shortcut mappings
  on supported physical devices. Keep this separate from package tests and
  Simulator UI coverage.
