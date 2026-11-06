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
   If Accessibility is missing, the companion also requests that separate system
   permission. Enabling unlock waits for the user to grant it in System Settings.
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
installer. It rejects links and other non-regular staged objects, validates all
nested code, then checks the main identity for the running architecture.
Privileged nested images use ad-hoc signatures to pin their exact slices even
when the outer app uses a certificate-based signing identity. Interrupted
staging is retained for diagnosis. Changed or unknown
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

The companion locates the exact system secure password control through
Accessibility and requires it to be enabled and focused, including a matching
loginwindow focused element. It submits one Return key-down/key-up pair from a
private event source with no modifier flags or repeat. Both events are prepared
before any input, and key-up is posted without an intervening cancellation point.
The plug-in's one-use grant supplies the authorization decision.

After the helper arms an allowed request, the companion declares user activity
with macOS's power-management API to wake a sleeping display. It waits up to
three seconds for the enabled, focused native secure control before submitting
once. The assertion is released on success, failure or cancellation; it does
not hold the display or system awake between requests. Preparation does not
renew the five-second grant.

If loginwindow shows its native user collection, the same preparation window
can press the unique button identifying the current already logged-in account.
The complete bounded collection must be readable and focused; ambiguous names,
other accounts, disabled controls and changed console sessions are refused.
Account selection is attempted once, then the focused secure password control
must be found independently before authentication is submitted. A native action
timeout is observed without replaying the action. No password is read or typed.

An explicit iOS connection to a saved Mac also requests Bonjour wake-on-resolve,
using the concrete network interface from discovery, with a bounded 15-second
resolution window. Unknown or reserved interfaces use ordinary resolution.
Discovery alone does not request
wake. If the API rejects the wake flag as unsupported or invalid, resolution
immediately falls back once to ordinary Bonjour and its five-second window.
Other failures propagate without retry. Full-system sleep requires working network wake and a network/device
that retains or proxies the service; the sleeping companion cannot execute an
unlock command itself. Enable **Wake for network access** on the Mac. A closed
laptop lid, shutdown, unsupported network wake and FileVault preboot remain
outside the supported wake path. Network wake is not evidence of OS unlock.
The current-user selector is based on read-only inspection of this host's native
loginwindow collection. Other system versions or account layouts may refuse
selection. Full-system sleep followed by automatic selection and unlock still
requires separate hardware acceptance; network reconnection alone does not
complete unlock.

The companion never reads the field value or supplies a password. When the OS
omits character-count metadata, it sets only an empty string through the native
setter. This can clear unsubmitted input; submission requires the empty write to
succeed and the same console session and boot to remain locked. Known nonempty
fields, other read failures, lost focus and failed preparation cancel the request.
The submission is not retried or replaced with another UI action. Success
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
