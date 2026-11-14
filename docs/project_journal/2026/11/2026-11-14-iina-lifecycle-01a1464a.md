---
id: 20261114-iina-lifecycle-01a1464a
title: IINA Connection Diagnostics and Lifecycle Recovery
status: completed
created: 2026-11-14
updated: 2026-11-14
branch: codex/iina-reliability-20261114
pr:
supersedes: []
superseded_by:
---

# IINA Connection Diagnostics and Lifecycle Recovery

## Changes

- Show per-window connection status in IINA's native plugin menu and log only
  diagnostic transitions. Separate missing or rejected setup, unavailable bridge,
  bridge HTTP failure, player failure, idle playback and a connected player.
  Native error bodies, credentials, titles and paths are never logged.
- Back off failed cycles from 250 ms to a two-second ceiling, resetting after
  success. Healthy polling remains serial at 250 ms, retains the eight-command
  batching policy and adds no configuration-file reads or per-command delay.
- Finish an in-flight request before unregistering a closing window. Discard
  late commands and stop pending retries without replaying an applied command
  whose result acknowledgement was lost.

## Validation

- Deterministic plugin tests exercise repeated outages and recovery, bounded
  retry delays, cached preference refresh, setup rejection, idle state,
  sanitized diagnostics, lost acknowledgements and closure during a request.
- Strict TypeScript checks and Oxlint pass. The existing media row, phone UI,
  gain-ratio volume policy and pointer transport are unchanged.
- These checks do not establish long-duration real-player stability or phone
  acceptance. The earlier credential and volume fixes remain documented in the
  [IINA recovery journal](2026-11-14-iina-recovery-01a1464a.md).

## Agreed Follow-up Order

- Deliver seek-duration settings in a separate PR after this reliability slice.
- Defer the accessibility/iPad adaptation workstream; prioritize a real Web
  client ahead of Android implementation. Keep physical acceptance separate
  until the user is available.
