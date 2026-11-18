---
id: 20261118-web-connection-details-01a1464a
title: Web Connection Details and Benchmark
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-connection-details
pr:
supersedes: []
superseded_by:
---

# Web Connection Details and Benchmark

## Outcome

- Open a separate Connection page from the Mac name, showing the current Mac,
  connection status and address, with Disconnect. Preserve the selected remote
  mode, unsent keyboard draft and floating controls when returning.
- Match the native benchmark's three warmups and three groups of 30 sequential
  authenticated no-op round trips. Show minimum, nearest-rank p50/p95, maximum,
  p95 minus p50 jitter and measured timeout count/loss rate. Browser scheduling
  and clock precision are part of this measurement; it is not input-to-display
  latency or proof that two devices used the same network route.
- Use the existing companion ping/pong protocol and `roundTripProbe.v1`
  capability. No new server privilege, arbitrary command, pointer/audio action,
  credential storage or automatic test is introduced.
- Bound retired requests at 128, accept only exact late replies, and keep
  timeouts separate from ordinary input deadlines. Cancel on leaving,
  disconnect or capability loss; reconnect never resumes or replays the run.
  Remote keyboard navigation stays disabled while viewing connection details.

## Validation

- Regression first proves the preceding Web transport lacks benchmark probes.
- Unit tests cover statistics, warmup exclusion, sequential probes, cancellation,
  delayed callbacks, timeout loss, exact reply matching, bounded retired state,
  current capabilities and reconnect without replay.
- Isolated muted browser checks cover phone, tablet and landscape layout,
  hit targets, focus, drafts, 93-probe completion, timeout/cancellation and old
  companions, alongside the existing remote regression checks.
- Desktop-free TLS/WSS checks perform 93 matching authenticated round trips
  without recording input/audio events, retaining existing pairing, permissions,
  keyboard/media, gesture and session-control checks.

## Next Steps

- After authorized deployment, compare physical Safari with native benchmark
  results on the same Mac and network. Keep input-effect and screen-latency
  acceptance distinct from RTT statistics.
- Finish the remaining browser-feasible parity gaps and record native-only
  transport/hardware/system-entry boundaries explicitly.
- Keep installed apps, helper grants and the daily-renewal payload unchanged
  until deployment is separately requested.
