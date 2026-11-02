---
id: 20261102-background-renewal-01a1464a
title: Independent Background Renewal Research
status: completed
created: 2026-11-02
updated: 2026-11-02
branch: wip/ios-background-renewal
pr:
supersedes: []
superseded_by:
---

# Independent Background Renewal Research

## Outcome

- Add reproducible, pinned xtool 1.24.0 source reconstruction, its MIT license,
  isolated Keychain/native AOSKit patch, Mac signing-project generator and runtime
  packager under `tooling/renewal/`.
- Add an opt-in headless validation runner for iOS candidate signing, locked
  Wi-Fi overwrite installation, and Mac probe self-renewal. The runner preserves
  application identity, original entitlements and executable instruction bytes.
- Require actual profile expiry advancement, matching Team/device/certificate,
  strict signatures, bounded private logs, and non-overlapping cooperating runs.
- Keep device/account configuration, signed artifacts, certificates, sessions,
  raw logs and machine-specific receipts outside Git. No daily scheduler or
  automatic unlock helper is installed by these tools.
- Application UI, input behavior, Chrome extension and IINA plugin are unchanged.

## Measured Feasibility

The initial local experiment on November 1 used Xcode 26.6 and an already-paired
iPhone after its first unlock since boot. These measurements predate this
packaging commit and establish the research premise, not exact-head CI proof.

- While the Mac remained locked, an independent saved session issued a fresh
  dedicated iOS development profile. Repeating issuance for the same App ID
  advanced its expiration while retaining the previous profile and certificate.
- The actual Sofa Remote identifier, Team, iPhone and certificate matched a new
  seven-day profile. Re-signing preserved entitlements and instruction bytes.
- A one-shot LaunchAgent completed renewal, re-signing and Wi-Fi overwrite
  installation while both devices stayed locked. Installer exit and app-presence
  read-back passed. The final installed profile expires November 8 at 23:41 UTC.
  The one-shot test agent was removed; no recurring schedule was left installed.
- The Mac probe obtained and adopted its own new seven-day profile. A new
  process and a separate background job could still access its saved session.
- A real iOS archive expired on October 29 was restored to a valid local signed
  candidate. That older code was not installed on the phone.

## Validation And Limits

- Offline unit coverage checks configuration privacy, profile identity and
  expiry, implicit/explicit Keychain authorization, command bounds, concurrent
  execution exclusion, and source archive admission. CI builds the reconstructed
  Swift probe without accessing an Apple account or device.
- Exact-head local/CI/review results belong to the PR. Historical hardware
  success does not claim that the newly packaged runner has completed longevity
  acceptance or physical remote-control testing.
- On November 2, the packaged public runner also issues and validates an iOS
  candidate while the Mac is locked, and adopts a self-renewed Mac probe after
  checking saved-session access. Its locked Wi-Fi overwrite installation passes
  with app-presence read-back; the installed profile expires November 9 at
  08:22 UTC. Original entitlements and instruction bytes match. Its private
  receipts remain outside Git; phone launch/control acceptance is not repeated.
- Daily 8–10-day testing moves to a separate merged-source worktree and Codex
  session. Its runtime configuration and results remain local.
- Recovery when the Mac probe itself is already expired, sleep/reboot/network
  resilience, and multi-day reliability remain explicit follow-up tests. Phone
  restart or cold developer-service initialization may require a manual unlock.

## Entry Point

See [the renewal research guide](../../../../../tooling/renewal/README.md) for
reconstruction, initial signing/login, explicit commands and longevity criteria.
