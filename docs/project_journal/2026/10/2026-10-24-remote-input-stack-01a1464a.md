---
id: 20261024-input-stack-01a1464a
title: Responsive input, BLE comparison, gestures, and media adapters
status: active
created: 2026-10-24
updated: 2026-10-24
branch: wip/input-latency
pr:
supersedes: []
superseded_by:
---

# Responsive input and media controls

## Scope and delivery

- Deliver four dependent slices: input latency, selectable BLE and round-trip comparison,
  multi-touch gestures, then IINA and Chrome media adapters.
- Each slice has a separate branch and PR targeting its immediate predecessor; the first
  targets `master`. Keep source dependencies explicit and validate every resulting head.
- Physical acceptance and merge are user-owned. Simulator fixtures and unit tests do not
  establish BLE radio performance or real input-to-display latency.
- The user enabled Developer UI Automation on the connected iPhone for later testing.
  Device unlock, permission prompts, and actual availability still require verification.

## Input performance

- Existing input uses TLS WebSocket over the local network. The previous implementation
  sent a full desktop-state response after every command and dropped relative input when
  eight results were outstanding. These are optimization candidates, not a measured cause
  of the reported delay.
- Measure command round-trip time with a monotonic local clock. Distinguish it from
  physical input-to-display latency, and preserve discrete-input ordering while bounding
  high-frequency relative-input work.
- The input slice coalesces adjacent relative deltas on a 60 Hz common-run-loop timer,
  preserves click/key ordering barriers, and bounds the queue and outstanding results.
  Overload may replace only trailing motion after the latest barrier. A saturated
  barrier queue silently drops only best-effort pointer motion and scroll; rejected
  discrete actions remain visible. Disconnect clears queued work; accepted discrete
  actions are never replayed on reconnection.
- The companion samples desktop state once per periodic broadcast and immediately after
  a system-volume command, rather than after every pointer event. TCP enables `noDelay`;
  connection and result deadlines use a monotonic clock. These reduce avoidable work but
  do not by themselves establish a measured physical latency improvement.

## BLE comparison

- Preserve existing secure Wi-Fi pairing; offer BLE for already-paired devices using
  public Core Bluetooth APIs. Advertisements and peripheral identifiers are discovery
  hints, not proof of peer identity.
- Pair over the existing Wi-Fi QR flow first. The mobile client stores the issued
  per-device token in Keychain. BLE uses that token for a mutual HMAC handshake with
  fresh nonces, derives directional keys, and protects ordered GATT frames with
  ChaCha20-Poly1305. Advertising identifiers do not authenticate a peer, and the
  pairing token is not sent as clear BLE data.
- Transport changes must retire the old session and pending work. Do not silently replay
  clicks, text, relative seeking, or held input across a switch or reconnect.
- Compare finite groups of authenticated no-op round trips over the selected transport.
  Report sample count, timeouts, median, p95, and clearly defined jitter. Do not subtract
  unsynchronized phone and Mac timestamps or label fixtures as radio measurements.
- The connection menu offers Wi-Fi/Bluetooth LE switching for an already paired Mac and
  a connection benchmark sheet. A default run sends three warmups, then three groups of
  30 sequential no-op probes, with a two-second timeout per measured probe. It reports
  local-monotonic p50/p95, jitter (p95 minus p50), and loss. No physical BLE measurement
  has been recorded.

## Gestures and media

- Preserve tap, secondary tap, pointer movement, and two-finger scrolling. Add held-button
  dragging and configurable multi-finger actions with cancellation and disconnect release.
- Pressure and local haptics are optional capability-based enhancements. Basic gestures
  remain usable without force sensing; complete Magic Trackpad equivalence is unproven.
- Media control targets a selected IINA player or supported Chrome tab independently of
  desktop focus. Include player volume, play/pause, relative seek, and next/previous where
  the source supports them. Player volume uses 10% steps and a clear 100% snap point;
  its maximum is a reported player capability.

## Native stack prerequisite and verifier

- The released upstream `@v2` action resolves to v2.2.11 and supports authenticated
  GitHub-native stacks rooted at the repository default branch. Manually chained
  base branches still require native stack membership registration.
- Native stack 10 is registered from `master` in order PR #9, #4, #5, #6, #7, #8.
  The members remain open and unmerged. See the [GitHub stacked pull request API](https://docs.github.com/en/rest/pulls/stacks).
- Repository PR #9 subscribes the verifier to GitHub's documented
  `pull_request.stacked` activity. Its `actionlint` 1.7.12 compatibility rule is
  limited to the documented event diagnostic; the `stacked_typo` negative control
  remains rejected. The required check, provider-review policy, permission scope,
  and upstream `@v2` reference remain unchanged.
- The Simulator gate allows 240 seconds per case, 40 minutes for the UI-test step,
  and 50 minutes for the Apple job. Failure diagnostics preserve the original
  `xcodebuild` exit status, mute and cleanup behavior, and at most ten annotations.
  The iOS README matches these limits and diagnostics.
- The intended source stack is PR #9, functional PRs #4–#7, and optional offline
  Web preview PR #8. Registration and branch retargeting are repository metadata
  operations; CI support alone does not create stack membership.
- Upstream action changes remain outside this repository-only workstream. Do not
  skip, replace, or forge the shared required check.

## Evidence and follow-up

- Foundation: PR #2; connected-screen and Simulator coverage: PR #3.
- Final integrated local checks passed 154 AppleCore package tests, macOS and generic
  iOS Simulator app builds, generated plist validation, and the `SofaRemoteNativeHost`
  release build. Pinned Node 26.12.0/pnpm 12.14.0 format, lint, typecheck, tests, and
  builds passed: Chrome 15/15 and IINA 10/10. `actionlint` 1.7.12, shell syntax,
  ShellCheck 0.11.0, project-journal validation, and whitespace checks passed. This local
  gate did not run the Simulator UI suite, physical BLE radio, or live media playback.
- Per-slice validation and current external-gate state belong in the corresponding PR.
- Later product work retains numeric-comparison pairing, Control Centre/widgets, and
  installation-entry exploration from the earlier journals.
