# Offsite backup with restic

Status: **live since 2026-11-09** on the owner's Synology NAS `barnes.fritz.box` over SFTP (option A below, but in the same home; see "What is running now"). The restore proof from the NAS is still owed. Decision record: ADR 0007. Setup record: `docs/offsite-backup-synology.md`.

## What is running now
- **Where:** a restic repository in one shared folder of the NAS, reached over SFTP with a key. The NAS user is a normal user without a shell. Names are in `local/vars.yml` only.
- **When:** three attempts a day, at 11:00, 14:00 and 17:00 (plus up to 30 minutes), because the NAS and the network are off most nights. This is the `restic_calendar` override in `local/vars.yml`; the repo default (04:30) would never find the NAS on.
- **What:** `/u01/data/backups` (the database dumps) and `/u01/data/parts-db/backups`. The Tax tool's folder is added to `restic_backup_paths` when it exists.
- **One snapshot per day is normal.** Each run saves a snapshot, then the clean-up keeps only the newest of the day.
- **When the NAS is off** (night, holiday): the run cannot connect and ends as `failed`; the next slot tries again and nothing is lost or deleted (the retention counts days that have a snapshot). You see it with `systemctl --user --failed` and `journalctl --user -u restic-backup.service`. A quiet "skipped" instead of "failed" is planned (ADR 0007, open item 4).
- **The limit you accepted:** the NAS stands in the same home as the server. This copy saves you from a dead disk or a mistake, not from fire or theft. For that, add one of the options B, C or D below later.
- **How to look:** `systemctl --user list-timers | grep restic` (next run), `systemctl --user status restic-backup.service` (last result).

## Why you need a copy somewhere else
Everything so far sits in one room: the database on `/u01`, its nightly dumps on `/u01`, the app backup archives on `/u01`. A fire, a theft, a power surge or a dead USB disk takes all of them at once. An **offsite** copy is a copy in another place (another house, or a company's data centre) that survives all of those.

## What restic is, in plain words
`restic` is a free backup program. It does four things that matter to you:
- **Encrypts everything before it leaves the server.** The place you store the copy only ever sees scrambled data; it cannot read your tax or health files, and neither can anyone who breaks into it.
- **Never sends the same data twice.** The second night only uploads what changed, so nightly backups of large archives stay small.
- **Keeps dated snapshots.** You can ask for "the server as it was on 3 November" and get exactly that.
- **Works with many kinds of storage** (another computer over SSH, cloud buckets, storage services).

Words you will meet: the **repository** is the place where the encrypted copy lives; a **snapshot** is one dated backup inside it; **forget/prune** removes snapshots you no longer need under a retention rule (here: 7 daily, 5 weekly, 12 monthly) and frees the space; **check** reads the repository to confirm it is intact.

## The one thing you must do
> **The restic password is the key to the offsite copy. If it is lost, the offsite copy cannot be read by anyone, ever, including you. Keep a copy of it OUTSIDE the server** (for example in your password manager and on paper in a safe place). If the server burns down, the password stored only on the server burns with it, and the offsite copy becomes useless.

You type the password yourself, at a hidden prompt, when we set this up (Phase U4). It never appears in chat, in this repository or in any log.

## What gets sent
Read-only, from `/u01`: the nightly database dumps (`/u01/data/backups`), parts-db's own archives (`/u01/data/parts-db/backups`) and the Tax tool's archives (`/u01/data/tax-healthcare-tool/backups`). The list is `restic_backup_paths` in `ansible/group_vars/all.yml`. **A folder that does not exist yet makes the backup fail** (the two app folders appear only after each app has moved its files to `/u01`); until then override the list in `local/vars.yml` with just the folders that exist. **Not** sent by default: Caddy's certificate data (it contains the private key of your home certificate authority; if you want it offsite, decide that separately and say so), the live database files, the Podman images and the Podman secrets.

## Choosing where to store it
All four options work with the same restic setup; only the repository address (in `local/vars.yml`, never in git) and a credential change. Prices change: check the provider's current page before signing up. The amount of data is small (dedup keeps tens of GB at most), so cost is dominated by the minimum plan, not by size.

| Option | What it is | Monthly cost | Encryption | Restoring | If your home is lost |
|---|---|---|---|---|---|
| **A. A computer or NAS at a friend or relative** | An always-on small machine (for example a Raspberry Pi with a disk) reached over SSH (SFTP) | Hardware once, then electricity | restic encrypts; the machine only holds scrambled data | You need the machine and its owner; slower to reach | Safe if it is in another home. Needs their router set up and trust in the other household. |
| **B. S3-compatible bucket** (for example Backblaze B2, Wasabi, an EU object-storage product) | Rented online storage, billed by GB stored | Usually a few euros for this size; some have a minimum | restic encrypts before upload | Install restic anywhere, give it the bucket key and the password | Safe. Two credentials (access key, secret key) to keep. |
| **C. A "storage box" service with SFTP** (for example Hetzner Storage Box, rsync.net) | A rented folder on a server, reached over SSH like option A | A flat monthly price per size tier | restic encrypts | Same as A, but the provider keeps the machine running | Safe. One SSH key to keep. Simple for a beginner. |
| **D. A USB disk you take to another place** | A disk you copy to and carry away, swapped every few weeks | One disk | restic encrypts | Fetch the disk | Safe up to the last swap; the newest weeks can be lost. Needs your discipline. |

**Recommendation: C, a storage box over SFTP, with a server in the EU.** Reasons: it is the simplest for someone new to this (one SSH key, no cloud console, no keys with long names), the price is flat and small, the provider runs the machine, it is offsite by definition, and because restic encrypts first, your tax and health data stays unreadable to the provider. B is the next best (slightly more to learn, same safety). A is great if you have a trusted person with an always-on machine; D is a useful extra, not a replacement, because the newest data is the part most likely to be lost. You decide in Phase U4; nothing is bought or created before that.

## How it is wired (for reference)
- `restic` runs as a container (`docker.io/restic/restic`, pinned to an exact version), started by a user service, so nothing is installed on the server and no sudo is needed. Files: `ansible/templates/restic-backup.service.j2` and `.timer.j2`, installed by `make restic-deploy`.
- The password is the Podman secret `restic-repo-password`. Target credentials, if any, are further Podman secrets listed in `restic_extra_secrets`. Create each one with `make restic-secret NAME=<secret name>`: it opens an SSH session and asks for the value **on the server**, hidden. It refuses to overwrite an existing secret.
- Your repository address goes into `local/vars.yml` (git-ignored); see `local/vars.example.yml` for fake examples. `make restic-deploy` refuses to run until it is set and all secrets exist.
- The service backs up, then applies the retention rule with `forget --prune`. The repo default runs the timer nightly at 04:30, after the database dump, with `Persistent=true`; on this server `restic_calendar` in `local/vars.yml` overrides it to 11:00, 14:00 and 17:00 (see "What is running now").
- `make restic-deploy` installs the units but **does not enable the timer** and sends nothing. The repository was initialised, the first backup taken and the timer enabled by the owner on 2026-11-09 (`systemctl --user enable --now restic-backup.timer`). A first restore into a scratch folder is still owed.

## Restoring (rehearsed in U4)
In outline: run the restic container with the same repository and password, `restic snapshots` to list, `restic restore <snapshot> --target <scratch folder>` to fetch files into a scratch folder, then run `make pg-restore-drill` on a fetched dump. The exact commands are written and tested in Phase U4 and then copied into `docs/recovery.md`.
