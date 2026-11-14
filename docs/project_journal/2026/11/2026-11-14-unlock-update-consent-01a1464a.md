---
id: 20261114-unlock-update-consent-01a1464a
title: Preserve Remote Unlock Consent Across Helper Updates
status: active
created: 2026-11-14
updated: 2026-11-14
branch: codex/preserve-unlock-consent-20261114
pr:
supersedes: []
superseded_by:
---

# Preserve Remote Unlock Consent Across Helper Updates

## Scope

Retain both the remote-unlock switch and the allowed-device list during normal
helper updates for the same console user and signing certificate. Explicit
uninstall remains a full removal. Pointer processing, UI and mobile apps are
unchanged; setup still requires normal administrator authorization and binds
XPC to the new exact companion hash.

## Implementation

- Record the admitted companion's leaf-certificate SHA-256 in the root-owned
  installation receipt. Older receipts remain decodable. A same-user exact-hash
  reinstall can also retain consent without a certificate; a changed hash needs
  a previously recorded matching certificate. Unknown legacy identities, changed
  certificates/users, and incomplete installations start without inherited consent.
- Capture only the current persistent settings while holding the uninstall state
  lock shared by revocation. Keep the snapshot in the administrator installer's
  memory until the new installation is published. Explicit uninstall captures
  nothing; denied devices are not inferred from the pairing list or older snapshots.
- Publish retained device permissions with the switch initially off. A root-owned
  one-use startup intent requests restoration of a previously enabled switch.
  Before serving XPC, the new helper clears prior grants, durably consumes this
  intent and uses normal artifact and screen-lock policy validation to re-enable.
  Failure cannot replay enablement on subsequent restarts.

## Validation

- Regression tests cover same-certificate updates, two allowed devices, disabled
  and revoked consent, different users/certificates, ad-hoc and legacy records,
  incomplete installation, receipt compatibility and startup failure ordering.
- Native ad-hoc signature coverage distinguishes missing certificate identity
  from invalid unsigned code.

## Remaining Acceptance

- Exercise a certificate-signed helper update through normal administrator setup,
  then confirm the switch and both device permissions survive the next update.
  This is separate from model and signature tests and is not yet physical acceptance.
- A legacy installation cannot prove continuity across a changed code hash;
  its first transition still requires manual consent once.

## Evidence

- [Runtime setup](../../../../../apps/macos/UnlockRuntime/README.md).
- [Remote unlock workstream](2026-11-02-remote-unlock-01a1464a.md).
- [IINA deployment and preceding helper update](2026-11-14-iina-recovery-01a1464a.md).
- Local validation records: `.codex-tmp/unlock-consent-20261114/`.
