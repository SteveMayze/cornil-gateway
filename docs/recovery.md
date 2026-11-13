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

## 7. PostgreSQL

What exists: the database `postgres` container (data in `/u01/data/postgres`), nightly dumps in `/u01/data/backups/postgres/<db>/` (kept: newest, 14 days, 12 months), an offsite restic copy (from Phase U4), and a disk health status. Commands: `make pg-status`, `make pg-backup-now`, `make pg-restore-drill`, `make pg-restore`, `make disk-status`. Background: `docs/postgres.md`, `docs/offsite-backup.md`, `docs/disk-health.md`.

### 7.1 `/u01` is not mounted (USB disk unplugged, loose or dead)
Symptoms: `make pg-status` says "u01 mounted: NO"; the apps are down (they refuse to start without the disk); the portal page and Caddy still answer. This is the guard from ADR 0006 working: nothing is written into the empty mount-point folder.
1. Check the cable and that the disk spins up. Do **not** create files in `/u01` while it is empty.
2. The units retry every 10 seconds, so once the disk is back everything starts by itself. If not: as the administrator, `sudo mount /u01` (it reads `/etc/fstab`), then `make pg-status`.
3. If the disk does not appear at all (`lsblk` shows no `sda`), see 7.5.

### 7.2 A nightly dump did not run or failed
`make pg-status` shows the newest dump per database and its age in hours; anything over about 30 hours is late. Run `make pg-backup-now`: it prints `DUMP_OK` lines or the error. The usual causes are `/u01` not mounted (7.1) and PostgreSQL not healthy. The timer catches up by itself after downtime (`Persistent=true`).

### 7.3 Proving a backup works: the restore drill (quarterly rehearsal)
Run `make pg-restore-drill` (all app databases) or `make pg-restore-drill DB=partsdb`. It restores the newest dump into a throw-away database, compares row counts with the dump, drops only that database and prints `DRILL_OK partsdb <dump name>`. Success looks like "row counts match for N tables" and `DRILL_OK`. If it prints `DRILL_FAILED`, the live database is untouched; keep the line that says which table differs and tell me. The full quarterly checklist is in 7.8.

### 7.4 Putting an older state back: restoring a database from a dump
Use this when data was damaged or deleted. **Stop the app that uses the database first** (for example `systemctl --user stop parts-db-web.service` as the service user).
1. Choose the dump: `make pg-status` shows the newest; the list is in `/u01/data/backups/postgres/<db>/`.
2. `make pg-restore DB=partsdb DUMP=partsdb-20261103T021500Z.dump`, then type `RESTORE` when asked. It takes a safety dump of the current state, restores into a new database, checks the row counts, then renames: the current database becomes `partsdb_old_<time>` and the restored one becomes `partsdb`. Nothing is dropped.
3. Start the app and check it. Keep `partsdb_old_<time>` until you are sure; deleting it is a manual administrator decision (`DROP DATABASE`, with a backup first); these tools never do it.
Normal output ends with `RESTORE_OK`. If it stops earlier, the live database was not replaced; the message says what is left over.

### 7.5 The disk is dead: restoring onto a new disk from the offsite copy
(**Not yet rehearsed.** An offsite copy exists since 2026-11-09 on the owner's NAS, see `docs/offsite-backup.md`; a restore from it has not been shown yet. The NAS is in the same home: if the home is lost, this copy is lost too.)
1. Fit a new disk, format it ext4 with the label `u01` and mount it at `/u01` (same `fstab` line as before; administrator steps from the earlier setup).
2. Recreate the folders: `make pg-deploy` (creates `/u01/data/postgres` and the dump folder, and starts an empty PostgreSQL; the superuser secret still exists on the eMMC).
3. Fetch the newest dump of each database from the offsite repository into `/u01/data/backups/postgres/<db>/` (commands written in U4; you need the **restic password from your safe place**).
4. `make pg-create-app APP=partsdb` and `APP=taxtool` only if the roles do not exist (they do not on an empty server); then `make pg-restore DB=… DUMP=…`.
5. Restore each app's own archive into its folder as that app's repo describes, then start the apps.

### 7.6 The superuser secret is missing but the data exists
`make pg-deploy` refuses and changes nothing. Do not delete anything. The data is intact; the password only matters at first creation. Tell me; the fix is a documented, owner-approved step.

### 7.7 Disk health warnings
See `docs/disk-health.md` (what each line of `make disk-status` means and what to do).

### 7.8 Quarterly rehearsal checklist
Do this once every three months (January, April, July, October). It takes about ten minutes and changes nothing that matters.
1. `make pg-status`: `u01 mounted: yes`, container `healthy`, published ports `0`, the newest dump of every database younger than about 30 hours.
2. `make pg-backup-now`: every database prints `DUMP_OK`.
3. `make pg-restore-drill`: every database prints `DRILL_OK` and "row counts match for N tables". `taxtool` shows 0 tables until that app is migrated; that is expected, not a failure.
4. `make disk-status`: SMART overall result PASSED, no reallocated or pending sectors, no new USB resets or I/O errors (see `docs/disk-health.md`).
5. **Offsite (on the NAS since 2026-11-09; switch the NAS on first):** `systemctl --user --failed` shows no restic unit and the last run of `restic-backup.service` succeeded; `restic check`; then restore one dump into a scratch folder and compare it with the live dump (`diff`), or run the drill on it once the tool accepts a folder. Also confirm you can still find your copy of the restic password outside the server. If the offsite step was not done, write "offsite not checked" in the log below; that is the most important line of the rehearsal.
6. Record the date and the result here (one line per rehearsal, no secrets):

| Date | Result | Notes |
|---|---|---|
| 2026-11-08 | steps 1-3 ok (`DRILL_OK` both databases); steps 4-5 not possible yet | first run, Phase U4; no offsite target; disk health bootstrap pending |
| 2026-11-13 | read-only check: nightly dump ok (02:17), restic timer 3 runs a day, 9 of 10 runs ok since 2026-11-09 (one NAS-side connection failure, recovered) | not a full rehearsal; offsite restore proof, password-copy confirmation and `make disk-status` still open |
