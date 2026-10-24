# Chrome extension: YouTube and Bilibili

The Manifest V3 extension exposes typed playback, relative seek, player-volume,
and site-provided episode navigation for HTTPS `www.youtube.com`,
`www.bilibili.com`, and `bilibili.com` tabs. A tab is an explicit media source;
desktop focus does not select or switch the player. The extension reports next
and previous only when the site's episode controls are rendered and enabled,
and checks the selected control again before invoking it. It returns a visible
failure if a control disappears after selection.

The service worker connects to the separately built native messaging host. The
host reads the local bridge token from the companion's mode-0600 configuration
file and proxies only validated media messages over authenticated loopback
HTTP. The token never enters the extension, page, or content script. The bridge
accepts no desktop-input commands.

From the repository root, install the pinned workspace dependencies and build.
These commands require Node.js 26 or newer and the pnpm version declared in the
repository. The installer uses Node's JSON serializer to preserve spaces and
escape special characters in the native host path.

```sh
pnpm install --frozen-lockfile
pnpm --filter @mac-remote-controller/chrome-extension build
swift build -c release --package-path packages/apple-core --product SofaRemoteNativeHost
```

After enabling the media bridge in the Mac companion, load
`apps/chrome-extension/dist` through `chrome://extensions` → **Developer mode**
→ **Load unpacked**. Register the helper for your local Chrome profile with:

```sh
scripts/install-chrome-native-host.sh \
  "$(pwd)/packages/apple-core/.build/release/SofaRemoteNativeHost"
```

The installer pins the manifest to this extension's fixed public ID and writes
it under the current user's Chrome NativeMessagingHosts directory. It does not
install the extension or launch Chrome. Reopen the extension after installing
the native host. After first loading or reloading the extension, refresh any
YouTube or Bilibili tabs that were already open so Chrome injects the current
content script. Later native-host reconnects are handled by the service worker,
which requests fresh snapshots from registered tabs without waiting for another
page event. To remove this registration, delete
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.joeyteng.sofaremote.json`.

Website controls are implemented against the page's current `<video>` and
visible episode buttons. SPA navigation, BFCache restore, replaced video
elements, and tab closure refresh or remove the target. The extension does not
inject arbitrary JavaScript, run shell commands, or use keyboard shortcuts.
While the native messaging host is connected, the service worker asks each
registered tab for a current media snapshot every two seconds. This keeps the
target lease alive when Chrome throttles timers in a hidden, silent page. If the
native port disconnects or the host is unavailable, one retry timer starts at one
second, doubles up to a 15-second cap, and runs only while a media tab is
registered. After reconnecting, the worker asks those tabs for fresh snapshots;
pending actions are dropped and never replayed. Chrome 105 or newer is required
because that version keeps an extension service worker alive while its native
messaging port remains connected. A muted `<video>` is reported with effective
volume zero; a positive volume command unmutes it.

Site selectors can change without notice. Automated tests use DOM fixtures and
do not claim live-site compatibility for every account, layout, region, or
episode. Verify on the desired tab before relying on next/previous controls.
