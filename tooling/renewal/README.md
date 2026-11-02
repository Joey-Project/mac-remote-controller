# Background renewal research

This is an opt-in macOS research tool for Sofa Remote's existing free Apple
development account. It is separate from the remote-control UI. It does not
install a scheduler, unlock either device, create/revoke certificates, delete
profiles, uninstall the phone app, or launch a media player.

The proof covers a warm, paired iPhone over Wi-Fi after its first unlock since
boot. Phone developer-service initialization after restart can require a manual
unlock. The probe can renew itself **before** expiration; recovery after the Mac
probe itself has expired still needs a bootstrap repair design.

## Reproducible source

The probe is reconstructed from [xtool 1.24.0](https://github.com/xtool-org/xtool/releases/tag/1.24.0),
commit `70e1568fdfcb20b560774057cd783f02361293b9`. `upstream.json` pins the archive,
source patch and dependency-lock digests. The six-file patch adds a restricted
renewal command, native local AOSKit Anisette, and an isolated Data Protection
Keychain service using `AfterFirstUnlockThisDeviceOnly`. No public Anisette
server is used. The MIT license is retained in `XTOOL-LICENSE.md`.

On an Apple Silicon Mac with Xcode and Python 3.11 or later:

```sh
python3 tooling/renewal/prepare.py
swift build --package-path tooling/renewal/.local/source \
  --scratch-path tooling/renewal/.local/Build \
  --product xtool --force-resolved-versions --disable-sandbox
python3 tooling/renewal/signing_project.py \
  --build-dir tooling/renewal/.local/Build \
  --output tooling/renewal/.local/bootstrap
```

For offline source reconstruction, pass `--archive /path/to/pinned-archive.tar.gz`.
The digest is still checked. Existing destination directories are never replaced.

## Initial Mac signing and login

Do this first setup while the Mac is unlocked. In Xcode, use the same free
Apple account and Personal Team that signed the iOS app. Build the generated
project with automatic signing, a concrete `platform=macOS,arch=arm64`
destination and a separate Derived Data directory. Initial provisioning can
require `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`.
Xcode may register this Mac for development. No password belongs in shell
arguments, configuration files, logs, or chat.

The generated Xcode app initially contains only the executable. Package its
SwiftPM frameworks, resources and Swift compatibility runtime before launching:

```sh
python3 tooling/renewal/package_probe.py \
  --app /path/to/DerivedData/Build/Products/Debug/SofaRenewalProbe.app \
  --build-dir tooling/renewal/.local/Build \
  --destination tooling/renewal/.local/packaged
```

The packager copies the app, preserves its profile and entitlements, signs the
nested frameworks and complete bundle with its existing leaf identity, verifies
the signature, and checks an isolated Keychain canary. It does not log in.

Run the packaged executable directly in a local interactive Terminal:

```sh
tooling/renewal/.local/packaged/SofaRenewalProbe.app/Contents/MacOS/SofaRenewalProbe \
  auth login --mode password
```

Enter account credentials and any verification code only in that local terminal.
The session stays in `com.joeyteng.sofaremote.renewal-probe.credentials`; Xcode's
credential storage is not read or changed by the probe. The experimental
authentication and developer-service interfaces are private Apple APIs.

## Private configuration

Create `configuration-private.json` outside tracked source and set mode `0600`.
These are its only accepted fields:

```json
{
  "probeApp": "/absolute/path/to/SofaRenewalProbe.app",
  "iosApp": "/absolute/path/to/validated/SofaRemoteiOS.app",
  "deviceIdentifier": "YOUR_COREDEVICE_IDENTIFIER",
  "deviceUDID": "YOUR_IPHONE_PROVISIONING_UDID",
  "runDirectory": "/absolute/path/to/private/renewal-runs"
}
```

No account password or token is accepted. Team and certificate data are derived
from the existing signed apps. Use the iPhone's provisioning UDID, not its
CoreDevice identifier. The Mac's provisioning UDID is read separately from
system hardware metadata; it is not assumed to equal the platform UUID.

The reference iOS app must be a known accepted build with the original identity.
An expired reference profile is supported. Candidate code, entitlements and
Keychain groups are preserved; this tool does not compile a different iOS UI.

## Explicit validation commands

Lock the Mac before a run. For installation, also lock the already-initialized
iPhone and keep it paired and reachable over Wi-Fi.

```sh
python3 tooling/renewal/renew.py ios-candidate --config /path/to/configuration-private.json
python3 tooling/renewal/renew.py ios-install --config /path/to/configuration-private.json
python3 tooling/renewal/renew.py mac-candidate --config /path/to/configuration-private.json
python3 tooling/renewal/renew.py mac-adopt --config /path/to/configuration-private.json
```

- `ios-candidate` signs and validates a local copy without installing it.
- `ios-install` additionally overwrites the original app over Wi-Fi, preserving
  its application identity. It records lock state and app-presence read-back.
- `mac-candidate` prepares a self-renewed copy of the Mac probe.
- `mac-adopt` checks saved-session access in that copy before replacing the
  configured stable probe path. It retains the previous app alongside that path.

Cooperating runs use one nonblocking lock alongside the configured probe, even
when their receipt directories differ. This prevents overlapping scheduled and
manual runs; it is not protection against a malicious same-user process.

Each run uses a new owner-private directory and writes a sanitized `receipt.json`.
Raw command diagnostics, decoded profiles and public certificate bytes remain
local. Command logs have per-command byte/time limits and a 4 MiB aggregate
budget. Failures stop the sequence; a successful request with unchanged expiry
is rejected. A successful installer followed by failed read-back remains a failed
validation with the successful install command recorded separately.

After a successful installation, point `iosApp` at the candidate recorded in its
receipt for the next comparison. This checks actual expiry advancement against
the most recently installed package. Keep the previous accepted package for
manual recovery. Retain backups and receipts deliberately; the research runner
does not recursively delete them.

## Daily longevity handoff

Run the offline suite without an Apple account or connected hardware:

```sh
python3 -m unittest discover -s tooling/renewal/tests -v
```

A dedicated test session should run for 8–10 days, executing Mac self-renewal
before the iOS renewal/install comparison each day. Record the merged source
commit, actual profile creation/expiration, command result, Wi-Fi transport and
device lock states. Include sleep/wake, a missed run and temporary phone/network
unavailability. Retry failures with backoff; do not loop account logins or revoke
certificates. Stop and request manual attention if first unlock or reauthentication
is required. Periodic Codex scheduling and its session are separate from this PR.

Keep a separate signed backup without renewal for a real-expiration recovery
test. Injected time can test decision logic; it does not establish the operating
system's behavior for a truly expired Mac probe. Do not change the machine clock
or expire the working installation for that test. Reboot tests require a suitable
maintenance window and the user's first-login/first-unlock cooperation.
