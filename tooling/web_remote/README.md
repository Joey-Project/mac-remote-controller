# Trusted LAN Web setup

The Mac companion serves the live client over HTTPS and same-origin WSS. A
browser connects directly to the Mac's private IPv4 address through a DNS-only
hostname. No relay, router port forwarding, public listener, or installation on
the phone is required. Native app connections keep their existing transport.

The initial Web client supports pointer movement, clicks, two-finger scrolling
and right tap, three-finger drag, text/control keys, system/player volume and
IINA/Chrome media control through the existing Mac adapters, and fixed desktop
action buttons. Pairing
uses the Mac-displayed four-digit code; the Mac must be unlocked for new pairing.
Existing paired browsers appear in the companion's device list and can be
revoked there. Session lock/unlock, display controls, BLE and phased pinch
gestures remain native-app features.

## Media controls

Set up the existing IINA plugin or Chrome extension on the Mac first. In the
Web menu, enable **Player controls**, then explicitly choose an available player.
The five-button row provides previous media, back 10 seconds, play/pause,
forward 10 seconds and next media. Buttons follow the selected player's
reported capabilities. A closed player clears selection rather than sending
its commands to a different source.

**Volume on touchpad** and **Player controls** can be shown independently or
together; both can be hidden to keep the touchpad clear. Volume stays visible
in keyboard mode. Tap the volume heading to switch between system volume and
the selected player's volume. Player volume requires a reported range and
current value, uses 10-percentage-point increments with a strong 100% detent,
and displays the full supported range, including values such as 120% or 400%.
Arrow keys adjust player volume by 10 percentage points; Home/End reach its
endpoints. Seek duration is fixed at 10 seconds in this slice.

Media commands use the existing authenticated same-origin connection and Mac
media router. No additional bridge token or adapter setup is sent to the browser.
While a player-volume request is awaiting acknowledgement, only the latest
unsent slider value is retained. Pointer/keyboard input does not wait for the
player, and intermediate slider values cannot fill the shared request queue.

## Desktop controls

Enable **Desktop controls** in the Web menu for Previous desktop, Mission
Control, App windows and Next desktop. The desktop group is independently
hideable alongside volume and player controls, so the touchpad supports all
eight visibility combinations without changing its frame. Keyboard mode keeps
the existing volume behavior and leaves the text field below visible panels.
On short screens, the floating stack can be scrolled to reach every group.

Buttons require an active connection, the companion's advertised gesture
support and Accessibility permission on the Mac. Missing support or permission
disables them and shows guidance. An action releases a local drag before sending
one allowlisted native command. Pointer and keyboard input remain independent
of media acknowledgements. Desktop actions use the same native Mac executor as
the iOS buttons; the browser does not send modifier keys or arbitrary shortcuts.
They are never replayed on reconnect. Actual desktop animation and switching
still require acceptance on the Mac after deployment.

## Certificate and DNS

Use a hostname you control with a browser-trusted certificate. A Bonjour
`.local` hostname or a public CNAME pointing at one does not supply public DNS
validation or a portable browser trust path. With a fixed DHCP reservation, a
DNS-only A record can simply point to the private LAN address.

For a changing address, the companion can observe an explicit interface such as
`en0`, rebind to its current private IPv4 address, and update one existing
Cloudflare DNS-only A record. The publisher verifies the record ID, name, type
and proxy state before writing, then reads it back. Updates use bounded backoff;
DNS caches and router DNS-rebinding protection can still delay or block lookup.
The listener never falls back to a wildcard or public address.

Let's Encrypt DNS-01 works without exposing the Mac to the Internet. Certificate
issuance and renewal require Internet access to Apple-independent ACME/DNS
services; ordinary remote control stays on the LAN. Public certificates also
publish their hostname in Certificate Transparency logs. ACME accounts are local
key pairs managed by Certbot, not a separate interactive login.

One reproducible toolchain is Certbot 5.10.0 with certbot-dns-cloudflare 5.10.0:

```sh
web_root="$HOME/Library/Application Support/SofaRemote/Web"
mkdir -p "$web_root"
chmod 700 "$web_root"
uv venv --python 3.14 "$web_root/Runtime"
uv pip install --python "$web_root/Runtime/bin/python" \
  certbot==5.10.0 certbot-dns-cloudflare==5.10.0
```

In this private directory, create `cloudflare-credentials.ini` with only the
`dns_cloudflare_api_token` setting, and an empty `acme-client.ini`, both mode
`0600`. Enter credentials locally, never in command arguments, URLs, source
files, or chat. Grant the token DNS Edit and Zone Read for only the intended
zone. Cloudflare scopes DNS Edit to a zone; the companion additionally limits
address updates to the configured record. Certbot creates temporary ACME TXT
records for the requested hostname.

