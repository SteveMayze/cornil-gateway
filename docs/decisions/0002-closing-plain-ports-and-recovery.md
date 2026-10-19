# ADR 0002: Closing the plain ports, host firewall, recovery tooling

Status: **Proposed** 2026-10-19 (steps below are requests and proposals; nothing here is applied except the tax upstream switch and the restore tooling)
Date: 2026-10-19

## Context
Both apps work through the gateway. The old plain-HTTP ports (8888 parts-db, 8889 old rootful tax, 8890 rootless tax) still answer on the LAN, measured from a LAN device. ADR 0001 found that the gateway cannot reach parts-db if it listens on loopback only.

## Decisions
1. **Applied:** `tax_upstream` is `tax-healthcare-tool-web:8000` (by container name on `gateway`). Verified before the switch; deploy idempotent; smoke passes.
2. **Requested (tax repo):** set `listen_address` to `127.0.0.1` (or drop `PublishPort`) and remove the plain-HTTP CSRF origin. Closes 8890.
3. **Owner's decision (tax repo workflow):** decommission the old rootful copy to close 8889.
4. **parts-db 8888:** not narrowed. Closed either by the later rootless move (joins `gateway`) or, until then, by the optional host firewall.
5. **Optional host firewall:** a separate nftables table `cornil_lan` dropping non-loopback traffic to 8888, 8889 and 8890 (raw prerouting), loaded by its own systemd unit. The distribution's `nftables.service` stays disabled because its stock file flushes all rules, which would remove Podman's. Proposal only; untested because it needs sudo; applied in two stages (runtime first).
6. **Recovery tooling (applied, no sudo):** `make restore-drill` and `make restore-caddy-data` restore Caddy's CA data from our own backups; `docs/recovery.md` documents CA loss, expiry, leaked key, rebuilt server. Backups remain manual.

## Consequences
- 8888 stays reachable on the LAN until the firewall is applied or parts-db is rootless.
- The firewall rule list must be edited when an app stops listening, and the unit removed when no port remains.
- Replacing the root certificate (leaked key or 2036 expiry) always means reinstalling on every device.
