# Chrome Extension (Placeholder)

This package contains a minimal Manifest V3 service worker scaffold. It does not implement remote control and requests no Chrome or website permissions.

The development toolchain targets Node 26 and pnpm 12.14.0. It pins Oxlint 1.88.0 with `oxlint-tsgolint` 7.0.2004 for type-aware linting, and TypeScript 7.0.2 for the separate `tsc --noEmit` check. Keep the TypeScript compiler and type-aware linter versions aligned when upgrading this toolchain.

From the repository root, install the workspace dependencies and build the extension:

```sh
pnpm install --frozen-lockfile
pnpm --filter @mac-remote-controller/chrome-extension build
```

In Chrome, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select `apps/chrome-extension/dist`.

Add permissions only alongside a feature that requires them. The placeholder intentionally has none.
