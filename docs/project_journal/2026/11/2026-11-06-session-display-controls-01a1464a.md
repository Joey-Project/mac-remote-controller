---
id: 20261106-session-display-controls-01a1464a
title: Session Lock and Display Controls
status: completed
created: 2026-11-06
updated: 2026-11-06
branch: codex/session-display-controls
pr:
supersedes: []
superseded_by:
---

# Session Lock and Display Controls

## Scope

Add three controls to the existing iPhone/iPad remote menu: mutually exclusive
Lock Mac / Unlock Mac, mutually exclusive Turn Display Off / Wake Display, and
a separate Lock & Turn Display Off. Keep touchpad, keyboard, media and volume
layout unchanged. Broader menu UI/UX work belongs in a later PR.

## Implementation

- Add optional lock and display-power capabilities, observed display state and
  four payload-free commands over the existing authenticated Wi-Fi/BLE sessions.
- Run lock and power operations in the ordinary companion. Keep remote-unlock
  helper authorization and Accessibility requirements unchanged. Load the private
  native lock symbol at runtime and omit lock capability if unavailable.
- Verify the same console user, session and boot during bounded confirmation.
  Send each native request once; serialize against unlock and other session
  operations. Confirm lock before attempting the combined display-off step.
- Keep the system awake with a reusable public idle-sleep assertion while a
  remote remains connected after display-off. Release on wake, last disconnect,
  shutdown or failed off confirmation. Preserve system power and password policy.
- Reuse the existing one-second state refresh without adding work to pointer
  input. Unknown states disable actions and legacy companions hide unsupported
  controls.

## Validation

- The Swift package has 299 passing tests, including payload restrictions,
  capability/state gating, state round trips, and unchanged input deadlines.
- Native-effect tests inject operations and cover lock-before-off ordering,
  actual-state confirmation, session changes, unavailable APIs, cancellation,
  busy rejection, no retries, assertion reuse and lifecycle cleanup. A regression
  prevents using a different session's lock state during confirmation.
- Simulator menu tests exercise both exclusive action pairs, one-command combined
  control, unknown states, old companions and lock without Accessibility. They
  use the existing in-process fixture and never affect a physical Mac.
- Physical lock/display acceptance remains separate from automated logic/UI
  coverage, especially for private native lock compatibility and display hardware.
- Allow 60 minutes for the complete Apple CI job, retaining the 40-minute UI
  suite limit, 240-second per-test limits and every existing validation step.
  This leaves room for canary/probe setup, both device suites and final builds.

## Follow-up

Organize menu UI/UX in a separate PR after this functional slice.
