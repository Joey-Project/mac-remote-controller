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
  Mac locking and transport cancellation. All 334 package tests passed, including
  15 numeric-pairing tests. Two use a real loopback TLS/WebSocket connection to
  verify certificate observation and rejection of a mismatched saved pin. Their
  generated identities are imported only into memory, never into a Keychain.
- The Simulator fixture reuses the real crypto, wire codec and Mac coordinator
  while keeping pairing credentials in memory. Full UI regression passed on
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

## Remaining Acceptance

- Validate live TLS enrollment and real Keychain persistence separately from
  the isolated fixture, without replacing existing paired credentials.
- Verify the Mac code window and paired phone on a physical setup before
  claiming physical-device acceptance.

## Evidence

- Protocol contract: `packages/protocol/v1-design.md`.
- Local artifacts: `.codex-tmp/numeric-pairing-20261109/`.
- Existing media issue remains deferred; this work changes no Chrome installation.
