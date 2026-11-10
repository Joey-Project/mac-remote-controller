---
id: 20261109-numeric-pairing-01a1464a
title: Phone-Initiated Four-Digit Mac Pairing
status: active
created: 2026-11-09
updated: 2026-11-10
branch: codex/numeric-confirmation-pairing
pr: https://github.com/Joey-Project/mac-remote-controller/pull/29
supersedes: []
superseded_by:
---

# Phone-Initiated Four-Digit Mac Pairing

## Summary

- Tap an unpaired nearby Mac on iPhone/iPad, read the four-digit code in the
  Mac's automatically opened window, and enter it on the phone. The user's final
  choice replaces the earlier both-screens comparison and Mac approval idea.
- Keep existing paired Wi-Fi/BLE reconnects and retain QR/paste invitations as
  secondary pairing methods. Do not change connected touchpad, keyboard or media UI.

## Current State

- The new enrollment-only message phases use SRP-6a with SHA-256 and the fixed
  3072-bit group from pinned `swift-srp` 2.4.0. Standard mutual proofs also bind
  the actual TLS leaf, service UUID, request/attempt IDs, both public keys,
  salt and device names. The displayed PIN is never a wire field.
- Only final client confirmation after server verification may authorize the
  live requesting connection and create its long-term token. Existing Keychain
  accounts and certificate-pinned reconnects remain in use. Enrollment grants
  no automatic remote-unlock permission.
- One pending request is visible on an unlocked Mac. Its code lasts 120 seconds,
  including system sleep; three wrong attempts invalidate it. Global rolling
  request/failure limits survive cancellation, replacement codes and reconnects.
  Cancellation, lock, expiry and disconnection discard pending state and keys.
- Modular exponentiation runs in dedicated actors. Terminal registration checks
  the current connection, request, deadline, Mac session and capacity again.
  Input dispatch and existing paired transport paths do not run SRP.
- Shared crypto/policy/coordinator tests exercise actual SRP, identity tampering,
  retries with fresh keys, finish replay, failure budgets, busy requests, expiry,
  Mac locking and transport cancellation. All 338 package tests passed, including
  16 numeric-pairing tests. Two use a real loopback TLS/WebSocket connection to
  verify certificate observation and rejection of a mismatched saved pin. Their
  generated identities are imported only into memory, never into a Keychain.
- The Simulator fixture reuses the real crypto, wire codec and Mac coordinator
  while keeping pairing credentials in memory. Initial full UI regression passed on
  iPhone 17 Pro (26 passed, three conditional skips) and iPad mini A17 Pro
  (27 passed, two conditional skips), including six new pairing cases on each.
  The skips cover opt-in physical integrations and an orientation test that
  runs only on iPad, not numeric pairing.
- After compacting the new input layout, all six pairing cases passed again on
  both devices. The tests now assert that Pair and Cancel remain fully above
  the keyboard, including after an incorrect code. Connected control UI stays
  unchanged.
- Strict Swift formatting/lint, two signed macOS builds and the generic iOS
  Simulator build passed. The upstream SRP dependency currently constrains
  transitive Swift Crypto to 4.5.2 rather than version 5.
- Offline Settings coverage reads the actual accessibility switch value before
  asynchronously polling, with the original three-second deadline. This avoids
  a predicate-wait timeout observed on CI even though its screenshot and
  hierarchy already showed the expected value. Relaunch persistence, restoration
  of the original value and zero-input assertions remain required.
- The two Settings UI cases passed three repetitions each on both local
  iPhone and iPad simulators after that change (12 executions total). Complete
  Swift checks, all 334 package tests and both app builds also passed again.
- Menu-driven UI tests require the actual Settings button to exist and be
  hittable before one tap. The original three-second destination check, draft
  preservation and explicit-send assertions remain in place. This adds no tap
  retry and changes no application UI or simulator startup behavior.
- The complete local UI suite passed after this synchronization change:
  iPhone 28 passed with three conditional skips, and iPad 29 passed with two
  conditional skips. The original draft test also passed three local iPad
  repetitions before the change. Local iOS 26.5 evidence remains separate from
  the CI runner's iOS 27.2 acceptance.
- The pending connection pool protects the active numeric-pairing connection
  during unrelated socket churn without authenticating it or increasing pool
  capacity. Ending the request releases protection automatically.
- Incorrect-proof accounting checks the deadline and Mac availability before
  charging either budget. Expiry during SRP verification returns `expired`
  without consuming a global incorrect-code attempt.
- A paired Nearby Mac offers **Pair again…** through its context menu. This is
  explicit numeric re-enrollment, including after Mac-side revocation; existing
  credentials remain until a verified welcome is saved, and cancellation keeps
  the old record. Saved reconnects never silently switch trust paths.
- All eight numeric-pairing UI cases passed on both iPhone and iPad after the
  recovery changes, including revoked-credential rejection, successful numeric
  replacement, reconnect with the new credential and cancel without forgetting.
- CI allows 70 minutes for the two sequential cold Simulator runs and 90
  minutes for the whole Apple job. The individual XCTest allowance stays at
  240 seconds; both devices and every assertion remain required. This covers
  the observed 50-minute step timeout while the second Simulator was still running.

## Remaining Acceptance

- Validate live TLS enrollment and real Keychain persistence separately from
  the isolated fixture, without replacing existing paired credentials.
- Verify the Mac code window and paired phone on a physical setup before
  claiming physical-device acceptance.

## Evidence

- Protocol contract: `packages/protocol/v1-design.md`.
- Local artifacts: `.codex-tmp/numeric-pairing-20261109/`.
- Existing media issue remains deferred; this work changes no Chrome installation.
