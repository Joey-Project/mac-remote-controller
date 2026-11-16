---
id: 20261116-local-automation-01a1464a
title: macOS Local Automation
status: completed
created: 2026-11-16
updated: 2026-11-16
branch: wip/macos-local-automation
pr: 39
supersedes: []
superseded_by:
---

# macOS Local Automation

Implemented in [PR #39](https://github.com/Joey-Project/mac-remote-controller/pull/39).

## Outcome

- Add the current-user Unix-socket service and bundled `SofaRemoteControl` CLI.
  The 26 typed IDs cover all app-defined interactive controls and both pairing
  code values, including per-device controls and the manual setup disclosure.
- Reuse existing controllers for setup, recovery, pairing, clipboard, Web and
  termination operations. Preserve the menu-bar layout, labels and input path.
- Enforce current visibility, enabled state, exact device selection, verified
  unlocked session and request deadline. Report accepted asynchronous actions
  separately from controller completion and system dialog confirmation.
- Keep endpoint ownership/modes, peer UID checks, frame/connection/time bounds,
  active-listener admission and identity-bound cleanup local to this service.
  Default snapshots exclude secrets; displayed pairing codes require explicit
  reads. System permissions and helper administrative authorization are retained.

## Validation

- Router and real Unix-socket tests cover malformed arguments, current devices,
  hidden/disabled/locked controls, stale requests, explicit code reads, unsafe
  filesystem objects, active/stale endpoints, frame limits and idle clients.
- Compiled CLI integration uses a real private socket with a fake service.
- Local validation covers 372 package tests (one signed-app-fixture-only skip),
  15 focused automation tests, three compiled CLI checks and two coverage checks.
  The universal Mac app and nested CLI pass strict signature verification.
- CI checks app UI coverage, builds/signs the bundled CLI, and retains the full
  AppleCore/MacSupport, Apple-app and existing iPhone/iPad UI suites.
- Runtime/production deployment and physical control acceptance remain separate
  from these isolated tests. Local evidence stays outside tracked sources.

## Next Steps

- Deploy the normally signed app through the existing helper update flow when
  requested, then use the interface for Web and media integration acceptance.
- Continue using native UI automation for popover presentation, layout checks
  and application/system-owned dialogs.

See [the local automation guide](../../../local-automation.md).
