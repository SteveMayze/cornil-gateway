# ADR 0003: parts-db is rootless; the gateway reaches it by container name

Status: **Accepted** 2026-11-01 (owner asked for the switch; deployed and verified as reported)
Date: 2026-11-01
Supersedes: decision 8 of ADR 0001 (`host.containers.internal:8888`), which is now history.

## Context
ADR 0001 planned parts-db to go rootless later. It now also runs as a rootless container of `homeapps`: name `parts-db-web`, on the `gateway` network, port 8000 inside, with empty data (reloaded by the owner afterwards).

## Decision
`partsdb_upstream: parts-db-web:8000` in `ansible/group_vars/all.yml`, like the tax app. The old value `host.containers.internal:8888` stays in a comment as the rollback value. Rollback: put it back, `make deploy`.

## Verified before the change (read-only, as `homeapps`)
- `parts-db-web` is running, healthy, on `gateway`.
- A throw-away Caddy-image container on `gateway` got `200` from `/health/` and `/parts-db/health/`, and `302` from `/parts-db/`, when sent `Host: cornil.fritz.box` (what Caddy forwards). With the container name as `Host` Django answers 400 (allowed hosts); that is expected and irrelevant behind Caddy.

## Consequences
- The gateway no longer depends on the rootful container or on port 8888. This repo did not stop it; the owner stopped `parts-db.service` themselves with sudo on 2026-11-01. Verified afterwards: port 8888 refuses connections, `make smoke` OK. Its data is still on disk; the unit was not removed.
- Port 8888 is closed (see above); the rootless container publishes plain port 8891 on the LAN, to be closed in the parts-db repo. The firewall line for 8888 is no longer needed (`docs/closing-plain-ports.md`). Nothing applied here.
