# ADR 0006: mount guard, cluster locale, PostgreSQL version, image storage

Status: **Proposed** 2026-11-03
Date: 2026-11-03

## Context
Units that use `/u01` must not start against the empty mount point if the USB disk is missing. Phase U0 tested this on the real server with throw-away user units (removed afterwards).

## Decision
1. **Mount guard.** `RequiresMountsFor=/u01` is **not sufficient** in a rootless user unit. Test result: systemd turns it into `After=u01.mount` only, with no `Requires=`; a unit therefore starts even when the mount is missing. Use instead, in the `[Service]` section of each unit that needs `/u01` (the Quadlet `[Service]` passthrough):
```
ExecStartPre=/usr/bin/mountpoint -q /u01
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
```
`mountpoint -q` exits non-zero for a folder that is not a mount point (tested: `/u01` passes, `/u01/data` fails with status 32). With `StartLimitIntervalSec=0` and `Restart=on-failure` the unit keeps retrying until the guard passes (tested with a flag file standing in for the disk: three retries, then it started when the flag appeared). `RequiresMountsFor=/u01` may stay as extra ordering at boot. `ConditionPathIsMountPoint=/u01` was also tested; it silently skips the start instead of failing and retrying, so it is not used.
2. **Which units.** `postgres` and both app units. **Not** Caddy: its files are on the eMMC, so the proxy and portal stay up if the disk is missing.
3. **Cluster locale.** Keep the image default `en_US.utf8` (owner approved). Sort order comes from the operating system inside the image, so: pin the exact image tag, re-index (`REINDEX`) after any image bump that changes the OS, and apps must set an explicit ordering wherever order is displayed or exported. A single database can be created with another locale from `template0` if one app needs it.
4. **PostgreSQL major version: 17** (matches Debian 13's client tools).
5. **Podman image storage stays on the eMMC.** Owner first asked for `/u01`, then reverted after the review: the store uses about 1 GB of 18 GB free, one Linux user has one image store (a split between Caddy and the apps is not possible without separate networks), and keeping it on the eMMC lets the proxy and portal survive a disk fault. **Builds use `/u01` for temporary files** (a temp-folder setting, to be added in U1 and checked there) so image builds do not wear the eMMC. The unused images (about 790 MB) may be pruned by the owner.

## Consequences
- Contract v1 text "Units" changes from "starting assumption `RequiresMountsFor=/u01`" to the four lines above.
- The guard cannot be proven for a truly absent disk without unmounting `/u01` (which would stop the running containers); the proof is by the real `mountpoint` command on a non-mount-point path plus the retry behaviour. The owner can repeat it at a quiet moment.

## Not verified here
Whether the immutable flag on the unmounted `/u01` mount point is set (needs `sudo umount`; see U0 owner-run commands). USB reset check (`dmesg`) and the rootful-container check are owner-run and still outstanding.
