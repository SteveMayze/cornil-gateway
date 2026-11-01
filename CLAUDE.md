# CLAUDE.md: cornil-gateway

Save as `CLAUDE.md` in the root of the `cornil-gateway` repository. Put `GATEWAY.md` at `docs/prompts/GATEWAY.md`.

## What this repository is
The single owner of the reverse proxy (Caddy) on the home server `cornil` (`cornil.fritz.box`). It serves two Django apps over HTTPS: `/parts-db` and `/tax-healthcare`. No other repository may contain Caddy configuration or write to the proxy's files.

The owner has little Podman and Linux administration experience. Explain every concept in plain language the first time it appears, give each command with a one-line "what this does", and say what normal output looks like and what to do if it fails.

## Secrets and privacy (highest priority)
Nothing sensitive may exist in any tracked file, in commit history, in test fixtures, in logs or in reports.

Never commit, print or paste into a report:
- passwords, tokens, API keys, SSH private keys, the sudo password;
- anything from Caddy's data directory, especially the internal certificate authority's **private key** (`root.key`, `intermediate.key`) and any `*.key` file. Whoever holds the root key can issue certificates that the owner's devices trust;
- the real inventory (host addresses, usernames), the owner's public IP, MAC addresses, Wi-Fi details, backups or copies of the server's files;
- the owner's financial or health data from the apps behind the proxy (the gateway never needs it; do not request it).

Rules:
1. Private and per-machine values live in `local/`, which is git-ignored. The repo contains only placeholders: `local/inventory.example.ini`, `local/vars.example.yml`, `.env.example`. Real files are created by the owner.
2. Secrets are generated on the server or on the owner's machine, never by writing them into a tracked file. The playbooks must not accept a secret as a command-line argument that ends up in shell history or logs (`no_log: true` on tasks that touch secrets).
3. The only thing meant to leave the server is Caddy's **public** root certificate (`root.crt`), fetched with `make root-cert` for installing on the owner's devices. Never fetch or copy the private keys. Backups of the Caddy data directory stay on the server or on the owner's own storage, never in the repo.
4. Before the first commit: `.gitignore` must cover `local/`, `*.key`, `*.pem` (except documented public test files), `*.env`, `*.retry`, `backups/`, `data/`, `.vault_pass`. Verify with `git check-ignore -v` and `git status --ignored`, and show the owner the result.
5. Add a secret scanner as a pre-commit hook and in `make check` (for example `gitleaks`; report if it cannot be installed). A finding blocks the commit.
6. Examples in docs use obviously fake values (`192.0.2.10`, `example-user`). Real hostnames of the home network (`cornil.fritz.box`) are acceptable; addresses, usernames and key paths are not.
7. If something sensitive is ever committed: stop, tell the owner, do not try to hide it with a new commit. Rewriting history and rotating the secret (for the CA key: regenerate the CA and reinstall the root certificate on every device) are the owner's decisions.
8. Reports and tool output shown to the owner are scrubbed: show command output only after removing addresses, usernames and anything that looks like a key.

## How to work
- One phase at a time, with a hard stop and an end-of-phase report (done, commits, checks, deviations, open questions, what was not verified). Wait for the owner's "go".
- Read-only inspection before any change on the host. Never overwrite a file on the host this repository does not own. Back up the old proxy setup first and say where the backup is.
- Rehearse before applying: `ansible-playbook --syntax-check`, `--check`, `caddy validate` on the rendered Caddyfile, and the Quadlet generator in dry-run mode.
- Routine deploys use **no sudo**. Caddy runs as a rootless container of the service user `homeapps`. Only the documented one-time bootstrap (and the port 80/443 system setting) uses sudo; label those steps clearly and give the exact command.
- Each phase has checkable acceptance criteria. Report each as met, not met, or not verifiable here, with evidence. At least one test per feature must exercise the real artifact (rendered Caddyfile, generated unit), not a copy of its text.
- Update this file and add an ADR in `docs/decisions/` after each owner decision. Never delete an old ADR; mark it superseded.
- Do not enable HSTS until the owner has installed the root certificate on every device and https has worked for a while.

## Layout (target)
`Makefile`, `ansible/`, `Caddyfile` template, `docs/` (`design.md`, `trust-root-cert.md`, `podman-explained.md` link, `decisions/`, `prompts/GATEWAY.md`), `local/` (ignored, placeholders only tracked), `scripts/`.

## Not in scope
App code, app databases, tax or health calculations, anything inside parts-db or the Tax and Healthcare Tool repositories (separate sessions; this repo only documents what each app must provide: a URL prefix, its own cookie names, proxy-aware settings).

## Decisions log (details in `docs/decisions/`)
- 2026-10-19 (ADR 0001): Caddy is a rootless container of `homeapps`; one repo owns the proxy; HSTS off; ESP32 route dropped; parts-db goes rootless later. Root certificate for MacBook Pro, iMac, iPhone, iPad, Windows. **Pending owner approval:** sysctl for ports 80/443, parts-db connection test.
- Never print `systemctl cat`, unit files or `Environment=` lines unfiltered: legacy units on the host contain secrets in plain text.
- 2026-10-19 (ADR 0001, accepted): sysctl `ip_unprivileged_port_start=80` approved (applied by the owner with `make bootstrap-ports`); parts-db reached via `host.containers.internal:8888` (tested: fails if parts-db is narrowed to 127.0.0.1); new Caddy runs on trial ports 8080/8443 until `make cutover`. Open: fresh CA vs adopting the January 2026 CA (design Q5).
- Test target `make check` needs local `caddy` and `gitleaks` (brew). Run shell tests with bash, not zsh; give `ssh` the `-n` flag inside scripts.
- 2026-11-01 (ADR 0003): parts-db now runs rootless on `gateway`; `partsdb_upstream: parts-db-web:8000` (old value kept as rollback comment). The rootful container is untouched; closing 8888 is up to the parts-db repo / owner.
- 2026-10-19 (ADR 0002, proposed): gateway is live on 80/443 with the tax app reached by container name; plain ports 8888/8889/8890 to be closed per `docs/closing-plain-ports.md` (parts-db cannot be narrowed to localhost until rootless; optional nftables table `cornil_lan`, never enable the stock `nftables.service`). Restore tooling and `docs/recovery.md` added.
