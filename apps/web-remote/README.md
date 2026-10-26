# Web interaction preview

This small TypeScript page is an **offline UI exploration**, not a remote-control
client. It lets you feel the touchpad, keyboard, and volume layout in Safari or
another browser without installing an app. The cursor, click counters, scroll,
key presses, typed text, and volume slider affect only this tab's local preview.

The page has no Mac connection workflow, endpoint field, invitation parser,
credential input, network transport, persistent browser storage, or screen
mirroring. Reload or close the tab to clear the preview state. It does not claim
to test pairing, security, command delivery, or physical-device behavior.

## Interaction

- Drag in the touch surface to move the local cursor; a short tap increments the
  local left-click counter.
- The click buttons, mouse wheel, volume slider, and keyboard buttons update
  local preview state only. The scroll readout shows cumulative direction and
  distance in CSS pixels. Pixel wheel input is preserved; line input uses the
  touch surface's explicit 24 CSS-pixel preview line, and page input uses the
  document layout viewport height.
- A second pointer switches the preview to scroll. Additional pointers are
  ignored. Pointer cancellation, lost pointer capture, window blur, and page
  deactivation clear the active gesture.
- Window keyboard shortcuts run only when focus is outside interactive controls
  and no Shift, Alt, Control, or Command modifier is held. Enter and unmodified
  Space remain available in the preview; focused controls keep their native
  activation, and modified browser shortcuts such as Shift+Space remain
  untouched.
- The touch surface accepts primary-button pointer input. Secondary and middle
  mouse/pen buttons do not count as taps; multiple touch pointers remain
  available for two-finger scroll preview.
- The text caption counts grapheme characters when `Intl.Segmenter` is
  available. Its fallback counts and labels Unicode code points.

## Development

The package uses the repository's pinned TypeScript, esbuild, and Oxlint
versions. The root pnpm workspace and CI run its `lint`, `typecheck`, `test`,
and `build` scripts alongside the native adapters. For focused local checks, use
`pnpm --filter @mac-remote-controller/web-remote-preview <script>` from the
repository root. `dist/` and package-local `node_modules/` are ignored.

## Web-control feasibility

The existing native pairing design cannot be used directly by a Safari SPA
without changing its trust model. See the focused
[web transport feasibility note](../../docs/project_journal/2026/10/2026-10-24-web-remote-feasibility-01a1464a.md)
for the protocol gap, App Clip tradeoffs, and the minimum prerequisites for a
future trusted gateway.
