# IINA plugin

`pnpm --filter @mac-remote-controller/iina-plugin build` creates
`apps/iina-plugin/dist/SofaRemote.iinaplugin`. In IINA, install that package
using **Settings → Plugins → Install from file**, then enable the companion's
local media bridge and copy its token into the plugin's preferences. The plugin
uses HTTP polling against `127.0.0.1:47623`; it does not open a listener.

Each IINA player window creates and reports its own routing ID. The ID
distinguishes windows but is not an authentication secret; the companion-issued
bridge token authenticates requests. Playback, relative seek, playlist
next/previous, and player volume use IINA's supported Plugin API. Playlist
controls are unavailable at the relevant playlist boundary, and availability
is checked again when a command executes. The plugin converts mpv's
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

The token is stored only in local plugin preferences and companion-owned
mode-0600 configuration. It is not sent to web pages and is not written to
plugin logs. The plugin retries the local bridge after it is unavailable and
unregisters its window target when IINA closes it. Automated checks use mocks;
they do not launch IINA or play audio.
