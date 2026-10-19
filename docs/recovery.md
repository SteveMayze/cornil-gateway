# Recovery procedures

Every command runs on your Mac in the repo folder unless it says "on the server". `ssh <service user>@<server>` means your usual login as `homeapps` (see `local/inventory.ini`). Concepts (container, Quadlet, rootless) are explained in [`podman-explained.md`](podman-explained.md).

## 0. Quick triage
```
make status          # what this does: read-only overview. Normal: unit active, container (healthy), network gateway
make smoke           # what this does: tests the gateway end to end. Normal: SMOKE OK
```
If `make status` cannot connect: the server is off or SSH is down; nothing here can help until it is back. After a **server reboot** run both commands; the gateway should have started on its own (linger is on). If it did not, run `make deploy`.

## 1. Caddy does not start or the site shows an error
1. Read Caddy's own log, on the server: `journalctl --user -u caddy -n 80 --no-pager` (normal: `serving initial configuration`; a line with `error` says what is wrong).
2. Try `make deploy` (safe to repeat; it validates the config and restarts only if needed).
3. A deploy that fails validation never goes live; the previous config is `~/cornil-gateway/config/Caddyfile.previous` on the server.
4. If you need the old setup back at once: `make rollback-legacy` (asks for sudo; restarts the legacy Caddy package, whose files were archived, not removed, at the cut-over). Note the legacy Caddy has only the old parts-db-only config.

## 2. One device shows "connection is not private"
- The device does not trust the gateway's root certificate, or trusts a different one. Compare the fingerprint in the device's certificate details with the output of `make root-cert`. The January 2026 experiment certificate has the same name but a different fingerprint.
- Reinstall using [`trust-root-cert.md`](trust-root-cert.md). Also check the device's clock; a wrong date looks like an expired certificate.
- The site's own certificate and Caddy's intermediate renew by themselves; you do nothing for them.

## 3. The root certificate is about to expire (due 2036) or you must replace it
The root certificate lasts ten years (this one ends in August 2036). Caddy renews the shorter-lived certificates beneath it automatically, but **not the root**. Plan the replacement a few months ahead: do section 4 ("create a new CA"), install the new file on every device, then remove the old one.

## 4. The CA is lost, damaged, or its private key may have leaked
**First try to restore from a backup** (you keep the same certificate, so devices need nothing):
```
make backup-caddy-data                       # (if the server still runs) a fresh backup, written on the server
ssh <service user>@<server> ls ~/cornil-gateway/backups        # lists backups; names look like caddy-data-20261019-114219.tar.gz
make restore-drill BACKUP=<name>             # what this does: unpacks the backup in a throw-away folder and compares its certificate with the live one. Normal: DRILL_OK
make restore-caddy-data BACKUP=<name>        # what this does: stops Caddy for a few seconds, sets the current data aside (kept), unpacks the backup, starts Caddy. You must type RESTORE
make smoke
```
`DRILL_DIFFERENT` is not an error: it says the backup holds an older CA than the live one. If it fails midway, the playbook puts the previous data back and starts Caddy again.

**If there is no usable backup, or the key leaked, create a new CA** (every device then needs the new file):
```
ssh <service user>@<server> 'systemctl --user stop caddy'        # what this does: stops the gateway (the site goes down)
ssh <service user>@<server> 'cd ~/cornil-gateway && mv caddy-data caddy-data.old && mkdir -m 700 caddy-data'   # keeps the old data aside
make deploy                                                       # starts Caddy, which creates a brand-new CA
make root-cert                                                    # fetches the NEW public certificate, prints its fingerprint
```
Then install the new file on every device ([`trust-root-cert.md`](trust-root-cert.md)), remove the old certificate from each device, run `make smoke`, and `make backup-caddy-data`. If the old key leaked, delete `caddy-data.old` on the server and every old backup once the devices are done (`ssh <service user>@<server> 'rm -r ~/cornil-gateway/caddy-data.old'`; this is permanent).

## 5. The whole server is rebuilt
1. Install the service user and Podman as in the tax repo's bootstrap (`make bootstrap-rootless` there).
2. Here: copy `local/inventory.example.ini` to `local/inventory.ini`, fill it in. Run `make bootstrap-ports` (sudo, once), then `make deploy`.
3. To keep the same certificate, put a backup archive from your own storage into `~/cornil-gateway/backups/` on the server and run `make restore-caddy-data BACKUP=<name>`; otherwise use section 4's "new CA".

## 6. Backups: what and where
`make backup-caddy-data` writes a dated archive into `~/cornil-gateway/backups/` on the server (mode 600; the newest 7 are kept). It contains the CA's **private key**: copy it only to your own encrypted storage, never into this repo. Nothing runs it automatically yet; run it after any CA change and whenever you like (monthly is sensible). If the server's disk dies, the only copy of the CA is the one you saved elsewhere.
