---
id: 20261119-renewal-without-lock-01a1464a
title: Lock Independent Renewal and Daily Testing
status: completed
created: 2026-11-19
updated: 2026-11-19
branch: wip/renewal-without-lock
pr:
supersedes: []
superseded_by:
---

# Lock Independent Renewal and Daily Testing

## Policy

- The user explicitly changed both manual renewal and daily background testing
  on 2026-11-19: neither Mac nor iPhone must be locked. Do not automatically
  lock or unlock a device to satisfy a test.
- Record known lock states and preserve unknown as null. Observation failure
  and changes between lock states do not invalidate renewal or installation.
- Keep daily Wi-Fi transport, Mac-before-iOS ordering, existing signing identity,
  profile-expiry advancement, fixed Widget validation, saved-session checks,
  installed-version readback, mutual exclusion and anti-downgrade admission.
- Successful receipt filtering no longer requires `bothDevicesLocked=true`.
  Profile/signature/code/version checks remain independently required before
  advancing the accepted reference. Historical locked runs retain their original
  observations and meaning; changing policy is not another observation day.

## Implementation and Validation

- The default Mac renewal/adoption path permits an unlocked session. A renewed
  candidate must still authenticate to Apple before atomic publication, with
  the previous runnable bundle retained for recovery.
- Daily iOS installation permits either lock state. Manual iOS recovery differs
  only by also allowing a paired USB transport. Developer-service first unlock
  and actual network availability remain platform prerequisites.
- Offline tests cover unlocked and unknown observations, lock-state transitions,
  successful installation receipts, Wi-Fi restrictions, missing post-install
  applications and candidate authentication failure before Mac publication.
- Runtime deployment and actual scheduled-run outcomes are separate from these
  offline tests. Local maintenance receipts are retained under
  `.codex-tmp/renewal-unlocked-20261119/`.

## Related Work

- [Renewal usage](../../../../tooling/renewal/README.md).
- [Background renewal observations](2026-11-02-background-renewal-01a1464a.md).
