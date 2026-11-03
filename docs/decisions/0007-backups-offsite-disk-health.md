# ADR 0007: nightly dumps, restore tools, offsite backup and disk health

Status: **Proposed** 2026-11-03 (code built in Phase U3; not deployed; the offsite target is the owner's decision in Phase U4)
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
