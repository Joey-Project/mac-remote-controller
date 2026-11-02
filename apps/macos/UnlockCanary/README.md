# Native authorization canary

This is the first validation stage for paired-phone screen unlock. The selected
backend is an Authorization Services plug-in, with no stored Mac login password.
This stage validates the native callback and admission boundary independently
of the remote-control application.

The bundle exports only the `canary` mechanism. It grants its dedicated right
only for a known, logged-in, **already unlocked** console session. A locked
console always refuses this test grant. Its installer writes only
`com.joeyteng.sofaremote.unlock.canary`; it never rewrites
`system.login.screensaver`. There is no keyboard-event sender, network listener,
phone endpoint, automatic unlock or resident daemon in this stage.

## Build and offline validation

On macOS with the selected Xcode command-line tools and Python 3.11 or later:

```sh
python3 -I tooling/unlock/build_canary.py \
  --output .codex-tmp/unlock-canary-build
python3 -m unittest discover -s tooling/unlock -p 'test_*.py' -v
```

The output directory must be new. The builder uses the native SDK, ARC,
`-Wall -Wextra -Werror -Wpedantic`, then applies and verifies local ad-hoc
signatures. No Apple account or provisioning profile is needed. The native
suite runs as an ordinary user with disposable fixtures; it neither installs
the bundle nor modifies any system authorization right. The local formatting
check is `clang-format --dry-run --Werror apps/macos/UnlockCanary/*.[hm]`.

The suite covers stale/wrong-boot/wrong-user/wrong-session grants, unknown
console state, locked-session refusal, malformed data, symlinks, hard links,
FIFOs, ownership/permissions, replay, cancellation and 16 concurrent consumers.
Grant lifetimes use continuous time, including time asleep. Directory child
churn does not revoke an unchanged file; object replacement, invalid contents
and access-policy changes are separate refusal conditions.
Writer, consumer and revoker acquire the same nonblocking directory lock before
opening a grant, preventing an old consumer from moving a replacement grant.
The real callback refreshes OS state and time immediately before its decision.
Only bare and exactly qualified canary mechanism identifiers are allowlisted.

## Reviewed administrator canary

First inspect the fixed installation plan without administrator privileges:

```sh
python3 -I tooling/unlock/install_canary.py plan \
  --build .codex-tmp/unlock-canary-build
```

The returned build fingerprint binds the bundle's executable, Info.plist,
resource seal and probe bytes. A reviewed installation requires that exact
fingerprint, and refuses existing destinations or an existing dedicated right.
Root operations must be approved through the Mac's normal administrator
authorization; passwords never belong in arguments, environment or chat.

```sh
sudo python3 -I tooling/unlock/install_canary.py install \
  --build .codex-tmp/unlock-canary-build \
  --expected-build-sha256 REVIEWED_BUILD_SHA256
```

It installs an inert bundle in `/Library/Security/SecurityAgentPlugins`, a
non-setuid probe in `/Library/PrivilegedHelperTools`, and owner-private state
under `/private/var/db/com.joeyteng.sofaremote.unlock-canary`. No agent or daemon
is registered. Both before and after installation, the existing screen-lock
policy must match. Partial installation preserves a recovery intent; automatic
reinstallation or interrupted-install recovery is deliberately not claimed.

While the Mac is unlocked, an administrator can arm one five-second canary
grant and an ordinary user can evaluate the dedicated right:

```sh
sudo /Library/PrivilegedHelperTools/com.joeyteng.sofaremote.unlock-canary arm
/Library/PrivilegedHelperTools/com.joeyteng.sofaremote.unlock-canary evaluate
/Library/PrivilegedHelperTools/com.joeyteng.sofaremote.unlock-canary evaluate
```

The first evaluation should allow; the second should refuse. Repeat with an
expired grant and without a grant. Evaluation alone does not prove actual OS
screen unlock. The read-only `state` operation reports only a lock category,
with no user or device identifiers; unknown state remains unknown. Sandboxed
processes may lack access to the IOKit observer.

Removal checks the original installed bytes and exact recorded dedicated
definition. Changed artifacts, unknown state entries, foreign policy or an
incomplete installation require manual diagnosis rather than broad deletion.

```sh
sudo python3 -I tooling/unlock/install_canary.py uninstall
```

## Remaining acceptance

Actual authorization-host loading, independent OS unlock, native authentication
triggering without password keystrokes, normal password/Touch ID fallback,
Keychain health, signed client admission, per-device phone opt-in and physical
device integration remain separate gates. A production mechanism must not be
enabled on the system screen-lock rule until those gates have concrete evidence
and a reviewed rollback path. The existing companion remains at
`~/Applications/SofaRemoteMac.app`.

Apple's [Authorization Services plug-in interface](https://developer.apple.com/documentation/security/authorization-plug-ins)
defines the callback entry point. [Machine Control's existing-session provider](https://github.com/kzahel/machine-control/blob/main/platforms/macos/guests/macos/unlock/README.md)
was an architecture reference. This directory contains original implementation;
no upstream source or installer is vendored or executed by the build.
