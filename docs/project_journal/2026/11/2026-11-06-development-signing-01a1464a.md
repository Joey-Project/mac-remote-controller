---
id: 20261106-development-signing-01a1464a
title: Stable Mac Development Signing
status: completed
created: 2026-11-06
updated: 2026-11-06
branch: codex/stable-development-signing
pr:
supersedes: []
superseded_by:
---

# Stable Mac Development Signing

## Scope

Preserve the Mac companion's privacy identity across local updates at
`$HOME/Applications/SofaRemoteMac.app`. Keep UI, remote-input behavior, pairing
storage and the unlock helper's exact-code-hash trust unchanged.

## Implementation

- Both Xcode configurations load a shared development signing configuration.
  The machine-local certificate SHA-1 and Team are explicitly pinned in an
  ignored file. No personal certificate metadata, private key, or account
  credentials are committed.
- Add configure, build and verify commands. Refuse absent/unavailable pins,
  implicit certificate rotation, ad-hoc signatures, mismatched Team/bundle ID,
  unstable code-hash requirements, missing Hardened Runtime and debug/injection
  entitlements. Full nested signature verification remains mandatory.
- Keep installable development output separate from the ad-hoc CI artifact.
  CI explicitly clears the local Team setting and tests offline admission.
- After validation, unregister only the temporary build product from Launch
  Services so it cannot replace the installed companion in permission pickers.
  App files and the fixed-path installation remain intact.
- Preserve the helper's per-version trust. This changes the companion's TCC
  identity continuity, not its privileged authorization policy.

## Validation

- Nine signing tests pass locally, including real Apple Development signatures
  on two different executable fixtures with equal designated requirements and
  different code hashes. Fixtures are never launched or installed.
- Negative native cases reject ad-hoc code, another certificate pin and debug
  entitlements. Missing and unavailable pins stop before a build can begin.
- CI runs offline cases without credentials; real certificate cases explicitly
  skip on unconfigured machines.
- The complete certificate-signed companion passes strict nested validation.
  Debug and Release products have different main code hashes and the same
  certificate-based designated requirement.
  The original Apple checks also pass: 278 Swift tests, formatting/lint,
  two ad-hoc universal macOS builds and generic iOS Simulator compilation.
- The first certificate-signed preview is installed at the fixed path with a
  verified rollback backup. Its old ad-hoc Accessibility grant no longer matches;
  system logs confirmed the requirement mismatch and the entry could not be
  added through Settings. A one-time, explicit `tccutil` reset of only this app's
  Accessibility approval removed the stale record. The user then granted normal
  system authorization and refreshed Unlock Helper through its existing setup;
  builds and routine updates never reset permissions.
  No helper implementation, pairing-format or lock-policy logic changes were
  introduced.

## Permission Acceptance

- The live Accessibility record is allowed and now binds the installed
  companion's Apple Development requirement, replacing the old ad-hoc hashes.
- The user reconnected the paired phone and confirmed normal pointer movement
  and clicking from the certificate-signed installation.
- The same saved live requirement accepts the installed app, a different Debug
  build and Release: all three have different main code hashes. The permission
  record was unchanged during the probe. No second app replacement or launch was
  needed for this check; this is requirement matching, not a second update trial.
- Development and CI build completion leave the fixed installation as the only
  registered Sofa Remote application. Build and rollback copies remain on disk.

## Operational Notes

- Keep the ignored certificate pin and fixed installation path on this Mac.
  Certificate rotation is explicit and can require fresh system authorization.
- Continue observing normal future updates. Updating Unlock Helper still
  requires administrator-authorized setup because it pins the exact companion
  version; this work does not change that trust policy.
