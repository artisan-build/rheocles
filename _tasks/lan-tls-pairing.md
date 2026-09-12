# LAN binding, TLS, and the shared pairing module (v0.2)

**Deferred (spec §11, §17): designed in, not built.** The MVP is loopback
only, bearer token, no TLS. v0.2 is LAN: TLS with a self-signed certificate
and approve-on-the-box pairing — Rheocles on Bonjour, the capture box shows
"Allow *Len's MacBook*?", one click pins the certificate and issues a token.

**Hooks already in place.**

- The bind address is one field (`Rheocles.defaultBindHost`,
  `Server.Configuration.host`), so binding `0.0.0.0` instead of `127.0.0.1`
  is a config change, not a rewrite.
- `BearerAuth` is a shared, rotatable object; a pairing module would mint and
  revoke tokens through it.
- Both transports build their `NWParameters` in one place each; adding
  `NWProtocolTLS.Options` with a pinned identity is localized to those two
  inits.

**What's missing:** the certificate module (generate/store a self-signed
identity), the Bonjour advertisement, and the approve-on-the-box pairing UI +
its endpoint. Sonocles will be retrofitted to the same shared module — one
design, two apps — so build it as a package boundary, not inline.
