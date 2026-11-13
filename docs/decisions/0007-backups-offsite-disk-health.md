# ADR 0007: nightly dumps, restore tools, offsite backup and disk health

Status: **Accepted in part** 2026-11-08 (dumps and drill live; disk health bootstrap approved); **offsite live since 2026-11-09** on the owner's NAS, restore proof still owed (see "Phase U4 continued" at the end). Originally proposed 2026-11-03 (code built in Phase U3; not deployed; the offsite target is the owner's decision in Phase U4)
Date: 2026-11-03

## Context
The shared PostgreSQL (ADR 0005) keeps its data on one bus-powered USB disk. Backups must survive a bad database, a dead disk and the loss of the home, and the owner must be able to prove they work.

## Decision
1. **Nightly dump, per database.** A user timer (`pg-dump.timer`, 02:15 plus a random delay, `Persistent=true`) starts `pg-dump.service`, which runs `pg_dump -Fc` **inside the `postgres` container** (client and server versions always match), writes `/u01/data/backups/postgres/<db>/<db>-<UTC time>.dump` under a temporary name, checks it with `pg_restore --list`, renames it, then thins out old dumps. The service carries the mount guard from ADR 0006. Retention (variables in `group_vars/all.yml`): the newest dump always, plus the newest dump of each of the last **14 days** and **12 months** that have one. Only files named exactly `<db>-<time>.dump` in that database's folder are ever deleted.
2. **Restore drill and real restore.** `make pg-restore-drill` restores the newest (or a chosen) dump into a throw-away database `drill_<db>_<time>`, compares the row count of every table with what the dump itself contains, drops only that database (the name pattern is checked before every create and drop) and prints `DRILL_OK`. `make pg-restore DB=… DUMP=…` replaces a database only after the owner types `RESTORE`: safety dump first (without retention, so the dump being restored is never thinned out), restore into `<db>_restoring_<time>`, row-count check, then the old database is **renamed aside** (`<db>_old_<time>`, never dropped by these tools) and the new one takes its name. Aside and drill databases are excluded from the nightly dump.
3. **Offsite with restic, as a container.** `restic` runs from a pinned image (`restic/restic:0.19.1`) in a user service, so nothing is installed and no sudo is needed. It sends the dumps and the apps' own backup archives (`restic_backup_paths`, mounted read-only) and prunes with 7 daily, 5 weekly and 12 monthly snapshots. The repository password and target credentials exist only as Podman secrets created on the server at a hidden prompt (`make restic-secret`); the repository address lives in `local/vars.yml`. **The timer is installed but not enabled** until Phase U4. Losing the restic password makes the offsite copy unreadable; the owner keeps a copy off the server. The target options and the recommendation (a storage box over SFTP in the EU, then an S3-compatible bucket) are in `docs/offsite-backup.md`; the owner decides in U4.
4. **Disk health.** A one-time sudo bootstrap (`make bootstrap-disk-health`) installs `smartmontools` and a root-owned daily job that writes a small, serial-free status file readable by the service user; `make disk-status` shows it. No group or privilege is given to the service user. The monthly SMART long self-test is a proposal and stays off until the owner sets `disk_smart_long_test: true`.

## Consequences
- The app repos may still make their own verified archives (database plus media); restic sends those too. The platform dump is the safety net that works even if an app's archive fails.
- Dumps live on the same disk as the data, so they protect against mistakes and corruption, not against losing the disk or the house; that is the job of the offsite copy.
- `make pg-restore` needs the app stopped first (documented); open connections are cut when the database is closed for the switch.
- A real restic restore into a scratch folder, and a drill on the restored dump, are required before U4 is accepted.

## Found while testing (Phase U3)
The first version of the restore tool let the safety dump's retention delete the very dump being restored (an older dump of the same day). Fixed by skipping retention for the safety dump; covered by a test.

## Not verified here
Nothing has run on the server. The tools were run for real against a stand-in `podman`, `smartctl` and `dmesg`; the real `pg_dump`, `pg_restore`, `restic` and `smartctl` outputs are first seen in Phase U4. The playbooks were rehearsed with `--check` only.

