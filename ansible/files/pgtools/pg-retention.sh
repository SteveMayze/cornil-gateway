#!/bin/bash
# Deletes old dumps of ONE database, inside ONE folder, keeping:
#   - always the newest dump,
#   - the newest dump of each of the last DAILY days that have a dump,
#   - the newest dump of each of the last MONTHLY months that have a dump.
# Only files named exactly <db>-YYYYMMDDTHHMMSSZ.dump in that folder are ever considered; nothing else is touched.
# Usage: pg-retention.sh <folder> <db> <daily> <monthly> [--dry-run]
set -eu
dir=${1:?folder}; db=${2:?database}; daily=${3:?daily}; monthly=${4:?monthly}; mode=${5:-}
printf '%s' "$db" | grep -Eq '^[a-z][a-z0-9_]{1,40}$' || { echo "bad database name" >&2; exit 2; }
printf '%s' "$daily$monthly" | grep -Eq '^[0-9]+$' || { echo "daily and monthly must be numbers" >&2; exit 2; }
[ -d "$dir" ] || { echo "no such folder" >&2; exit 2; }
doomed=$(ls -1 "$dir" | grep -E "^$db-[0-9]{8}T[0-9]{6}Z\.dump\$" | sort -r | awk -v daily="$daily" -v monthly="$monthly" '
  { stamp = $0; sub(/^.*-/, "", stamp); day = substr(stamp, 1, 8); mon = substr(stamp, 1, 6); keep = 0
    if (NR == 1) keep = 1
    if (!(day in sd)) { sd[day] = 1; nd++; if (nd <= daily) keep = 1 }
    if (!(mon in sm)) { sm[mon] = 1; nm++; if (nm <= monthly) keep = 1 }
    if (!keep) print $0 }')
for f in $doomed; do
  if [ "$mode" = "--dry-run" ]; then
    echo "would delete $f"
  else
    rm -f -- "${dir:?}/${f:?}"
    echo "deleted $f"
  fi
done
