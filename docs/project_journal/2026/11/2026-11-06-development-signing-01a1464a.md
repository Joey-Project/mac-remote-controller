---
id: 20261106-development-signing-01a1464a
title: Stable Mac Development Signing
status: active
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
  the initial normal system authorization is pending. No TCC reset, helper
  modification, pairing reset or lock-policy change was performed.

## Next Steps

- Complete the initial transition from ad-hoc signing. An existing Accessibility
  or Keychain authorization can require one normal system grant.
- Confirm a subsequent certificate-signed update retains Accessibility access.
  Updating Unlock Helper still requires the existing administrator-authorized
  setup because it pins the exact companion version.
