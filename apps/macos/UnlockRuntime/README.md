# Remote unlock and recovery

This experimental integration unlocks an **already logged-in** Mac console
session after an explicit request from an allowed, paired iPhone or iPad. It
does not handle FileVault preboot, initial login, logout, or a switched user.
It never stores, reads, or types the Mac login password.

## Menu-bar setup

Keep the companion at `~/Applications/SofaRemoteMac.app`. Its **Setup & Recovery**
section groups the existing Chrome/IINA setup with these controls:

1. **Install Unlock Helper…** asks for native macOS administrator authorization.
   Installation leaves remote unlock off and preserves the screen-lock rule.
2. Turn on **Enable remote unlock**, then allow specific paired devices in the
   paired-device list. The iOS remote menu offers **Unlock Mac** only on a
   companion advertising this capability; the action is disabled without
   per-device permission or a confirmed locked session.
3. Turn the feature off to revoke pending authority and restore the recorded
   screen-lock rule. **Uninstall Unlock Helper…** also stops launchd and removes
   the owned helper, plug-in, settings, and dedicated authorization right.

Local/ad-hoc builds are supported with Hardened Runtime enabled and debug/code
injection exceptions disabled. The helper admits only the exact installed
companion code-directory hash and console UID, and the app verifies the helper
in return. A new companion build therefore needs **Update Unlock Helper…**;
update starts disabled and requires selecting allowed devices again.

The administrator operation first copies the app into a root-private staging
directory and verifies its pinned complete signature before running its
installer. Interrupted staging is retained for diagnosis. Changed or unknown
system artifacts are preserved, and setup reports a conflict instead of
overwriting another tool's configuration. A timeout is an unconfirmed operation;
inspect its status before starting another setup operation.

## Authorization boundary

The launchd service exposes a fixed, typed XPC interface. It cannot run arbitrary
commands or accept caller-supplied file paths, passwords, or authentication
rules. Phone identity comes from the existing authenticated Wi-Fi/BLE session.
Installation and removal require local administrator authorization; paired
phones cannot enable the service or grant themselves unlock permission.

Enablement prepends one dedicated mechanism to a supported one-of-N
`system.login.screensaver` rule, preserving the existing branches and order.
Unsupported compositions fail without changing them. Complete policy readback,
including owner/modification metadata, is retained for conflict detection.

A request creates a one-use grant lasting at most five seconds, bound to the
console UID, session UUID, boot UUID, and a live broker lease. Broker exit or
restart invalidates that lease. Disconnect, revoke, disable, session change,
and deadline expiry cancel the request. The authorization window applies to
the console session; it is not cryptographically bound to one loginwindow
authentication attempt. Existing password/Touch ID authentication remains a
fallback branch.

The companion attempts a bounded Accessibility `AXConfirm` action on an empty
native password field. It reads only the character count, never the field
value, and sends no keyboard events. If that action is unavailable, the request
is cancelled. There is no silent Return-key or password-typing fallback. Success
requires independently observing the same OS console become unlocked. Physical
host compatibility, fallback authentication and Keychain health need explicit
acceptance; compilation or isolated canary success is not full unlock proof.

All broker work stays outside the pointer input path. OS-result sampling runs
only during an active request, for at most eight seconds. An unlock command is
not automatically replayed after an uncertain result.

## Manual phone recovery

**Choose Renewal Setup…** imports the private configuration described in
[the renewal guide](../../../tooling/renewal/README.md#private-configuration).
The companion retains its own accepted iOS app copy and configuration under
`~/Library/Application Support/SofaRemote/Recovery`, without changing a separate
daily-test configuration or scheduler.

**Re-sign & Reinstall…** uses that accepted app and the existing renewal probe's
dedicated Keychain session. It runs the explicit `--manual-recovery` mode: the
Mac can stay unlocked and the paired phone can use USB or Wi-Fi. The underlying
background commands still require their original locked-Mac/locked-phone/Wi-Fi
conditions. No Apple password or token is entered into the menu-bar app.

Python 3.11+, Xcode, the signed renewal probe and its initial Apple login must
already be configured. A phone reboot may need a manual unlock to initialize
developer services. If the Mac probe itself has expired, bootstrap signing
repair is still required; installing the unlock helper does not repair it.
Installation and app-presence readback are distinct from launching or accepting
the app on an unlocked physical phone.

## Validation without installation

```sh
python3 -I tooling/unlock/test_runtime.py --output .codex-tmp/unlock-runtime-tests
python3 -m unittest discover -s tooling/unlock -p 'test_*.py' -v
python3 -m unittest discover -s tooling/renewal/tests -v
tooling/swift/check.sh
tooling/swift/test-ios-ui.sh
```

The native checks run as the ordinary user in fresh temporary directories. CI
does not install a root helper or modify the runner's authentication database.
Keep the earlier [inert canary](../UnlockCanary/README.md) separate: its mechanism
refuses locked sessions and is not this production unlock path.
