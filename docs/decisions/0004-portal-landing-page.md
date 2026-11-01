# ADR 0004: an HTML portal page at `/`

Status: **Proposed** 2026-11-01 (built unattended on a branch; not deployed; the owner decides)
Date: 2026-11-01

## Context
`https://cornil.fritz.box/` answered with one line of plain text (`cornil: parts-db and tax-healthcare`) from a `respond` in the Caddyfile. The owner wants a formatted page that links to the applications, and expects to add a third application later.

## Decision
1. **A single static HTML page**, rendered by Ansible from `ansible/templates/portal/index.html.j2`. Inline CSS only: no scripts, no external fonts, images or CDNs (the host is LAN-only). Light and dark mode follow the device setting.
2. **One list drives the page.** `portal_apps` in `ansible/group_vars/all.yml` holds one entry per app (name, path, icon, description). To add an app: add its `handle_path` block and upstream variable to the Caddyfile template, then add one entry to the list. `scripts/test.sh` fails if a listed path has no matching route, no redirect, or no link on the page.
3. **Where it lives.** `deploy.yml` writes it to `~/cornil-gateway/config/portal/index.html` on the server. That folder is already mounted read-only at `/etc/caddy`, so the Quadlet unit is unchanged and Caddy is not restarted. The page is written before the Caddyfile that refers to it goes live, so Caddy never points at a missing file. `gateway_portal_dir` (default `/etc/caddy/portal`) is a variable so tests can point it at a local folder.
4. **Only exactly `/` serves the page.** Any other path that is not an app (for example `/nope` or `/index.html`) returns `404 Not found`. This is a change: before, every unknown path returned `200` with the plain text. The `redir` lines and both `handle_path` proxy blocks are untouched.
5. **Headers on the page:** `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a strict `Content-Security-Policy` (inline styles and `data:` images only). No HSTS (still off, see ADR 0001).

## Consequences
- Anything that relied on the old plain-text answer breaks. In this repo that was `scripts/smoke.sh` and one check in `scripts/test.sh`; both are updated. Nothing else here depended on it.
- The page makes no calls to the apps, so it shows no live status and leaks nothing from them.
- A change that only edits the page needs no Caddy reload; a change to routes does (the existing `make deploy` handles it, and restores the previous Caddyfile if the reload fails).
- Rollback: `Caddyfile.previous` is kept on the server by `make deploy`; or revert the commit and run `make deploy`. The `portal/` folder may stay; it is harmless.

## Not verified here
Behaviour on the real server (file permissions of `config/portal/` inside the rootless container, and the live `make deploy` / `make smoke`) was not tested; that needs the owner's machine.
