# U01-POSTGRES-PLATFORM.md: the /u01 disk and one shared PostgreSQL on cornil (cornil-gateway repo)

Save as `docs/prompts/U01-POSTGRES-PLATFORM.md`. This file is tracked. It contains no secrets, no disk UUID and no addresses. Keep it that way.

How to use: open a session in the `cornil-gateway` repo, say "Read `docs/prompts/U01-POSTGRES-PLATFORM.md` and `CLAUDE.md`. Do only Phase U1" (or U0, U2, U3, U4). One phase per session. Each phase ends with a report and a stop.

The owner knows little about Podman and Linux administration. Explain every concept in plain language the first time, give each command with a one-line "what this does", say what normal output looks like and what to do if it fails (the same rule as `CLAUDE.md`).

## Why

The home server `cornil` (Minix Z83-4 Pro, Debian 13, headless) runs two Django apps (parts-db and the Tax and Healthcare Tool) as rootless Podman Quadlet containers of the user `homeapps`, both on SQLite on the eMMC (root partition about 27 GB). A 1 TB USB hard disk (ext4, label `u01`) is now mounted at `/u01`, with `/u01/data` and `/u01/apps` owned by `homeapps` (mode 750). It passed a reboot test. The agreed strategy:

1. Move the apps' files (media, uploads, backups, build contexts) to `/u01`.
2. Run **one PostgreSQL container** with one database and one login role per app, data on `/u01/data/postgres`.
3. Migrate parts-db first, then the Tax tool (a third app, Humbser, will be built on PostgreSQL from the start and is not part of this work; the platform must make adding it a one-command job).
4. Back up with a nightly `pg_dump` per database, plus `restic` encrypted offsite, and rehearse a restore every quarter.

**This repo's part** is the shared platform: the `db` network, the `postgres` container, creation of databases and roles, the nightly dumps, the offsite backup and disk health. The app repos (`Parts-DB`, `Tax-and-KK-Tool`) each have their own prompt file for their own part.

## Execution modes (every phase carries one)

- **[LOCAL]** needs the server (SSH as `homeapps`), real files or the owner's sudo. Run it in a normal Claude Code session on the owner's Mac.
- **[CLOUD OK]** needs only a checkout of this repo. It can run in a background/cloud session: work on a branch, open a pull request, do not merge. A cloud session cannot reach `cornil.fritz.box`, cannot see git-ignored files (`local/`), and cannot run `make check` if `caddy` or `gitleaks` are missing (say so; the owner runs it). If a [CLOUD OK] phase finds it needs the server, stop and say what is needed.
- **[OWNER]** commands the owner runs by hand (sudo, reboot). Give the exact command and what it changes.

## Standing rules (in addition to `CLAUDE.md`, which applies in full)

1. Secrets: nothing sensitive in any tracked file, commit, log or report. Database passwords are generated **on the server** and stored as **Podman secrets** (`podman secret`), never in a file in this repo, never as a command-line argument that reaches shell history (`no_log: true`; pass through stdin). Never print a secret.
2. Never print `systemctl cat`, unit files or `Environment=` lines unfiltered. Scrub addresses, usernames and device identifiers (the disk UUID is not written into tracked files; use `<u01-uuid>` or look it up with `findmnt`).
3. Read-only inspection before any change. Rehearse before applying: `ansible-playbook --syntax-check`, `--check`, the Quadlet generator in dry-run mode (`make quadlet-dryrun`).
4. Routine deploys use no sudo. Only labelled one-time steps may. Never delete data: no `state: absent`, `rsync --delete`, `rm -r` or `DROP` in a playbook the owner can trigger routinely. A "drop database" operation, if ever needed, is a documented manual step with a backup first.
5. One phase, then stop and report (done, commits, checks with real results, deviations, open questions, what was not verified; each acceptance criterion met / not met / not verifiable here). Wait for "go".
6. Add an ADR (next free number is **0005**) after each decision; update `CLAUDE.md`'s decisions log. Never delete an old ADR.
7. At least one test per feature must exercise the real artifact (the rendered unit or the rendered playbook output), not a copy of its text.

## Shared contract v1 (identical in all three repos; if you disagree, say so in your first reply, do not diverge silently)

**Server.** `cornil.fritz.box`, Debian 13, rootless Podman + Quadlet as `homeapps` (linger on). The disk is mounted at `/u01` (fstab `defaults,noatime,nofail,x-systemd.device-timeout=15`); the unmounted mount point is immutable (`chattr +i`) so nothing can be written there by accident.

**Who owns what.**

| Thing | Owner |
|---|---|
| `gateway` network, Caddy | `cornil-gateway` (unchanged) |
| `db` network (`db.network`), the `postgres` container, creating databases and roles, nightly dumps, restic, disk health | `cornil-gateway`, platform area (ADR 0005, after the owner approves in U0) |
| App containers, their settings, migrating their own data, their own backup archives | the app repo |

