# cornil-gateway

The single owner of the Caddy reverse proxy on the home server `cornil` (`cornil.fritz.box`).
It serves two Django apps over HTTPS:

- `https://cornil.fritz.box/parts-db` (repo: SteveMayze/parts-db; rootless container `parts-db-web`, reached by name on the `gateway` network)
- `https://cornil.fritz.box/tax-healthcare` (repo: SteveMayze/Tax-and-KK-Tool)

No other repository may contain Caddy configuration or write to the proxy's files.

**Status:** live. The gateway serves both apps on ports 80 and 443. Closing the old plain-HTTP ports is described in `docs/closing-plain-ports.md`; recovery in `docs/recovery.md`.

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
    make smoke               # end-to-end check through the gateway
    make root-cert           # fetch the PUBLIC root certificate; install it on devices (docs/trust-root-cert.md)
    make backup-caddy-data   # back up the CA on the server
    make restore-drill BACKUP=<name>       # prove a backup is usable (touches nothing live)
    make restore-caddy-data BACKUP=<name>  # replace the live CA data with a backup
    make check               # secret scan + tests (needs: brew install caddy gitleaks)

Three targets marked `[SUDO]` (`bootstrap-ports`, `cutover`, `rollback-legacy`) ask for the sudo password; each playbook's first lines say exactly what it changes.
