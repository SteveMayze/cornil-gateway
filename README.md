# cornil-gateway

The single owner of the Caddy reverse proxy on the home server `cornil` (`cornil.fritz.box`).
It serves two Django apps over HTTPS:

- `https://cornil.fritz.box/parts-db` (repo: SteveMayze/parts-db; rootless container `parts-db-web`, reached by name on the `gateway` network)
- `https://cornil.fritz.box/tax-healthcare` (repo: SteveMayze/Tax-and-KK-Tool)

No other repository may contain Caddy configuration or write to the proxy's files.

Since ADR 0005 this repository also owns the **shared platform** on the server: the `db` network and one PostgreSQL container with a database and login per app (`docs/postgres.md`). Built in Phase U1 and not yet deployed.

**Status:** live. The gateway serves both apps on ports 80 and 443. Closing the old plain-HTTP ports is described in `docs/closing-plain-ports.md`; recovery in `docs/recovery.md`.

## The portal page
`https://cornil.fritz.box/` shows a small page that links to each application (ADR 0004). Any other path that is not an app returns 404.

To add an application to the page:
1. In `ansible/templates/Caddyfile.j2`, add its `redir` line and `handle_path` block (copy the existing two), and add its `*_upstream` variable to `ansible/group_vars/all.yml`.
2. In the same file, add one entry to `portal_apps` (name, path, icon, description). There is a commented example.
3. `make check` fails if a listed path has no route, no redirect or no link on the page.
4. `make deploy`. Caddy is reloaded in place; nothing restarts.

To look at the page without a server: `make render`, then open `build/portal/index.html` in a browser.

## Where to read
- `CLAUDE.md`: secrets, privacy and working rules.
- `docs/prompts/GATEWAY.md`: the task definition (Part A is this repo).
- `docs/design.md` and `docs/decisions/`: the design and its decisions (written in G1).
- Podman concepts in plain language: [`docs/podman-explained.md`](docs/podman-explained.md) (copied from the tax repo, which holds the original).

## Getting started on a new clone
    make hooks    # turn on the secret scan before every commit
    make check    # run all checks

Real addresses, usernames and keys live only in `local/` (git-ignored). Copy the `*.example.*`
files there and edit the copies.

## Everyday commands
Routine commands use SSH as the service user and never ask for the sudo password. `make help` lists all of them.

    make deploy              # install or update Caddy (add HTTP_PORT=8080 HTTPS_PORT=8443 for the trial ports)
    make status              # read-only overview
    make smoke               # end-to-end check through the gateway (needs local/cornil-root.crt: make root-cert)
    make root-cert           # fetch the PUBLIC root certificate; install it on devices (docs/trust-root-cert.md)
    make backup-caddy-data   # back up the CA on the server
    make restore-drill BACKUP=<name>       # prove a backup is usable (touches nothing live)
    make restore-caddy-data BACKUP=<name>  # replace the live CA data with a backup
    make check               # secret scan + tests (needs: brew install caddy gitleaks)

PostgreSQL (no sudo; see `docs/postgres.md`):

    make pg-deploy-check             # rehearse
    make pg-deploy                   # install an empty PostgreSQL
    make pg-status                   # read-only overview
    make pg-create-app APP=<name>    # add an app's database, login and password secret

Backups and disk health (see `docs/recovery.md` section 7; nightly dump deployed in U4; offsite copy on the owner's NAS since 2026-11-09, see `docs/offsite-backup.md`; quarterly checklist in `docs/recovery.md` 7.8):

    make pg-backup-deploy            # install the nightly PostgreSQL dump
    make pg-backup-now               # take a dump now
    make pg-restore-drill            # prove the newest dump restores (live data untouched)
    make pg-restore DB=<db> DUMP=<file>   # replace a database from a dump (asks for RESTORE)
    make restic-secret NAME=<name>   # create a Podman secret on the server from a hidden prompt there
    make restic-deploy               # install the offsite backup service and timer (schedule and target come from local/vars.yml)
    make disk-status                 # disk health summary

Four targets marked `[SUDO]` (`bootstrap-ports`, `cutover`, `rollback-legacy`, `bootstrap-disk-health`) ask for the sudo password; each playbook's first lines say exactly what it changes.