No repo writes into another repo's files, units, folders or secrets on the server. The shared objects are exactly: the `gateway` network, the `db` network, the `postgres` container and the Podman secret *names* below.

**Layout.**

```
/u01/data/postgres/                       PostgreSQL data (platform)
/u01/data/backups/postgres/<db>/          nightly dumps (platform)
/u01/data/parts-db/{data,media,backups}   parts-db (data/ holds SQLite until its cutover, then legacy-sqlite/)
/u01/data/tax-healthcare-tool/{data,uploads,backups}   Tax tool (same)
/u01/apps/<app>/build/                    image build contexts (were ~/<app>/build)
```

Stays on the eMMC, never on the removable disk: each app's `config/env` (Django secret key), the Podman image storage, and the Podman secrets. Image builds use `/u01` for temporary files.

**Database.** Container `postgres` on the Podman network `db` (Quadlet file `db.network`, `NetworkName=db`). **Not published on the host**: reachable only from containers that join `db`, as host `postgres`, port 5432. Official `postgres` image pinned to an exact tag (major version decided in U0, default 17, which matches Debian 13's client tools). `scram-sha-256` only. One database and one login role per app: `partsdb` / `partsdb`, `taxtool` / `taxtool` (later `humbser`). A role is not a superuser, owns only its database, and `CONNECT` is revoked from `PUBLIC`.

**Passwords.** Generated on the server, stored as Podman secrets `partsdb-db-password` and `taxtool-db-password` (superuser: `postgres-superuser-password`, never used by an app). Apps read them with `Secret=<name>,type=env,target=DJANGO_DB_PASSWORD` in their Quadlet unit.

**App settings contract.** If `DJANGO_DB_HOST` is unset the app uses SQLite exactly as today (development and tests unchanged). Otherwise PostgreSQL from `DJANGO_DB_HOST`, `DJANGO_DB_PORT` (default 5432), `DJANGO_DB_NAME`, `DJANGO_DB_USER`, `DJANGO_DB_PASSWORD`. Driver: `psycopg` 3, pinned.

**Units.** Each app unit gets `Network=db.network` (in addition to `gateway.network`), starts after `postgres.service`, and carries the `/u01` guard decided in U0 (the starting assumption is `RequiresMountsFor=/u01`; U0 must prove it actually works in a rootless **user** unit, or choose the replacement).

**Not in the contract:** text ordering. PostgreSQL sorts text by locale rules, SQLite by bytes. Apps must not rely on database ordering for anything that is displayed or exported unless the ordering is explicit and tested. U0 records the cluster locale.

---

## Phase U0: Inspect, decide, confirm the contract  [LOCAL, read-only]

Do not change anything on the host or in the repo (except writing the findings, the ADR drafts and, after "go", the `CLAUDE.md` amendment).

### Questions for the owner (defaults in brackets; put them in your first reply)
1. **Scope.** Extend this repo from "the proxy" to "the shared platform on cornil" [yes], or create a new repo (for example `cornil-platform`)? If extended: `CLAUDE.md` ("What this repository is", "Not in scope: app databases") is amended by ADR 0005, the rule that only this repo contains Caddy configuration stays, and no app data ever enters this repo.
2. PostgreSQL major version [17].
3. Cluster locale [keep the image default `en_US.utf8`, and make the apps' ordering explicit]. The alternative `C.UTF-8` sorts by bytes like SQLite and changes less.
4. Where Podman keeps its image storage [stays on the eMMC; revisit only if free space gets tight].
5. Offsite target for `restic` [decide in U3 from the options you list].

### Inspect (read-only, as `homeapps` through the existing inventory; scrub the output)
- OS, kernel, Podman and systemd versions; confirm `Secret=` support in Quadlet. CPU, `free -m` (the memory decides the PostgreSQL settings), `df -h` (eMMC and `/u01`).
- `findmnt /u01`, `ls -la /u01 /u01/data /u01/apps`, mount options, whether the mount point is immutable, last boot's mount time against the time `homeapps`' units started (`journalctl --user -b`, `systemd-analyze`): can user units start **before** `/u01` is mounted?
- Quadlet file names in `~/.config/containers/systemd/`, `podman ps -a`, `podman volume ls`, `podman network ls`, `podman secret ls`, and for each of the three containers only the `Source` and `Destination` of `{{json .Mounts}}`. Where each app keeps its data today (sizes only: `du -sh`).
- `systemctl --user list-units` and `list-timers` for the app units and backup timers. Never `systemctl cat`.
- Check that no existing file is named `postgres.container`, `db.network` or similar.

### Owner-run (give the exact commands; ask for scrubbed output)
- `sudo podman ps -a` and `systemctl --failed` as the admin login: is there a leftover **rootful** container? A failed healthcheck unit whose name starts `2601c` was logged by the system manager and matches no current container.
- `dmesg | grep -i -E 'usb|reset|I/O error'` (the disk is bus-powered; a reset means a power problem). Optional burn-in: `sudo apt install smartmontools` then `sudo smartctl -t long -d sat /dev/sda`, result later with `sudo smartctl -a -d sat /dev/sda`.

### Prove the mount guard (needs the owner's "go"; creates and removes one throw-away user unit)
Does `RequiresMountsFor=/u01` take effect in a **user** unit (`systemctl --user show -p Requires,After,RequiresMountsFor <unit>`)? If not, propose and test the replacement (`ConditionPathIsMountPoint=/u01`, or `ExecStartPre=/usr/bin/mountpoint -q /u01`, with a restart policy that keeps retrying until the disk appears). Remove the test unit and say that you did.

### Deliver
A findings table; draft ADR 0005 (scope, platform, layout, contract) and ADR 0006 (mount guard, locale, Postgres version); a statement "contract v1 confirmed" or the exact amended text, which the owner pastes into the two app prompts; and the proposed `CLAUDE.md` amendment (applied only after "go").

Acceptance: nothing changed on the host except the removed throw-away unit; every open item of the handoff is answered or handed to the owner with a command; the mount-guard question is answered by a test, not by reading documentation.

---

## Phase U1: PostgreSQL platform code, not deployed  [CLOUD OK]

Branch `feat/u01-postgres-platform`. Build everything; deploy nothing.

1. `ansible/templates/db.network.j2` (`NetworkName=db`, same style as `gateway.network.j2`).
2. `ansible/templates/postgres.container.j2`: pinned image tag (verify the current patch tag of the chosen major; never `latest`), `Network=db.network`, **no `PublishPort`**, data volume `/u01/data/postgres` with `PGDATA` in a sub-folder, user mapping so the files belong to `homeapps` on the host (verify the postgres user's uid in the image; `UserNS=keep-id:uid=…,gid=…` as the apps do), the mount guard from ADR 0006, `Secret=` for the superuser password, `HealthCmd=pg_isready` (as a script or a form Quadlet does not re-quote), a generous `TimeoutStopSec` for a clean shutdown, memory limit and pid limit sized from the U0 findings, `Restart=always`. Hardening as far as the image allows (`NoNewPrivileges`, `DropCapability=ALL` with only what postgres needs; test it with the Quadlet dry-run, say what you could not verify).
3. Server settings via the unit or a mounted config file, sized for the server's RAM. **Do not weaken durability** (`fsync`, `synchronous_commit`, `full_page_writes` stay on: the disk is bus-powered USB). Allow connections only from the `db` network with `scram-sha-256`.
4. Playbooks (no sudo, `no_log` where secrets pass): `postgres-deploy.yml` (checks `/u01` is a real mount point, folders exist, generates the superuser secret on the server if missing, installs units, starts, waits healthy), `postgres-status.yml` (read-only), `pg-create-app.yml` with `-e app=partsdb` (idempotent: creates the role and database if missing, generates the password into the Podman secret `<app>-db-password` if missing, revokes `CONNECT` from `PUBLIC`, never touches an existing role's password, never drops anything).
5. `Makefile`: `pg-deploy`, `pg-status`, `pg-create-app APP=…`, in `make help`; add the new playbooks to `make syntax`.
6. Tests on the real rendered artifacts (extend `scripts/test.sh`): no `PublishPort`; `Network=db.network`; image pinned and not `latest`; mount guard present; no password or secret text in any rendered file; `Secret=` used; the host-side data path is under `/u01/data`; `pg-create-app` contains no `DROP`; `make quadlet-dryrun` accepts the units.
7. Docs: `docs/postgres.md` (plain language: what PostgreSQL is here, why one container with many databases, how an app connects, how to add an app), update `docs/design.md`, `docs/recovery.md` (outline; filled in U3/U4), README.

Do not touch the Caddy templates, `gateway.network.j2` or the portal. Do not run anything against the server.

Acceptance: `make syntax`, `make test` (and `make check` if `caddy` and `gitleaks` exist here, otherwise say the owner runs it) pass; rendered artifacts satisfy item 6; the PR is open; nothing is deployed.

---

## Phase U2: Deploy an empty PostgreSQL, create the two databases  [LOCAL + OWNER]

Start only after the U1 pull request is merged and the owner says "go".

1. `make deploy-check`-style rehearsal first (`--check`), then `make pg-deploy`, `make pg-status`. Show scrubbed output; explain what normal looks like.
2. `make pg-create-app APP=partsdb`, `make pg-create-app APP=taxtool`. Confirm with `podman secret ls` that the secrets exist (names only; never a value).
3. Prove it: a throw-away container on the `db` network connects as `partsdb` to `partsdb` (`SELECT 1`), is **refused** for `taxtool`'s database, and cannot connect as a role that does not exist; from the owner's Mac `nc -z cornil.fritz.box 5432` fails (nothing published).
4. Durability: create a canary table in a scratch database, restart the container (`systemctl --user restart postgres`), confirm it survived; then the **owner** reboots the server (give the command) and you confirm `/u01` mounted by itself, `postgres` is healthy, the canary is still there, and no I/O errors appear in `dmesg`. Drop the canary and the scratch database (the one `DROP` of this phase, on a database you created yourself, with the owner's go).
5. Do not start any app against it yet.

Acceptance: items 3 and 4 shown with real output; secrets never printed; the app containers untouched.

---

## Phase U3: Backups and disk health code  [CLOUD OK]

Branch `feat/u01-backups`. Build, do not deploy. Start after U1 is merged.

1. **Nightly dump per database.** A user systemd timer and service (pattern as the apps' backup timers: `Persistent=true`, a random delay) that runs `pg_dump -Fc` for each database **inside the `postgres` container** (so client and server versions always match), writes to `/u01/data/backups/postgres/<db>/<db>-<timestamp>.dump`, verifies it with `pg_restore --list`, and applies a retention (suggest: 14 daily, 12 monthly, always the newest; show the numbers in group_vars). Atomic write (temp name, then rename). Never deletes outside its own folder.
2. **`restore-drill` for Postgres**: restore the newest (or chosen) dump into a throw-away database, compare per-table row counts with the dump's contents, drop only that throw-away database, and print `DRILL_OK`. `make pg-restore-drill [DB=…] [DUMP=…]`. A real restore (`make pg-restore DB=… DUMP=…`) replaces a database only after the owner types `RESTORE`, takes a safety dump first and renames the old database aside instead of dropping it.
3. **Offsite with restic (design and code, not credentials).** In `docs/offsite-backup.md` compare at least three targets suited to a home server (for example an SFTP target on another machine, an S3-compatible bucket, a storage-box service), with cost, encryption, restore effort and what is lost if the home is lost, and recommend one. Templates for a restic backup service and timer that back up `/u01/data/backups` (the dumps **and** the app-level backup archives) and prune with a retention. The repository password and any target credentials are created **on the server** (Podman secret or a 0600 file on the eMMC), never in the repo. Say plainly in the docs: **losing the restic password means the offsite backup cannot be read; the owner must keep a copy outside the server.**
4. **Disk health.** `docs/disk-health.md` and, if feasible without weakening security, a `make disk-status` that reports SMART status and the count of USB resets in `dmesg` (these need root: propose the smallest sudo-free arrangement, for example a root-owned timer installed by a one-time labelled bootstrap that writes a small status file `homeapps` can read; do not add `homeapps` to broad groups without saying why). A monthly SMART long test is a proposal for the owner to approve.
5. Tests on rendered artifacts: timer and service units, retention numbers, no secret text, restore-drill refuses to touch a non-throw-away database name (assert the name pattern).
6. Update `docs/recovery.md` with the PostgreSQL sections (dump restore, drill, what to do if `/u01` does not mount, what to do if the disk dies: restore from restic onto a new disk).

Acceptance: syntax and tests pass; the drill playbook and restore playbook are rehearsed with `--check`; nothing is deployed; offsite recommendation is explained for a beginner.

---

## Phase U4: Go-live of backups and the first real restore rehearsal  [LOCAL + OWNER]

Start after the owner says "go" and at least parts-db runs on PostgreSQL (its prompt phase PD4); ideally after both apps.

1. Deploy the dump timer (`make pg-deploy` or the new target), run one dump by hand, show the scrubbed listing and `pg_restore --list` result, run `make pg-restore-drill` and show `DRILL_OK`.
2. Initialise the restic repository on the chosen target. The **owner** types the repository password into a prompt on the server (not into the chat); you never see it. Run the first offsite backup, `restic check`, and a **restore of one dump from offsite into a scratch folder**, then run the drill on it.
3. Disk health: the one-time bootstrap if the owner approved one; report the first SMART result.
4. Write the quarterly rehearsal checklist in `docs/recovery.md` (what to run, what success looks like, where to record the date) and offer, in one sentence, to create a scheduled task that reminds the owner each quarter.
5. Update `CLAUDE.md`'s decisions log and `README.md` (the portal and Caddy are unchanged).

Acceptance: an offsite restore into a scratch place was demonstrated with real output; the owner confirms they hold a copy of the restic password off the server.

---

## End-of-phase report (every phase)
Done; commits; checks run with real results; deviations; open questions; what was not verified and why; each acceptance criterion met / not met / not verifiable here; proposed next phase. Then wait for "go".
