# Disk health for `/u01`

Status: **built, not deployed** (Phase U3). Decision record: ADR 0007.

## Why this matters
`/u01` is a USB hard disk that gets its power from the USB cable ("bus-powered"). Two things can go wrong: the disk itself wears out, or the power is marginal and the disk briefly disconnects ("a USB reset"). Both can corrupt data before you notice. The disk reports its own condition (called **SMART**, a built-in self-check). Reading it needs administrator rights, so we do it in a small way that keeps the rest of the system unprivileged.

## What is installed, and what it can and cannot do
A one-time step (`make bootstrap-disk-health`, **uses sudo**, you type the administrator password) installs:
- the package `smartmontools` (the standard tool for reading SMART);
- a small root-owned script `/usr/local/sbin/cornil-disk-health` and a systemd timer that runs it **daily as root**;
- the folder `/var/lib/cornil-disk-health`, holding one small text file `status`.

The script writes only health words and counters: no serial number, no address, no file name. The service user (`homeapps`) is **not** added to any group and gets no new rights; it simply reads the status file. `make disk-status` shows that file, without sudo.

## Reading `make disk-status`
| Line | Normal | What to do if not |
|---|---|---|
| `smart_overall` | `PASSED` | Anything else: back up now (`make pg-backup-now`), then plan to replace the disk. |
| `reallocated_sectors`, `pending_sectors`, `offline_uncorrectable` | `0` | Any number above 0 means the disk is already failing spots on its surface. Treat as a warning: confirm the offsite backup is current, and plan a replacement. Rising numbers: replace soon. |
| `udma_crc_errors` | `0` | Rising means a bad cable or connection; try another USB cable. |
| `usb_resets_since_boot` | `0` | Above 0: the disk disconnected briefly. Suspect power: use a shorter cable, a powered USB hub, or another USB port. |
| `io_errors_since_boot`, `ext4_errors_since_boot` | `0` | Above 0: stop writing, take a dump, check `docs/recovery.md`. |
| `temperature_c` | below about 50 | Better airflow. |
| `power_on_hours` | grows over time | Information only; a typical disk is good for several years of hours. |
| `checked_at` | within the last day | Older: the timer is not running; `systemctl status cornil-disk-health.timer` as the administrator. |

If `make disk-status` says "No status file yet", run `make bootstrap-disk-health` once.

## The monthly long self-test (a proposal for you to approve)
The disk can test its entire surface by itself (`smartctl -t long`). It runs inside the disk, takes some hours for 1 TB, slows the disk a little while it runs, and is the best early-warning test there is. **It is OFF.** To approve it, put `disk_smart_long_test: true` in `local/vars.yml` and run `make bootstrap-disk-health` again; it then runs on the first of each month at 03:00 (`disk_smart_long_test_calendar`). The result shows up in `last_self_test` of the status file. Say no and nothing changes.

## One-time check from the earlier inspection
In Phase U0 you ran `dmesg | grep -i -E 'usb|reset|I/O error'` once: no resets and no I/O errors after the reboot. The daily job repeats that check forever.
