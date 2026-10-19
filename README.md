# cornil-gateway

The single owner of the Caddy reverse proxy on the home server `cornil` (`cornil.fritz.box`).
It serves two Django apps over HTTPS:

- `https://cornil.fritz.box/parts-db` (repo: SteveMayze/parts-db)
- `https://cornil.fritz.box/tax-healthcare` (repo: SteveMayze/Tax-and-KK-Tool)

No other repository may contain Caddy configuration or write to the proxy's files.

**Status:** phase G1 (design written, awaiting owner approval). Nothing is deployed yet.

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
