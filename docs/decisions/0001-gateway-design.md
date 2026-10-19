# ADR 0001: Gateway design (rootless Caddy, shared network, ports)

Status: **Proposed** (the port setting and the parts-db connection test are awaiting the owner's approval)
Date: 2026-10-19

## Context
Two Django apps must be served under `https://cornil.fritz.box/parts-db` and `/tax-healthcare`. On 2026-10-07 one app's Caddy playbook overwrote the other's config. The host runs a legacy Caddy as a Debian package, owned by root, on ports 80 and 443. The tax app is moving to rootless Podman under the user `homeapps`. See `docs/design.md` section 1 for the inspected state.

## Decisions (owner-confirmed on 2026-10-19)
1. This repository is the only owner of the Caddy configuration. Apps contain no Caddy code.
2. Caddy runs as a rootless Podman container of `homeapps`. Routine deploys use no sudo.
3. Devices that will get the root certificate: MacBook Pro, iMac, iPhone, iPad, Windows machine.
4. Nothing else uses the proxy. The old ESP32 API route is dropped.
5. parts-db moves to rootless later, after the tax app has settled.
6. HSTS stays off.

## Decisions (proposed, pending approval)
7. **Reaching the tax app:** a shared rootless network `gateway` (Quadlet `gateway.network`), Caddy proxies to the container name on the app's internal port. The app eventually publishes no host port.
8. **Reaching parts-db:** `host.containers.internal` is the first candidate, host networking the fallback. **Not yet decided**: it must be proven by a real test on the host (design section 2). This ADR will be updated, not replaced, once tested.
9. **Ports 80 and 443:** set `net.ipv4.ip_unprivileged_port_start=80` once via a labelled sudo bootstrap step. Alternatives rejected: rootful Caddy (breaks no-sudo deploys), high ports plus forwarding (needs a firewall that does not exist).
10. **Cut-over:** G2 runs the new Caddy beside the old one on temporary ports 8080 and 8443. A separate sudo step backs up and stops the legacy `caddy.service` and then starts the new Caddy on 80 and 443. The legacy package and its files are not removed.
11. **Data directory:** `~/cornil-gateway/caddy-data` (0700, contains the CA private key); backups stay on the server or on the owner's own storage, never in the repo.
12. **Fresh CA** for the new Caddy unless Q2 shows an installed old root certificate is worth keeping.

## Consequences
- Gateway deploys need only SSH; sudo is limited to the bootstrap, the sysctl and the cut-over.
- Any local user can bind ports 80 and up once the sysctl is applied (accepted for a single-owner server).
- The gateway repo creates the `gateway` network, so it must be deployed before the tax app joins it.
- Until parts-db is rootless it stays reachable on the LAN at 8888 even after G3, unless a host firewall is added (optional proposal in G3).
- Rollback is stopping the user unit and re-enabling the legacy `caddy.service`.