First validate against the ACME staging service. After accepting the current
[Let's Encrypt terms](https://letsencrypt.org/repository/), an initial production
request can use:

```sh
"$web_root/Runtime/bin/certbot" certonly \
  --config "$web_root/acme-client.ini" \
  --config-dir "$web_root/acme-production" \
  --work-dir "$web_root/acme-production-work" \
  --logs-dir "$web_root/acme-production-logs" \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$web_root/cloudflare-credentials.ini" \
  --dns-cloudflare-propagation-seconds 30 \
  --cert-name sofaremote-lan --key-type ecdsa \
  --agree-tos --register-unsafely-without-email \
  -d remote.example.com
```

An email contact can be supplied instead. Keep all ACME state private and
available locally rather than in an on-demand cloud-storage folder. The private
key must be owned by the current user and inaccessible to other users. Certbot's
`live/` symlinks are supported. The server requires TLS 1.3 and a matching key.
Use a separate staging directory, not staging material in the production paths.

## Configure and enable

From the repository root, substitute the actual hostname, interface and private
address. The setup command refuses to overwrite existing configuration and
leaves the endpoint disabled:

```sh
python3 tooling/web_remote/configure.py \
  --hostname remote.example.com --address 192.168.1.10 --interface en0 \
  --certificate-chain "$web_root/acme-production/live/sofaremote-lan/fullchain.pem" \
  --private-key "$web_root/acme-production/live/sofaremote-lan/privkey.pem"
```

For Cloudflare address updates also provide `--zone-id` and `--record-id` for
the already created DNS-only A record. These identifiers are not API tokens.
The companion reads the token from the private credentials file; it is never
embedded in `configuration.json` or sent to the browser.

In the Mac menu's **Web remote** section, choose **Reload setup**, then
**Enable Web remote**.
Open or copy its HTTPS URL, including port `47625`. On the phone, request a code
and enter the one shown by the Mac. Three wrong entries rotate the code; rate
limits and a two-minute deadline still apply. Cancel the Mac prompt to reject a
request. Trusted-browser cookies are Secure, HttpOnly and SameSite=Strict;
JavaScript never receives the native credential. Clearing browser data requires
pairing again. The Web menu can forget its own pairing and disconnect immediately.

The configured port is persistent: app restarts, LAN address changes and
certificate renewal do not select a new port. The default is `47625`; changing
it requires an explicit setup change and an updated browser URL.

Backgrounding an unpaired browser preserves its pairing form and rechecks
authorization when it returns. Controls stay hidden until the Mac confirms an
active connection. Pairing requests use a same-origin referrer policy so Safari
can provide the exact Origin required by the server, even though the document
suppresses referrers by default. Null or foreign origins remain rejected.

If a router blocks public-DNS answers containing private IPs, allow the exact
hostname in its DNS-rebinding settings or use a local DNS override. Do not turn
off browser certificate validation. The certificate authenticates the server,
while same-origin checks and pairing authenticate and constrain input requests.

## Daily certificate check

After initial issuance, install the separate certificate check once:

```sh
python3 tooling/web_remote/schedule_certificate_check.py
```

It installs one user LaunchAgent,
`com.joeyteng.sofaremote.web-certificate`, with RunAtLoad and a 24-hour interval.
It copies the maintenance script outside the checkout, uses the private Certbot
runtime, and never replaces an existing job. It renews only when Certbot says
renewal is due; it does not force daily issuance. It does not alter the iPhone
renewal automation, wake/unlock either device, or run before user login.

`certificate-status.json` records check time, exit code and whether the leaf
certificate changed. Private provider logs have a size budget; command output
is capped at 256 KiB and each attempt at four minutes. If historical logs exceed
the budget, the next attempt first trims only owned private regular Certbot logs;
it preserves unrelated files, rejects symlinks, and keeps the separate bounded
command output. Old verbose failures cannot permanently starve renewal.
SIGTERM retires the owned
Certbot process group. A successful check with `certificateChanged: false` is
not evidence of a renewed expiration date. The companion checks chain content
once a minute, preloads replacement TLS material, and then reopens its listener.
Existing browser sessions reconnect without re-pairing after a certificate swap.

To stop checks, boot out only this user job and remove its plist from
`~/Library/LaunchAgents/`. Keep account keys/certificates if planning to resume.

## Validation boundaries

- `pnpm --filter @mac-remote-controller/web-remote-preview test` covers input
  ordering, gestures, acknowledgements, reconnect generations, held-input leases,
  media capabilities/selection, player-volume bounds, snapping and stale acks,
  desktop capability gating, action ordering and held-drag release.
- `swift test --package-path packages/web-gateway` covers admission, pairing,
  DNS publication and private-file policy.
- Apple CI also runs `test_transport.py` against `SofaRemoteWebFixture`: ephemeral
  trusted test certificate, real TLS/HTTP/WSS, input acknowledgements, disconnect
  release, media delivery/rejection, fixed desktop actions, restricted command
  scope and revocation.
  Mock players include a 400% volume range and unsupported controls. The fixture
  never imports AppKit, posts desktop input or plays audio.
- Physical iPhone/iPad Safari, touch latency, Mac application effects and a real
  certificate expiration/renewal cycle remain separate acceptance checks.

See [Certbot's Cloudflare plugin](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)
and [Let's Encrypt DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge).
