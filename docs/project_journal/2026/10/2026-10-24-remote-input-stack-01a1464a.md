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
- Transport changes must retire the old session and pending work. Do not silently replay
  clicks, text, relative seeking, or held input across a switch or reconnect.
- Compare finite groups of authenticated no-op round trips over the selected transport.
  Report sample count, timeouts, median, p95, and clearly defined jitter. Do not subtract
  unsynchronized phone and Mac timestamps or label fixtures as radio measurements.

## Gestures and media

- Preserve tap, secondary tap, pointer movement, and two-finger scrolling. Add held-button
  dragging and configurable multi-finger actions with cancellation and disconnect release.
- Pressure and local haptics are optional capability-based enhancements. Basic gestures
  remain usable without force sensing; complete Magic Trackpad equivalence is unproven.
- Media control targets a selected IINA player or supported Chrome tab independently of
  desktop focus. Include player volume, play/pause, relative seek, and next/previous where
  the source supports them. Player volume uses 10% steps and a clear 100% snap point;
  its maximum is a reported player capability.

## Shared gate dependency

- Ordinary repository CI accepts non-default PR bases. The currently published shared
  Codex review gate rejects them and needs upstream stacked-base support and retarget
  handling. A clean remote review cannot substitute for that required check.
- The user explicitly chose repository-only changes and will coordinate the upstream
  fix. Do not modify, publish, or merge either upstream repository from this workstream.
- Keep this external dependency visible in PR evidence; do not skip, replace, or forge
  the shared check to report readiness.

## Evidence and follow-up

- Foundation: PR #2; connected-screen and Simulator coverage: PR #3.
- Per-slice validation and current external-gate state belong in the corresponding PR.
- Later product work retains numeric-comparison pairing, Control Centre/widgets, and
  installation-entry exploration from the earlier journals.
