# ADR 0005: this repository becomes the shared platform on cornil

Status: **Proposed** 2026-11-03 (owner approved the scope and PostgreSQL 17 in the Phase U0 questions; the `CLAUDE.md` amendment waits for "go")
Date: 2026-11-03

## Context
A 1 TB USB disk is mounted at `/u01`. The agreed strategy is to move the apps' files there and run one shared PostgreSQL container, with a database and a login role per app. Someone must own the shared pieces (the `db` network, the `postgres` container, database and role creation, dumps, offsite backup, disk health). `CLAUDE.md` currently limits this repository to the proxy and lists app databases as out of scope.

## Decision
1. **Extend this repository** from "the reverse proxy" to "the shared platform on cornil". No new repository.
2. **Unchanged:** only this repository contains Caddy configuration. No app code, no app data and no app secret values ever enter this repository.
3. **Ownership** (contract v1):

| Thing | Owner |
|---|---|
| `gateway` network, Caddy | this repo |
| `db` network (`db.network`), the `postgres` container, creating databases and roles, nightly dumps, restic, disk health | this repo |
| App containers, their settings, migrating their own data, their own backup archives | the app repo |

No repo writes into another repo's files, units, folders or secrets on the server. Shared objects are exactly: the `gateway` network, the `db` network, the `postgres` container and the Podman secret names `partsdb-db-password`, `taxtool-db-password` and `postgres-superuser-password`.
4. **Layout:**
```
/u01/data/postgres/                       PostgreSQL data
/u01/data/backups/postgres/<db>/          nightly dumps
/u01/data/parts-db/{data,media,backups}
/u01/data/tax-healthcare-tool/{data,uploads,backups}
/u01/apps/<app>/build/                    image build contexts
```
5. **Stays on the eMMC:** each app's `config/env`, Caddy's own data (`~/cornil-gateway`), the Podman image storage and the Podman secrets (they live inside the image storage folder). Builds use `/u01` for temporary files (see ADR 0006).
6. **Database:** container `postgres` on the Podman network `db`, not published on the host, official image pinned to an exact tag, `scram-sha-256` only; one database and one non-superuser role per app (`partsdb`, `taxtool`, later `humbser`).
7. **Apps** join `db.network` in addition to `gateway.network`, start after `postgres.service` (`Wants=` plus `After=`, not `Requires=`, so a PostgreSQL restart does not restart the app), and carry the `/u01` guard from ADR 0006. If `DJANGO_DB_HOST` is unset an app uses SQLite as today.

## Consequences
- `CLAUDE.md` ("What this repository is", "Not in scope") is amended; the secrets rules apply to the new area too (database passwords exist only as Podman secrets generated on the server).
- Phases U1 to U4 in `docs/prompts/U01-POSTGRES-PLATFORM.md` build and deploy the platform.
- A Podman-image-on-`/u01` option was considered and rejected by the owner after review (see ADR 0006): it would make the proxy depend on the USB disk.

## Phase U0 findings that bear on this decision
- Server: Debian 13, Podman 5.4.2 (supports `Secret=` in Quadlet), systemd 257, 4 cores, 3.7 GB RAM, eMMC 18 GB free, `/u01` empty and mounted ext4 `noatime`; no name collisions for `postgres.container` or `db.network`; no USB resets or I/O errors in `dmesg`.
- A stale rootful `tax-healthcare-tool-web` (system service, port 8889, data under `/var/lib/tax-healthcare-tool`, database unchanged since 2026-10-19) still runs. The live Tax tool is the rootless one and is the migration source. It is not touched by this ADR.

## Phase U2 results (2026-11-03)
PostgreSQL 17.11 was deployed with `make pg-deploy`; `partsdb` and `taxtool` were created with `make pg-create-app`. A throw-away container on `db` connected as each role to its own database, was refused on the other's database and on `postgres`, and was refused for an unknown role and for a wrong password. The isolation test found that app roles could still open the `postgres` maintenance database through the default PUBLIC grant; `pg-create-app` now revokes it. A canary row in a scratch database survived a service restart and a server reboot (`/u01` mounted by itself, no recovery messages, `dmesg` clean); the scratch database was then dropped, the one `DROP` of the phase. Port 5432 is not reachable from the owner's Mac.

## Not verified here
Nothing is deployed. The contract is confirmed against the server's current state (Phase U0 findings), not against a running PostgreSQL.
