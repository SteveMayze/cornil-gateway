# Design: the cornil gateway (G1)

Status: **proposed**. Nothing here has been applied to the host. The port setting in section 3 needs the owner's approval first.

New to Podman or systemd? Read [`podman-explained.md`](podman-explained.md) first (copied from the tax repo; the tax repo's copy is the original). Terms are explained again here only where this design needs them.

## 1. What exists today (read-only inspection, 2026-10-19)

| Item | Finding |
|---|---|
| Host | Debian 13 (trixie), Podman 5.4.2, systemd 257, netavark and aardvark-dns installed, rootless networking helper `pasta` installed and in use |
| Caddy today | **A Debian package (2.11.2), run by the system's systemd as the user `caddy`.** Not a container. It is the old ESP32-experiment Caddy |
| Its files | `/etc/caddy/Caddyfile` plus three dated backups (root-owned); data in `/var/lib/caddy` (owned by `caddy`, mode 0700, so the service user cannot read it, which is correct) |
| Its current config | Four lines sending `/parts*`, `/admin*`, `/static*` to port 8888 and `/` to `/parts/`. This is what the 2026-10-07 playbook left behind. The `local_certs` option and the API route are gone, so **HTTPS on 443 currently fails** (the TLS handshake is refused); plain HTTP on 80 answers with a redirect |
| Ports | 80 and 443: old Caddy. 2019 (Caddy's admin interface, localhost only): old Caddy. 8888: parts-db (all interfaces). 8889: tax app, **old rootful copy**. 8890: tax app, **new rootless copy** (a trial, see below). 22: SSH |
| parts-db | Rootful Quadlet unit in `/etc/containers/systemd/`, publishes 8888 on all interfaces, plain HTTP |
| Tax app | Two copies are running. The old rootful unit still serves 8889. The rootless unit under `homeapps` (`systemctl --user`) serves 8890 and is healthy. So the "Part B switch" in `podman-explained.md` section 7 has **not yet been done** |
| Service user | `homeapps`: linger on, has a subordinate id range, only the default Podman network exists, cgroup controllers `cpu memory pids` delegated |
| `net.ipv4.ip_unprivileged_port_start` | `1024` (the Linux default) |
| Firewall | none installed |

Things the inspection turned up that are not part of the design but the owner should know:

- A secret value (an API token) sits in plain text in the old Caddy service definition, and the parts-db Django secret key sits in a world-readable unit file. Neither is copied into this repo or these docs. See the report for what to do.
- The old Caddy's data directory still holds the internal CA from January 2026 (made when `local_certs` was set). If any device already trusts that root certificate, it will **not** trust the new Caddy's CA. See open question Q2.

## 2. How Caddy reaches each app

**Plain-language background.** A container has its own private network. Inside Caddy's container, `127.0.0.1` means "Caddy itself", not the server. So Caddy needs an address for each app. Two ways:

1. **Shared network, reach by name.** Put Caddy and the app on one private Podman network. Podman's name service lets Caddy say `tax-healthcare-tool-web` and find the app. The app needs no port published on the server at all, so nothing on the home network can reach it except through Caddy. Possible only when both containers belong to the same user (a network belongs to one user's Podman).
2. **Go out to the server and come back in.** Caddy connects to the server's own address and the app's published port. Needed when the app lives under a different user.

### Tax app (rootless, `homeapps`): shared network

- The gateway repo owns a Quadlet network file `gateway.network` (a rootless network called `gateway`, created by `homeapps`' Podman).
- Caddy's unit has `Network=gateway.network`. The tax app's unit gets the same line (a change in the tax repo, written as a request in section 7).
- Caddy proxies to `tax-healthcare-tool-web:8000` (the app's port *inside* its container).
- Until G3 the tax app keeps its published port for the old plain-HTTP access. At G3 it drops `PublishPort` entirely.
- Effect on `listen_address`: with no published port, the variable no longer applies; during the transition it stays as it is.

### parts-db (rootful until migrated): to be decided by a real test

parts-db belongs to root, so it is on a different Podman and cannot join `gateway`. Three candidates:

| Option | How | Concern |
|---|---|---|
| A. `host.containers.internal` | Caddy's container is given the name of "the server itself" and connects to its port 8888 | In rootless Podman 5 with `pasta`, whether this reaches a port that is published by the *rootful* Podman, and whether it still works after parts-db is narrowed to `127.0.0.1` (G3), must be proven |
| B. Host networking for Caddy | Caddy shares the server's network directly and uses `127.0.0.1:8888` | Simple, but Caddy then sits on the server's network without isolation, and reaching the tax app by name no longer works (it would need the tax app's published port) |
| C. Second route via the server's LAN address | Caddy connects to the server's own LAN address | Depends on an address that can change; not recommended |

**Plan:** test A first, then B if A fails, **on the host with a throw-away container** and write the results in the ADR. I have not run this: it creates a temporary container and network under `homeapps`, which is a change on the host, so it needs the owner's go (Q4). The test is:

1. As `homeapps`: start a temporary container on a temporary network. From inside it, `curl` `http://host.containers.internal:8888/` and expect a response from parts-db (a redirect to its login is fine).
2. Repeat with parts-db's port bound only to `127.0.0.1` on a **spare** port (a second throw-away rootful container needs sudo, so the owner runs it; exact command to be given), to learn whether A survives G3.
3. Remove the temporary container and network.

Outcome rule: if A works for both cases, use A. If it works only while parts-db listens on all interfaces, parts-db stays that way until it is migrated to rootless (at which point it joins `gateway` and this problem disappears), with the LAN-side exposure accepted until then and reduced by an optional host firewall (G3 proposal). If A fails outright, use B for Caddy and say so.

## 3. Ports 80 and 443 without root

Normal users may not listen on ports below 1024. Our URLs have no port number, so Caddy must have 80 (HTTP) and 443 (HTTPS). Options:

| Option | What it is | Trade-off |
|---|---|---|
| **1. Lower the limit (recommended)** | One server setting, `net.ipv4.ip_unprivileged_port_start=80`, in a file in `/etc/sysctl.d/` and applied once | Any ordinary user on the server could then listen on any port from 80 up. Acceptable on a single-owner home server where `homeapps` and the owner are the only users. 80 (not 0) keeps ports 1 to 79, which include well-known system ports such as 22 (SSH), unprivileged-proof. Effect is permanent across reboots |
| 2. Run Caddy rootful | Caddy as a root-owned container | Every gateway deploy would need sudo again; breaks the "no sudo for routine deploys" decision. Not recommended |
| 3. Caddy on high ports plus a redirect | Caddy on 8080 and 8443, with a firewall rule forwarding 80 and 443 | There is no firewall configured today; adding one only for this is more moving parts than option 1 |

**Recommendation: option 1.** It is a **one-time sudo step** in the bootstrap, labelled as such. It changes exactly one thing on the server: it adds one small file, `/etc/sysctl.d/90-unprivileged-ports.conf`, containing the line above, and applies it with `sysctl --system`. To undo: delete the file and run `sudo sysctl --system` (or reboot).

**Not applied. Needs the owner's approval (Q3).**

**A conflict to plan for:** today the old Caddy package holds ports 80 and 443, so the new Caddy cannot take them until the old one is stopped. Therefore:

- G2 builds and tests the new Caddy **beside** the old one on temporary high ports (8080 and 8443), which needs no sysctl and no sudo.
- A separate, clearly labelled **cut-over** step (sudo, owner runs it) then: backs up the old Caddy's files, stops and disables the old `caddy.service` (without removing the package or its files), applies the sysctl, and starts the new Caddy on 80 and 443. HTTPS is already broken on the host today, so the visible interruption is small.

## 4. Who runs Caddy, and where its files live

- **User:** `homeapps` (owner decision), as a rootless container run by that user's systemd, deployed with an SSH key and no sudo.
- **Unit:** `~/.config/containers/systemd/caddy.container` and `gateway.network`, written by this repo's playbook only. Image: the official `caddy` image, pinned to a version.
- **Rendered Caddyfile:** `~/cornil-gateway/config/Caddyfile`, mounted read-only. Written only by this repo's playbook.
- **Data directory (important):** `~/cornil-gateway/caddy-data`, mounted as `/data`, mode 0700, owned by `homeapps`. It holds Caddy's internal CA **including its private key**. Losing it means installing a new root certificate on every device; leaking it means someone could make certificates your devices trust.
- **Admin interface:** Caddy's admin API stays inside the container and is not published. Reloads use `podman exec ... caddy reload`.

### Backup of the data directory

- `make backup-caddy-data` runs on the server as `homeapps`: stops nothing, copies the directory into a dated archive in `~/cornil-gateway/backups/` (mode 0600), keeps the newest few, and prints the name.
- The archive contains the private key, so it is treated as a secret: it stays on the server, or is copied by the owner to their own encrypted storage. It is never fetched into this repo (`backups/` is git-ignored as a second safeguard).
- Before the cut-over: the old Caddy's `/etc/caddy` and `/var/lib/caddy` are copied to a dated folder under `/root` or a root-only folder by a sudo command the owner runs. Its location is reported. The old CA key stays there and is not read by me.

## 5. Certificates

`tls internal` makes Caddy act as its own tiny certificate authority and issue a certificate for `cornil.fritz.box`. Browsers trust it only if the CA's **public** root certificate (`root.crt`) is installed on the device. `make root-cert` fetches only that public file. Devices: MacBook Pro, iMac, iPhone, iPad, Windows machine (steps in `docs/trust-root-cert.md`, G2). HSTS stays off.

## 6. Rollback

| Stage | How to go back |
|---|---|
| During G2 (parallel, high ports) | `systemctl --user stop caddy` as `homeapps`. Nothing else changed |
| After the cut-over | `systemctl --user disable --now caddy` as `homeapps`; then, as the owner: `sudo systemctl enable --now caddy` restarts the old Caddy with its files untouched, and (optionally) delete the sysctl file. The old plain-HTTP app ports keep working throughout until G3 |
| Bad Caddyfile on deploy | The playbook validates before applying, keeps the previous Caddyfile, and restores it if validation or reload fails |
| CA lost or key leaked | Recovery procedure written in G3: new CA, new root certificate on every device |

## 7. What the apps must provide (requests for their own sessions)

Not done by this repo.

**Tax repo (Tax-and-KK-Tool):**
- Join the network: add `Network=gateway.network` to its Quadlet unit (the network is created by this repo; deploy order is gateway first).
- Set `DJANGO_BEHIND_TLS_PROXY=1`, `DJANGO_CSRF_TRUSTED_ORIGINS=https://cornil.fritz.box`, and keep `DJANGO_URL_PREFIX=/tax-healthcare` and its own cookie names. Its current trial unit says http and 8890, which is correct for the trial only.
- At G3: remove `PublishPort`.
- Finish Phase 9A's cut-over (`podman-explained.md` section 7, part B) so one rootless copy serves the live data, before the gateway points at it.

**parts-db repo (Part B of GATEWAY.md):** prefix `/parts-db`, own cookie names, proxy-aware settings, remove all Caddy tasks. A later separate step moves it to rootless and onto the `gateway` network.

## 8. Open questions

- **Q1.** Tax cut-over: should the rootless copy on 8890 become the live app on 8889 before the gateway is built, or should the gateway target the 8890 copy for now? (Default: finish the cut-over first.)
- **Q2.** Did you ever install the January 2026 root certificate on a device? (Default: no. A fresh CA is created and the old one is left alone.)
- **Q3.** Approve the port setting (`ip_unprivileged_port_start=80`) as a one-time sudo step? (Default: not applied until you say yes.)
- **Q4.** May I run the throw-away `host.containers.internal` test as `homeapps` (creates and removes one temporary container and network)? (Default: no, not until you say yes.)
