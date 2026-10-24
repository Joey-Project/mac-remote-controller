# Chrome extension: YouTube and Bilibili

The Manifest V3 extension exposes typed playback, relative seek, player-volume,
and site-provided episode navigation for HTTPS `www.youtube.com`,
`www.bilibili.com`, and `bilibili.com` tabs. A tab is an explicit media source;
desktop focus does not select or switch the player. The extension reports next
and previous only when the site's episode controls exist, and returns a visible
failure if a control disappears after selection.

The service worker connects to the separately built native messaging host. The
host reads the local bridge token from the companion's mode-0600 configuration
file and proxies only validated media messages over authenticated loopback
HTTP. The token never enters the extension, page, or content script. The bridge
accepts no desktop-input commands.

From the repository root, install the pinned workspace dependencies and build:

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
the native host. To remove this registration, delete
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.joeyteng.sofaremote.json`.

Website controls are implemented against the page's current `<video>` and
visible episode buttons. SPA navigation, BFCache restore, replaced video
elements, and tab closure refresh or remove the target. The extension does not
inject arbitrary JavaScript, run shell commands, or use keyboard shortcuts.

Site selectors can change without notice. Automated tests use DOM fixtures and
do not claim live-site compatibility for every account, layout, region, or
episode. Verify on the desired tab before relying on next/previous controls.
