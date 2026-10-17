# Chrome Extension (Placeholder)

This package contains a minimal Manifest V3 service worker scaffold. It does not implement remote control and requests no Chrome or website permissions.

The development toolchain targets Node 26 and pnpm 12.14.0. TypeScript is pinned to 6.0.3, the newest version supported by `typescript-eslint` 8.71.2; TypeScript 7 is outside its declared `<6.1` peer range.

From the repository root, install the workspace dependencies and build the extension:

```sh
pnpm install --frozen-lockfile
pnpm --filter @mac-remote-controller/chrome-extension build
```

In Chrome, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select `apps/chrome-extension/dist`.

Add permissions only alongside a feature that requires them. The placeholder intentionally has none.
