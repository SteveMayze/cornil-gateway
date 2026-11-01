# G3: closing the plain-HTTP ports 8888, 8889 and 8890

**Status: proposal plus exact requests. Nothing in this file has been applied.** Measured today from a LAN device (the Mac): ports 80 and 443 answer (the gateway); 8888 (parts-db), 8889 (old rootful tax copy) and 8890 (rootless tax copy) also answer over plain HTTP. After the steps below only 80 and 443 (and 22 for SSH) answer.

Why close them: the gateway is the only front door that gives you HTTPS. The old ports bypass it, send passwords and data unencrypted across your home network, and let anyone on it reach the apps directly.

## What each port is and how it closes

| Port | What listens | How it closes | Who does it |
|---|---|---|---|
| 8890 | rootless tax app (`homeapps`) | Remove its host port. Caddy does not use it: it reaches the app by name on the `gateway` network (verified) | Tax repo session (request below) |
| 8889 | old **rootful** tax app | Stop and remove the old rootful copy: the "Part B" and later "removal" sections of `podman-explained.md` (§7, §8). Needs sudo, your decision, and only after the final data copy was verified | You, in the tax repo's workflow |
| 8888 | parts-db (rootful, **no longer used by the gateway since ADR 0003**) | Closable now by the parts-db repo / you. Earlier finding: **cannot be narrowed to localhost while the gateway used it.** My test showed Caddy's route (`host.containers.internal`) fails if parts-db listens on `127.0.0.1` only. Either (a) move parts-db to rootless and onto the `gateway` network (the planned later step), or (b) block 8888 from the LAN with the host firewall below, which still lets Caddy reach it | parts-db session / you |

Recommended order: tax 8890 first (no risk), then the firewall for 8888 and 8889 until they are gone for real, then parts-db to rootless and remove the firewall rule for it.

## Exact request for the tax repo (8890)
Paste `docs/prompts/TAX-CLOSE-PORT-REQUEST.md` into the tax session. In short: set `listen_address: 127.0.0.1` (the published port `8890` then listens on the server's own loopback only: the LAN is refused, `curl http://127.0.0.1:8890/health/` on the server still works for debugging) or remove `PublishPort` altogether; remove the plain-HTTP origin from `DJANGO_CSRF_TRUSTED_ORIGINS`; keep `DJANGO_BEHIND_TLS_PROXY=1`.

## parts-db (8888)
**Update 2026-11-01 (ADR 0003):** the gateway now reaches the rootless `parts-db-web` by name (`partsdb_upstream: parts-db-web:8000`), so it no longer uses port 8888. The rootful container on 8888 can now be closed by the parts-db repo / you (stop and remove it, or narrow it to `127.0.0.1`). Do that only after you have checked `/parts-db/` through the gateway, because the rollback value (`host.containers.internal:8888`) needs it running. Nothing has been applied here.

## Optional host firewall (proposal, needs your approval and sudo)

**Plain-language background.** A firewall is a list of rules the server applies to network traffic before any program sees it. Linux's current one is called nftables. Right now the server has the tools installed but no rules of ours. The rule below says: *traffic arriving from the home network to ports 8888, 8889 or 8890 is dropped; traffic from the server to itself is allowed*. Caddy talks to parts-db from the server itself, so it keeps working. SSH (22), 80 and 443 are not mentioned and stay open. This does **not** change the default policy, so it cannot lock you out of SSH.

**What it changes:** adds a file `/etc/cornil/lan-ports.nft` and, in stage 2, a systemd unit `cornil-lan-ports.service`. It does **not** enable the distribution's `nftables.service` (whose stock file starts with `flush ruleset` and would wipe Podman's own rules). It uses its own table `cornil_lan`, which nothing else touches.

**Untested.** I could not apply it (no sudo), so the rule is syntax-checked on your server by the first command and tested by you at stage 1. Stage 1 is not permanent: a reboot or the undo line removes it.

`/etc/cornil/lan-ports.nft`:
```
table inet cornil_lan
delete table inet cornil_lan
table inet cornil_lan {
    chain stop_direct_app_ports {
        type filter hook prerouting priority raw; policy accept;
        iifname != "lo" tcp dport { 8888, 8889, 8890 } drop
    }
}
```
(`priority raw` runs before Podman's address translation, so the rule sees the original port for both rootful and rootless containers. `inet` covers IPv4 and IPv6. The first two lines make the file safe to load repeatedly.)

Stage 1, temporary (run on the server with your admin login):
```
sudo mkdir -p /etc/cornil                      # a folder for this one file
sudoedit /etc/cornil/lan-ports.nft             # paste the file above
sudo nft -c -f /etc/cornil/lan-ports.nft       # CHECK only: no output means the syntax is valid
sudo nft -f /etc/cornil/lan-ports.nft          # apply now (lost at reboot)
```
Then test from your Mac:
```
curl -m 5 http://cornil.fritz.box:8888/        # expect: hangs then times out (dropped), no reply
make smoke                                     # expect: SMOKE OK (gateway still reaches parts-db)
```
Undo any time: `sudo nft delete table inet cornil_lan`. If `make smoke` fails after stage 1, undo and tell me.

Stage 2, permanent (only after stage 1 worked), `/etc/systemd/system/cornil-lan-ports.service`:
```
[Unit]
Description=Block direct LAN access to the app ports (cornil gateway)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/cornil/lan-ports.nft
ExecStop=/usr/sbin/nft delete table inet cornil_lan

[Install]
WantedBy=multi-user.target
```
```
sudo systemctl daemon-reload                   # tell systemd about the new file
sudo systemctl enable --now cornil-lan-ports   # load it now and at every boot
```
Remember to remove the port from the rule when its app really stops listening. For parts-db that is the `8888` entry in the `tcp dport { 8888, 8889, 8890 }` line: it may be removed once the rootful unit is stopped. Delete the unit when no port remains. Nothing was applied.

## How to verify the end state (from another LAN device)
```
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://cornil.fritz.box:8888/   # refused or timeout
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://cornil.fritz.box:8889/   # refused or timeout
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://cornil.fritz.box:8890/   # refused or timeout
make smoke                                                                     # SMOKE OK
```
"Connection refused" means nothing listens (best); a timeout means the firewall dropped it; either way the app is not reachable.
