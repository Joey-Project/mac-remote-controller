---
id: 20261024-multitouch-gestures-01a1464a
title: Multitouch Gestures and Held Pointer Cleanup
status: active
created: 2026-10-24
updated: 2026-11-09
branch: codex/touchpad-gesture-experience
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

- The current priority is the user's reported gap from Magic Trackpad behavior:
  two fingers scroll but cannot pinch to zoom, and four-finger behavior is
  missing on the physical Mac. Chrome extension unavailability is recorded
  separately in the media workstream and is deferred behind this input work.
- UIKit distinguishes two-finger translation from separation change. Once a
  sequence becomes scroll or pinch it stays in that mode until fingers lift.
  Symmetric pinches can begin with no centroid motion, while per-finger tap
  slop prevents an accidental right-click. A minimum eight-point scale denominator
  avoids unstable zoom from nearly coincident starting fingers without preventing
  a close-start pinch from becoming active. One-finger input retains its existing dispatch
  and avoids the additional finger-span calculation.
- `simulatedGestures.v1` gates phased `gesture.frame` commands, carrying a UUID,
  allowlisted kind, cumulative progress/log-scale, and client uptime. Updates
  coalesce without crossing begin/end/cancel barriers. Both transports use the
  existing bounded queue and acknowledgement window, with immediate terminal
  flush. A rejected phase closes the session for native cancellation.
- Four-finger input locks its initial axis and streams actual progress rather
  than a one-shot action. The Mac emits native Dock events for horizontal Spaces
  and vertical Mission Control/App Expose. Short or reverse releases cancel;
  native magnification uses relative scale changes at the initial pointer
  location. No keyboard or wheel-based zoom fallback is used. Unsupported
  companions retain the historical scrolling and fixed-shortcut behavior.
- The legacy Dock event builder now writes float-bit progress and matching
  motion/phase fields, including the marker's source field. This fixes incomplete
  encoding in the previous three-frame implementation. Event-field facts are
  cross-checked against
  [Mac Mouse Fix's TouchSimulator](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/TouchSimulator.m).
- Each native start/update prepares a cancellation path before emitting events.
  Cancellation is retained per connection and on disconnect if Accessibility
  is unavailable, holds pointer ownership until posted, retries on the existing
  timer, and prevents ordinary quit when cleanup cannot be submitted. Eight
  seconds without a gesture frame also attempts cancellation.
- Native event submission and local haptic recognition do not prove the target
  app or desktop actually acted. Separate phone classification, command delivery,
  Mac event submission and observed native response during diagnosis.
- The user deferred the raw-contact virtual trackpad route and chose continued
  gesture simulation. The separate Mac-local probe on macOS 26.3 tested
  CoreHID `HIDVirtualDevice` and IOKit `IOHIDUserDeviceCreateWithProperties`, with
  both a vendor-defined control and a five-contact Touch Pad descriptor. Both
  APIs returned nil under ad-hoc and the existing pinned Apple Development
  signing identity. The resource-open result was `0xe00002c2`; kernel logs
  explicitly report `creation-probe is not entitled`, before descriptor parsing.
  The installed SDK requires `com.apple.developer.hid.virtual.device`.
  [Apple's user-client implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDResourceUserClient.cpp#L117-L158)
  checks signed entitlements, with no root-user exemption in that check.
  That isolated probe sent no input reports or installed a driver. The
  five-contact descriptor, native gesture recognition and cleanup acceptance
  remain unverified. Local probe source and bounded logs are retained under
  `.codex-tmp/virtual-trackpad-probe-20261109/RESULT.md`.
- The CoreHID application capability to request is `HID Virtual Device`
  (`com.apple.developer.hid.virtual.device`), not the similarly named DriverKit
  family key. Apple's documented account flow is Mac App ID → Capability
  Requests → Request, submitted by the Account Holder through Certificates,
  Identifiers & Profiles. Developer program membership provides that portal;
  membership alone does not establish capability approval. Once approved,
  enable the capability and verify the profile and signature before retrying.
  [Apple's capability request flow](https://developer.apple.com/help/account/capabilities/capability-requests).

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
  shortcuts also emit prepared local feedback. On legacy companions, four-finger
  shortcuts fire once at the distance threshold instead of waiting for lift.
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
- Pointer ownership covers held buttons and continuous gestures. Legacy fixed
  shortcuts remain available during another remote's button hold, but cannot
  interrupt a continuous gesture.
- Legacy four-finger actions no longer synthesize Control-arrow shortcuts. Mission
  Control and App Exposé send the same native Dock notifications used by the
  system launcher. Previous/next Space posts a balanced begin/change/end Dock
  swipe with no keyboard events or modifier flags. The wire action allowlist
  remains unchanged for compatibility; arbitrary events cannot be requested.
- The undocumented Dock/HID ABI is isolated and dynamically resolved from fixed
  system library paths. Missing interfaces report a failure without a keyboard
  fallback. macOS 27 uses an attached HID payload; older macOS uses Dock gesture
  fields. The legacy atomic action prepares all frames before posting; continuous
  gestures prepare a retained cancellation before each post, so later allocation
  failure still has a cleanup path. No virtual
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
- Current local checks pass strict Swift format/SwiftLint, 315 AppleCore and
  MacSupport tests, two incremental signed macOS builds and a generic iOS
  Simulator build. AppKit decodes real constructed events as magnification
  with native began/changed/ended/cancelled phases. New tests cover strict wire
  bounds, cumulative coalescing, lifecycle identity/time checks, allocation
  failure cleanup and Dock progress/axis encoding, without posting desktop input.
- Targeted iPhone XCUITest passes actual pinch input, legacy-companion fallback,
  and existing movement/left-click/right-click. It exposed an initial-distance
  classification defect: XCUITest begins at about seven points of separation.
  The fixed policy permits close-start pinches and bounds the scale denominator;
  a deterministic replay covers that trace. Temporary diagnostics were removed.
  The full iPhone/iPad runner remains `tooling/swift/test-ios-ui.sh`; local
  artifacts are retained under `.codex-tmp/simulated-gestures-20261109/`.
  No physical-device or cross-application gesture acceptance is claimed here.

- The Simulator suite has nine scenarios on iPhone and iPad. The UI step has a
  40-minute limit and the Apple job a 50-minute limit: a six-scenario CI run took
  about 23 minutes, so the added capability and gesture cases need headroom.
  These limits do not assert that a particular run passed.
- A failed Simulator run extracts its XCTest summary and reports up to ten
  failure messages as GitHub annotations, while preserving the original
  `xcodebuild` exit status. Missing summaries produce a diagnostic warning.

## Remaining Acceptance

- Interpret Zoom as two-finger pinch magnification of Mac app content. Preserve
  two-finger pan/scroll and tap-to-right-click without accidental clicks when
  transitioning or cancelling a pinch.
- Validate native magnification in actual target apps, including a view that
  ignores it, and continuous four-finger execution/reversal on the physical Mac.
  AppKit decoding and deterministic event-capture tests do not establish
  cross-application delivery or successful desktop animation.
- Keep virtual-HID provisioning deferred. Preserve the accepted touchpad,
  keyboard, toolbar and volume UI, ordered cleanup and low-latency dispatch.

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
