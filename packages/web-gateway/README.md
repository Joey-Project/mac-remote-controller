# Web Remote Support

Mac-only foundations for a browser-trusted HTTPS remote endpoint. Native
AppleCore transport and helper dependencies remain separate.

This package currently validates explicit private-LAN endpoint configuration and
publishes changes to one verified Cloudflare DNS-only A record. It does not yet
start an HTTPS listener or authorize browser commands.

The DNS publisher requires a separately supplied token. Tokens are not part of
the Codable configuration and must not be logged or committed. Callers must
validate decoded configuration, serialize address observation, apply bounded
backoff after errors, and re-read an ambiguously updated record before retrying.

```bash
swift test --package-path packages/web-gateway
```

Live transport and certificate maintenance must be completed and tested before
this package can provide no-install Mac control.
