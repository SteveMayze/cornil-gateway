# Request for the cornil-gateway repo: route /parts-db/ to the rootless parts-db container by name

Paste into a new Claude Code session in the `cornil-gateway` repo. Its `CLAUDE.md` applies (secrets, phases, plain language, scrubbed reports). **Run this only when the parts-db session (version 2 of its rootless prompt, phase R2, step 5a) tells me the rootless parts-db container is running, healthy and has passed its persistence test.** I will say "go" when that is true.

## Context
Until now the gateway reached parts-db at `host.containers.internal:8888`, the port of a **rootful** container (ADR 0001, `docs/design.md`). parts-db now also runs as a rootless container of `homeapps`, on the `gateway` network, container name `parts-db-web`, port 8000 inside, like the tax app. Its data starts empty on purpose (no migration); I reload it afterwards. Nothing in this repo may be sensitive; do not print unit files or `Environment=` lines.

## Do (one phase, then stop and report)
1. Read-only first: on the server as `homeapps`, confirm `parts-db-web` is running and on the `gateway` network, and that Caddy can reach it (a throw-away `curl` from a container on `gateway` to `http://parts-db-web:8000/health/`, or the equivalent; say what you used). Show the current `partsdb_upstream`.
2. Set `partsdb_upstream: parts-db-web:8000` in `ansible/group_vars/all.yml` (keep the old value in a comment as the rollback value). Update the comment above it, `README.md`, `docs/design.md`, `docs/closing-plain-ports.md` (parts-db row: now closable by the parts-db repo; if the optional `cornil_lan` firewall rule mentions 8888, say which line may be removed once the rootful unit is stopped, but apply nothing), the `CLAUDE.md` decisions log, and add ADR 0003 (parts-db rootless; upstream by name). Update the test stand-in so the parts-db route is tested like the tax route.
3. Rehearse: `ansible-playbook --syntax-check`, `--check`, `caddy validate` on the rendered Caddyfile, `make check`.
4. Deploy with `make deploy` (no sudo). Then `make smoke`, and ask me to open `https://cornil.fritz.box/parts-db/` (login, form post, PDF import). Rollback if anything fails: set the old upstream back and `make deploy`, then tell me.
5. Do not touch the parts-db or tax repos, do not stop or remove the rootful container, do not enable HSTS, do not touch Caddy's data directory.

Report as usual (done, commits, checks, deviations, open questions, not verified; each acceptance criterion met / not met / not verifiable), then wait for my "go". Acceptance: `make smoke` passes; `/parts-db/` works through the gateway against the rootless container; the Caddyfile still contains no secret.
