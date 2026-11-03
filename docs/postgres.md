# PostgreSQL on cornil: the shared database

Status: **built, not deployed** (Phase U1). Decisions: ADR 0005 (scope, layout, contract) and ADR 0006 (mount guard, locale, version).

## What this is, in plain words
- **PostgreSQL** is a database program. Your apps keep their data in it instead of in a single file (SQLite). It is stricter and safer when several things write at once, and it can be backed up while it runs.
- **One container, many databases.** We run a single PostgreSQL (the container `postgres`). Inside it, each app gets its **own database** and its **own login** (a "role"), both named after the app (`partsdb`, `taxtool`, later `humbser`). An app can only open its own database. This is far lighter on a 3.7 GB server than one PostgreSQL per app.
- **The `db` network.** A Podman network is a private virtual cable between containers. `postgres` sits only on the network called `db`. **No port is published on the server itself**, so nothing on your home network can reach it, not even your Mac. Only a container that joins `db` can connect, and it finds the database by the name `postgres`, port 5432.
- **Where the data lives.** On the USB disk: `/u01/data/postgres`. The small settings file (`pg_hba.conf`, who may connect) lives on the eMMC at `~/cornil-platform/postgres/`.
- **Passwords** are generated on the server and stored as **Podman secrets** (named, protected values). They are never written into this repo, never shown, and never typed on a command line. The names are `postgres-superuser-password`, `partsdb-db-password`, `taxtool-db-password`.
- **If the USB disk is missing,** PostgreSQL refuses to start (it would otherwise start on the empty mount-point folder and create a fresh, empty database in the wrong place) and retries every 10 seconds until the disk appears. Caddy and the portal do not depend on the disk and keep running.

## Commands (all without sudo)
    make pg-deploy-check             # rehearse: shows what would change, changes nothing
    make pg-deploy                   # install PostgreSQL (an empty server). First start takes about a minute
    make pg-status                   # read-only overview
    make pg-create-app APP=partsdb   # add an app's database, login and password secret. Safe to repeat

What normal looks like:
- `make pg-deploy`: ends with a line saying PostgreSQL 17.x is running and healthy. If it stops with "/u01 is not a mounted disk": the USB disk is not mounted; nothing was written (see `docs/recovery.md`).
- `make pg-status`: "u01 mounted: yes", "health: healthy", "published ports: 0 (must be 0)", the three secret names (names only), and the durability line showing `on` three times.
- `make pg-create-app APP=partsdb`: ends with "role and database ready". Running it again changes nothing. It never changes an existing password and never deletes anything.
- If it fails: read the message under the failed task. The most common causes are PostgreSQL not healthy yet (wait a minute, run again) and the disk not mounted.

## How an app connects
In the app's own Quadlet unit (in the app's repo, not here):

    Network=db.network
    Secret=partsdb-db-password,type=env,target=DJANGO_DB_PASSWORD
    Environment=DJANGO_DB_HOST=postgres  DJANGO_DB_PORT=5432  DJANGO_DB_NAME=partsdb  DJANGO_DB_USER=partsdb

(one `Environment=` line per variable in the real file). If `DJANGO_DB_HOST` is not set, the app uses SQLite as before. The unit also needs the `/u01` guard from ADR 0006 and `Wants=postgres.service` plus `After=postgres.service` (not `Requires=`, so restarting PostgreSQL does not restart the app).

## How to add an app (for example Humbser)
1. `make pg-create-app APP=humbser`
2. In the app's unit: join `db.network`, add the `Secret=` line for `humbser-db-password`, set the `DJANGO_DB_*` values, add the guard.
That is all. Nothing in this repo needs editing.

## Choices you may wonder about
- **Version 17**, image pinned to an exact tag (`group_vars/all.yml`, `postgres_image`). A new patch release of 17 is a normal update. A new *major* version needs a dump and restore, not just a new tag.
- **Sort order.** The database sorts text by `en_US.utf8` rules (case and accents mostly ignored), SQLite sorted by raw bytes. The apps must therefore ask for an explicit ordering wherever a list is displayed or exported. The sort rules come from the operating system inside the image; if a future image changes them, run `REINDEX DATABASE <name>` on each database so indexes match.
- **Durability is not weakened.** `fsync`, `synchronous_commit` and `full_page_writes` stay on, and data checksums are enabled when the cluster is first created. The disk is bus-powered USB, so safety comes first; speed is plenty for these apps.
- **Hardening.** Read-only container filesystem, no extra privileges, no Linux capabilities, memory limit 1 GB, at most 200 processes.
- **Superuser password.** It is used only when the cluster is first created. The playbooks refuse to generate a new one for an existing cluster, because it would not match.

## What was not verified (nothing has been run on the server)
The unit has been checked as text by the tests and as an Ansible playbook, but not yet translated by the server's Quadlet generator (`make quadlet-dryrun`, which the owner runs) and not started. Things that could still need a small adjustment on first start: the read-only root filesystem with the socket folder in memory, and the `UserNS=keep-id` mapping with the data folder. Phase U2 starts it for the first time, with a rehearsal first.
