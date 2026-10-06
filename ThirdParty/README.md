# Third-party source and provenance

## idevice

Vendored crate: `idevice/`, by Jackson Coxson, MIT (`idevice/LICENSE.txt`).
Upstream: https://github.com/jkcoxson/idevice
Snapshot: `d32c8189c51c2789496b0768039419c3705498c3`.

Tracked crate files are included; upstream Git history, caches and unrelated tools are excluded. Local changes:

- `src/remote_pairing/tls_psk.rs`: expose server Finished verification, fix pending/partial asynchronous writes, handle empty writes, and add regression tests. Phone History refuses the developer tunnel if Finished verification fails.
- `src/services/dvt/remote_server.rs`: expose `call_method_with_reply` for generic read-only queries.
- `src/services/heartbeat.rs`: expose a receive-message helper.

The crate's original README may describe upstream tools outside this vendored subset. Phone History builds only the crate and the features in `Core/Cargo.toml`.

## LocalDevVPN / StosVPN

Phone History **uses code from LocalDevVPN** by Stossy11 and the SideStore Team.
Upstream: https://github.com/jkcoxson/LocalDevVPN
Snapshot reviewed/adapted: `af3fd697803ada4ac2b8d518358f5ab0a534844c`.

The local packet route and packet transport in `Tunnel/PacketTunnelProvider.swift` adapt `TunnelProv/PacketTunnelProvider.swift`. The full StosVPN License is retained in `LocalDevVPN-LICENSE`, bundled in the app, and attributed in the root README and About screen. Its attribution/branding terms apply to that adapted code; the project's MIT license does not override them.

No StikDebug source is vendored or copied. Dependency references alone do not grant permission to copy differently licensed code.
