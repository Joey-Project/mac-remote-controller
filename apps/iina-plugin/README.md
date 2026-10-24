# IINA plugin

`pnpm --filter @mac-remote-controller/iina-plugin build` creates
`apps/iina-plugin/dist/SofaRemote.iinaplugin`. In IINA, install that package
using **Settings → Plugins → Install from file**, then enable the companion's
local media bridge and copy its token into the plugin's preferences. The plugin
uses HTTP polling against `127.0.0.1:47623`; it does not open a listener.

Each IINA player window creates and reports its own exact target ID. Playback,
relative seek, playlist next/previous, and player volume use IINA's supported
Plugin API. Playlist controls are unavailable when the current playlist has at
most one item. The player volume control uses mpv's `volume-max` value and
reports the actual volume and maximum separately from Mac system volume.

The token is stored only in local plugin preferences and companion-owned
mode-0600 configuration. It is not sent to web pages and is not written to
plugin logs. The plugin retries the local bridge after it is unavailable and
unregisters its window target when IINA closes it. Automated checks use mocks;
they do not launch IINA or play audio.
