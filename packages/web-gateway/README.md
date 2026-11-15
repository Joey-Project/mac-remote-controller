# Web Remote Support

Mac-only browser-trusted HTTPS/WSS remote endpoint. Native
AppleCore transport and helper dependencies remain separate.

The gateway validates an explicit private-LAN binding, uses a dedicated SwiftNIO
I/O thread, serves bounded same-origin requests, and grants an input-only Web
peer after Mac-displayed four-digit pairing. Secure HttpOnly cookies never enter
wire messages. Native command ordering, paired-device revocation and held-input
cleanup are reused by the companion. Browser peers cannot request privileged
session/display operations or media/system shortcuts.

The DNS publisher requires a separately supplied token. Tokens are not part of
the Codable configuration and must not be logged or committed. Callers must
validate decoded configuration, serialize address observation, apply bounded
backoff after errors, and re-read an ambiguously updated record before retrying.

```bash
swift test --package-path packages/web-gateway
```

`SofaRemoteWebFixture` exercises the same transport with in-memory authorization
and mock effects. It never imports AppKit or posts desktop events. Its explicit
loopback test mode is not used by the Mac app. Apple CI drives real TLS/HTTP/WSS
with an ephemeral trusted test certificate, including release and revocation.

See [Web setup and certificate maintenance](../../tooling/web_remote/README.md).