## Phase U4 outcome (2026-11-08)
- Dump timer was already enabled. A manual dump gave `DUMP_OK` for both databases and `make pg-restore-drill` gave `DRILL_OK` (partsdb: row counts match for 16 tables; taxtool: 0 tables, not yet migrated).
- **Owner decision: no offsite target is available.** The restic timer stays uninstalled and no repository exists. **Risk accepted for now:** the dumps and the data share one bus-powered disk, so a dead disk or a lost home loses everything; the dumps only protect against mistakes and corruption. To be revisited when the owner picks a target (`docs/offsite-backup.md`); the restic restore-into-scratch proof is still owed.
- Owner approved the one-time `make bootstrap-disk-health` (sudo, run by the owner). Monthly SMART long test stays off.
- Quarterly rehearsal checklist: `docs/recovery.md` 7.8.

## Phase U4 continued (2026-11-09 to 2026-11-13)
This section supersedes the line "Owner decision: no offsite target is available" above. The older text stays as the record of 2026-11-08.

- **Owner decision (2026-11-09): the restic target is the owner's Synology NAS `barnes.fritz.box` over SFTP** (option A in `docs/offsite-backup.md`), with key login as a normal, non-admin NAS user that can write to one shared folder. User and share names are only in `local/vars.yml`. The repository address has the form `sftp:<nas-user>@barnes.fritz.box:/<share>/restic` (absolute path, as restic requires on Synology).
- **Accepted limit:** the NAS is in the same home as `cornil`. The copy survives a dead `/u01` disk, a mistake or a corrupted database. It does **not** survive fire, theft or a power surge that hits both. A second copy in another place is a later owner decision.
- **Done on the server (2026-11-09):** key and `known_hosts` in `~/cornil-platform/restic-ssh` (mounted read-only into the container; `restic_ssh_dir`), password as the Podman secret `restic-repo-password` typed by the owner, `restic init`, `restic check` ("no errors were found"), first backup through `restic-backup.service` (21.7 MiB from `/u01/data/backups` and `/u01/data/parts-db/backups`), `forget --prune` with 7 daily, 5 weekly, 12 monthly. `restic_backup_paths` is overridden in `local/vars.yml` to those two folders, because `/u01/data/tax-healthcare-tool/backups` does not exist until that app moves; add it back then.
- **Schedule (owner requirement):** the NAS and the home network are switched off most nights and for whole holidays, so the default 04:30 run could never succeed. Override in `local/vars.yml`: `restic_calendar: "*-*-* 11,14,17:00:00"` (three attempts a day, each plus up to 30 minutes random delay). The timer was enabled on 2026-11-09. Because `forget` keeps the newest snapshot of each day, the repository shows one snapshot per day although three runs succeed. `--keep-daily 7` counts days that have a snapshot, so a holiday gap deletes nothing.
- **Verified read-only (2026-11-13):** timer enabled and active; 10 runs since 2026-11-09, 9 succeeded; one failure on 2026-11-11 at 11:02 ("unable to start the sftp session ... server unexpectedly closed connection": the NAS end closed the connection; cause on the NAS not examined), recovered by the 14:17 run; no failed units; nightly `pg-dump.service` succeeded at 02:17 on 2026-11-13, which closes the "nightly platform dump confirmed" item of the parts-db cutover.
- **Synology findings worth keeping** (details in `docs/offsite-backup-synology.md`): the SFTP view has a virtual root with `/home` (the user's home) and `/<share>`; DSM puts an ACL on files in the home folder and its sshd refuses the key with "bad ACL permission for file .../authorized_keys" until the ACL is removed (`synoacltool -del`, then `chmod 600`); a normal NAS user cannot open a shell, only SFTP, which is all restic needs; the "not using a post-quantum key exchange" warning is harmless (the NAS has an older OpenSSH).

### Still open before U4 is accepted
1. **Restore proof:** restore the latest snapshot from the NAS into a scratch folder and compare with the live dump folders, shown with real output. `pg-restore-drill.sh` only accepts a dump in the live dump folder, so a byte-for-byte comparison stands in for the drill on the restored file (an optional dump-folder argument would close that gap; not built).
2. The owner confirms a copy of the restic password **outside the server**.
3. First `make disk-status` result after `make bootstrap-disk-health`.
4. **Owner request, not built:** an optional `ExecCondition` in `restic-backup.service.j2`, driven by a variable in `local/vars.yml`, so that a run is skipped quietly (not failed) when the NAS is off. Until then a run with the NAS off ends as `failed` and the next slot tries again.
5. `Wants=pg-dump.service` makes every restic run take one extra dump (three a day); harmless because dump retention keeps the newest per day, but worth a decision.
