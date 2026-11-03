#!/bin/bash
# Proves a dump can be restored. Restores it into a THROW-AWAY database, compares the row count of every table
# with what the dump itself contains, drops ONLY that throw-away database, and prints DRILL_OK.
# The live database is never touched. The only database this script may create or drop is named drill_<db>_<time>
# (checked before every create and drop).
# Usage: pg-restore-drill.sh <db> [dump file name]      (default: the newest dump of <db>)
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pg-lib.sh"
BACKUP_ROOT=${BACKUP_ROOT:?BACKUP_ROOT must be set}
db=${1:?database}; valid_db "$db" || die "bad database name"
dir="$BACKUP_ROOT/$db"
dump=${2:-$(newest_dump "$dir" "$db")}
[ -n "$dump" ] || die "no dump found for $db in its backup folder"
valid_dump "$db" "$dump" || die "not a dump file name for $db: $dump"
[ -s "$dir/$dump" ] || die "dump file missing or empty"

name="drill_${db}_$(date -u +%Y%m%dt%H%M%S)"
valid_drill_name "$name" || die "refusing: $name is not a throw-away name"
tmpd=$(mktemp -d)
created=0
cleanup() {
  if [ "$created" = 1 ] && valid_drill_name "$name"; then
    pg -d postgres -c "DROP DATABASE IF EXISTS \"$name\"" && echo "dropped throw-away database $name"
    created=0
  fi
}
trap 'cleanup; rm -rf "${tmpd:?}"' EXIT

echo "restoring $dump into throw-away database $name"
pg -d postgres -c "CREATE DATABASE \"$name\"" || die "cannot create $name"
created=1
"$PODMAN" exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$name" --no-owner --no-acl --exit-on-error < "$dir/$dump" \
  || die "pg_restore failed"
counts_in_dump "$dir/$dump" > "$tmpd/dump.counts"
counts_in_db "$name" > "$tmpd/db.counts"
tables=$(wc -l < "$tmpd/dump.counts" | tr -d ' ')
if compare_counts "$tmpd/dump.counts" "$tmpd/db.counts"; then
  echo "row counts match for $tables tables"
  result=ok
else
  result=bad
fi
cleanup
if [ "$result" = ok ]; then echo "DRILL_OK $db $dump"; exit 0; fi
echo "DRILL_FAILED $db $dump" >&2; exit 1
