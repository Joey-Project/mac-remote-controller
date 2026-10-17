# Chrome Extension (Placeholder)

This package contains a minimal Manifest V3 service worker scaffold. It does not implement remote control and requests no Chrome or website permissions.

From the repository root, install the workspace dependencies and build the extension:

```sh
pnpm install --frozen-lockfile
pnpm --filter @mac-remote-controller/chrome-extension build
```

In Chrome, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select `apps/chrome-extension/dist`.

Add permissions only alongside a feature that requires them. The placeholder intentionally has none.
