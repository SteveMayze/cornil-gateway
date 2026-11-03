#!/bin/bash
# REPLACES a live database with a dump. Safe by construction: it takes a safety dump first, restores into a NEW
# database, checks the row counts, and only then renames: the current database is renamed ASIDE (<db>_old_<time>),
# never dropped, and the new one takes its name. Stop the app that uses the database first.
# Needs CONFIRM=RESTORE in the environment (the Makefile asks the owner to type it).
# Usage: CONFIRM=RESTORE pg-restore.sh <db> <dump file name>
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pg-lib.sh"
BACKUP_ROOT=${BACKUP_ROOT:?BACKUP_ROOT must be set}
[ "${CONFIRM:-}" = RESTORE ] || die "not confirmed (CONFIRM=RESTORE is required)"
db=${1:?database}; dump=${2:?dump file name}
valid_db "$db" || die "bad database name"
valid_dump "$db" "$dump" || die "not a dump file name for $db: $dump"
dir="$BACKUP_ROOT/$db"; [ -s "$dir/$dump" ] || die "dump file missing or empty"
[ "$(pg_tA -d postgres -c "select 1 from pg_database where datname = '$db'")" = 1 ] || die "database $db does not exist; create it with make pg-create-app first"

ts=$(date -u +%Y%m%dt%H%M%S)
new="${db}_restoring_$ts"; aside="${db}_old_$ts"
{ valid_restoring_name "$new" && valid_aside_name "$aside"; } || die "internal name check failed"
tmpd=$(mktemp -d); trap 'rm -rf "${tmpd:?}"' EXIT

echo "1/5 safety dump of the current $db"
SKIP_RETENTION=1 "$here/pg-dump.sh" "$db" || die "safety dump failed; nothing was changed"
echo "2/5 restoring $dump into the new database $new"
pg -d postgres -c "CREATE DATABASE \"$new\"" || die "cannot create $new"
if ! "$PODMAN" exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$new" --exit-on-error < "$dir/$dump"; then
  echo "pg_restore failed. $new is left in place for inspection; $db was not changed." >&2; exit 1
fi
echo "3/5 checking row counts"
counts_in_dump "$dir/$dump" > "$tmpd/dump.counts"; counts_in_db "$new" > "$tmpd/db.counts"
compare_counts "$tmpd/dump.counts" "$tmpd/db.counts" || { echo "Row counts differ. $new is left in place; $db was not changed." >&2; exit 1; }
echo "4/5 switching: current $db becomes $aside, $new becomes $db"
pg -d postgres -c "ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS false" || die "cannot close $db"
pg -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$db' and pid <> pg_backend_pid()" > /dev/null
pg -d postgres -c "ALTER DATABASE \"$db\" RENAME TO \"$aside\"" || die "rename failed; $db is closed, reopen it with: ALTER DATABASE $db WITH ALLOW_CONNECTIONS true"
pg -d postgres -c "ALTER DATABASE \"$new\" RENAME TO \"$db\"" || die "second rename failed; rename $aside back to $db by hand"
echo "5/5 ownership and access"
pg -d postgres -c "ALTER DATABASE \"$db\" OWNER TO \"$db\"" -c "REVOKE ALL ON DATABASE \"$db\" FROM PUBLIC"
echo "RESTORE_OK $db from $dump. The previous database is kept as $aside (never dropped by these tools)."
