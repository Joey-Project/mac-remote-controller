# IINA plugin

Choose **Set Up IINA** in the Mac companion. It writes the bridge port and token
into this plugin's private local preferences, preserving other settings, and opens
the bundled package in IINA. Confirm IINA's installation and permission prompt;
IINA then installs and enables the plugin. No token copying is needed. For an
existing plugin, approve replacement and choose **Plugin → Reload All Plugins**
or restart IINA to load the updated plugin code. Open a video, then select its
IINA media source on the phone. The companion remembers the bridge opt-in across
relaunches; disabling it keeps it off on subsequent launches.

## Manual development setup

`pnpm --filter @mac-remote-controller/iina-plugin build` creates
`apps/iina-plugin/dist/SofaRemote.iinaplugin`. Package that directory with IINA's
CLI, running from the output directory:

```sh
cd apps/iina-plugin/dist
/Applications/IINA.app/Contents/MacOS/iina-plugin pack SofaRemote.iinaplugin
```

Open the generated `SofaRemote.iinaplugin-0.1.0.iinaplgz` with IINA to install it,
then enable the companion's local media bridge and copy its token into the
plugin's preferences. Keep **Bridge port** at `47623` unless the companion shows
a different port. The plugin uses HTTP polling against `127.0.0.1:47623`; it does
not open a listener.

Each IINA player window creates and reports its own routing ID. The ID
distinguishes windows but is not an authentication secret; the companion-issued
bridge token authenticates requests. Playback, relative seek, playlist
next/previous, and player volume use IINA's supported Plugin API. Playlist
controls are unavailable at the relevant playlist boundary, and availability
is checked again when a command executes. Every command also checks that
playback is still active before changing player state, seeking, navigating, or
setting volume. The plugin converts mpv's
percentage-based volume and
`volume-max` to the protocol's gain ratio (`1.0` means 100%) before reporting
the current value and maximum. Incoming gain ratios are converted back to mpv
percentages only when applying a volume command. A muted IINA window reports
effective player volume as 0; an explicit positive player-volume command sets
the requested volume and clears IINA mute, while a zero command leaves mute
unchanged. Mac system volume remains a separate control.

IINA's `iina.http.post` forwards `options.data` through Just's form-encoded
request path. The plugin sends one `payload` field containing the JSON message;
the loopback bridge accepts this bounded single-field form only on IINA POST
routes. Chrome continues to send JSON directly.

The token is stored only in local plugin preferences and private mode-0600
configuration. It is not sent to web pages or written to plugin logs. **Set Up
IINA** also writes `@data/bridge.json` in this plugin's private data directory.
The companion refreshes this file when restoring an already configured bridge.
IINA caches its preferences in memory, so the plugin reads the managed file on
startup and after a failed bridge request, then updates only its cached port
and token. Healthy polling adds no file reads. A bridge restart or credential
change therefore does not require another plugin restart.

Each polling cycle still reads the cached port/token preferences, preserving
manual setup when no managed file exists. Missing or invalid settings cause no
bridge request; while waiting, the plugin also checks for newly published setup.
Managed reads are bounded to 4 KiB and need no additional plugin permission.

When the queue is empty, the plugin polls every 250 ms. Each poll refreshes the
target and drains up to eight queued commands without a per-command polling
delay. A full batch yields to IINA's event loop before another bounded batch;
the plugin does not locally replay completed commands. It retries the local
bridge after it is unavailable and unregisters its window target when IINA
closes it. Automated checks use mocks; they do not launch IINA or play audio.
