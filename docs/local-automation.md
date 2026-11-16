# macOS local automation

The companion exposes its app-defined controls through a current-user Unix
socket. The bundled `SofaRemoteControl` CLI returns versioned JSON and delegates
actions to the same controllers used by the menu-bar UI. No TCP port or remote
automation service is added, and pointer/keyboard processing does not call this
interface.

## Use the installed companion

```sh
control="$HOME/Applications/SofaRemoteMac.app/Contents/Helpers/SofaRemoteControl"
"$control" status
"$control" list
"$control" get web.enabled
"$control" invoke web.reload
"$control" invoke web.enabled --value true
"$control" invoke media.manualExpanded --value true
"$control" invoke recovery.chooseSetup --path /absolute/path/to/configuration-private.json
```

The companion must be running. The endpoint is
`~/Library/Application Support/SofaRemote/Automation/control.sock`; its directory
must be owned by the current user with mode `0700`, and the socket has mode
`0600`. Both sides verify the peer's effective UID. Other users and network
clients cannot use the interface. Processes running as the same user can request
the operations below, including clipboard, device removal and quit.

`list` returns stable IDs, labels, kinds, conditional visibility, enabled state
and non-secret values. Per-device entries also include `deviceID`. These IDs
are shared with the SwiftUI accessibility identifiers. Visibility describes
whether the app would render that control in its current state; it does not
require the menu-bar popover to be open or claim that a control is onscreen.
Use native UI automation for popover presentation and visual layout acceptance.

## Controls

| Group               | IDs                                                                      | Arguments / behavior                                                                                                                                                      |
| ------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Accessibility       | `accessibility.request`                                                  | Opens the existing system permission flow.                                                                                                                                |
| Media adapters      | `media.enabled`, `media.setupIINA`, `media.setupChrome`                  | The toggle takes `--value true` or `false`; setup keeps the IINA/Chrome confirmation flows.                                                                               |
| Manual media setup  | `media.manualExpanded`, `media.copyToken`                                | Expand the disclosure first, then copy the token using the existing concealed clipboard operation. The token is never returned in JSON.                                   |
| Unlock setup        | `unlock.manage`, `unlock.uninstall`, `unlock.enabled`                    | Install/update/repair is chosen from the same UI state; administrative actions still require the normal system dialog.                                                    |
| Paired devices      | `device.unlock`, `device.remove`                                         | Both require an exact current `--device ID`; the unlock toggle also requires `--value true` or `false`.                                                                   |
| Phone recovery      | `recovery.chooseSetup`, `recovery.reinstall`                             | An optional absolute `--path` selects the same private JSON setup directly; without it the normal file chooser opens. Reinstall uses the accepted recovery configuration. |
| Web service         | `web.enabled`, `web.reload`, `web.open`, `web.copyURL`, `web.openFolder` | The toggle requires a Boolean value. Other actions reuse the existing browser, clipboard and Finder behavior.                                                             |
| QR pairing          | `pairing.qr.open`, `pairing.qr.close`, `pairing.qr.copy`                 | Existing lifetime, one-use enrollment and clipboard behavior are retained.                                                                                                |
| Native code pairing | `pairing.numeric.cancel`, `pairing.mac.code`                             | Cancel also covers closing the pairing window; use explicit `get` for the currently displayed code.                                                                       |
| Web code pairing    | `pairing.web.cancel`, `pairing.web.code`                                 | Cancel also covers closing the Web pairing window; use explicit `get` for its code.                                                                                       |
| Application         | `app.quit`                                                               | Uses normal termination, including held-input release checks.                                                                                                             |

Every app-defined button, toggle and disclosure is registered, together with the
two read-only pairing-code values. The UI coverage test rejects missing/duplicate
IDs and unregistered controls when new app sources are added. App-owned controls
delegate to their existing business logic. macOS authorization dialogs, file
chooser widgets, IINA installation and Chrome extension enablement remain owned
by those applications; the API does not approve them.

## Results and limits

- `ok` is a successful query. `accepted` means the action was admitted, not that
  an asynchronous installation, reload or system dialog has finished. Query
  `status` for each controller's busy flag, outcome/message and current state.
- Hidden or disabled controls return `unavailable`; all actions require a
  verified unlocked login session. Unknown state also blocks actions. The API
  does not add a local unlock command or bypass existing helper authorization.
- `get pairing.mac.code` and `get pairing.web.code` return a code only while
  that prompt is current and the Mac is unlocked. Ordinary `status`/`list` never
  include pairing codes, QR invitations or bearer tokens. Do not publish explicit
  pairing-code responses or private device/status data in logs or PRs.
- Requests use one JSON line per connection, schema version `1`, at most 16 KiB.
  Responses are bounded to 64 KiB. There are at most eight concurrent clients
  and a three-second transport deadline. An expired queued action is rejected
  before execution. The CLI performs no automatic retry; a lost acknowledgement
  does not prove that an admitted action failed.
- CLI exit codes are `0` for `ok`/`accepted`, `1` for a returned failure and `2`
  for invalid CLI arguments or a transport/protocol error.
- A stale owner-private socket can be recovered. An active listener, symlink,
  ordinary file or insecure directory is preserved and refused. Shutdown only
  removes the matching socket object created by that server. An owner-private
  `control.sock.lock` file serializes cooperating instances through startup and
  cleanup, preventing an old instance from removing its replacement's socket.
  The empty lock file is retained; do not delete it while a companion is running.

The direct wire form for a reload is:

```json
{ "version": 1, "operation": "invoke", "control": "web.reload" }
```

Other operations are `status`, `list` and `get`. Optional argument fields are
`value`, `deviceID` and `path`, all strings. Unknown keys, unsupported versions
and inappropriate arguments fail admission. Test clients may select a separate
owner-private endpoint with `--socket /absolute/path/control.sock`.

## Development checks

```sh
swift test --package-path packages/apple-core --filter LocalAutomation
python3 -m unittest discover -s tooling/automation -p 'test_ui_coverage.py' -v
python3 tooling/automation/test_cli.py --binary /path/to/SofaRemoteControl
```

The socket tests use private temporary directories and fake handlers. CLI tests
use a real Unix socket and the compiled executable. They never invoke production
setup, grant a permission, remove a device, renew/install an app or read an Apple
account session. `tooling/swift/check.sh` also exercises CLI integration and
builds/signs the nested universal executable with the Mac app.
