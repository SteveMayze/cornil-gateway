#!/bin/bash
# Nightly dump of every app database: pg_dump -Fc run INSIDE the postgres container, written to
# $BACKUP_ROOT/<db>/<db>-<UTC timestamp>.dump, checked with pg_restore --list, then old dumps thinned out.
# Atomic: written under a temporary name, renamed only when it is complete and readable.
# Usage: pg-dump.sh [db ...]       (no arguments: every database except postgres, templates, drill_*, *_old_*, *_restoring_*)
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pg-lib.sh"
umask 077
BACKUP_ROOT=${BACKUP_ROOT:?BACKUP_ROOT must be set}
KEEP_DAILY=${KEEP_DAILY:-14}
KEEP_MONTHLY=${KEEP_MONTHLY:-12}
case "$BACKUP_ROOT" in /?*) ;; *) die "BACKUP_ROOT must be an absolute folder" ;; esac

if [ "$#" -gt 0 ]; then dbs="$*"; else
  dbs=$(pg_tA -d postgres -c "select datname from pg_database
        where not datistemplate and datname <> 'postgres' and datname !~ '^drill_'
          and datname !~ '_old_[0-9]{8}t[0-9]{6}\$' and datname !~ '_restoring_[0-9]{8}t[0-9]{6}\$' order by 1") || die "cannot list databases"
fi
[ -n "$dbs" ] || { echo "no databases to dump"; exit 0; }

failed=0
for db in $dbs; do
  valid_db "$db" || { echo "SKIP $db (name not allowed)"; failed=1; continue; }
  dir="$BACKUP_ROOT/$db"; mkdir -p "$dir"; chmod 700 "$dir"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  # Never overwrite an existing dump (two dumps in the same second get different names).
  while [ -e "$dir/$db-$ts.dump" ]; do sleep 1; ts=$(date -u +%Y%m%dT%H%M%SZ); done
  final="$dir/$db-$ts.dump"; tmp="$dir/.$db-$ts.dump.tmp"
  if "$PODMAN" exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$db" > "$tmp" \
     && [ -s "$tmp" ] \
     && "$PODMAN" exec -i "$PG_CONTAINER" pg_restore --list < "$tmp" > /dev/null; then
    mv -- "$tmp" "$final"
    echo "DUMP_OK $db $(basename "$final") $(wc -c < "$final" | tr -d ' ') bytes"
    # SKIP_RETENTION=1 is set by pg-restore.sh: its safety dump must never thin out the very dump being restored.
    if [ "${SKIP_RETENTION:-0}" != 1 ]; then
      "$here/pg-retention.sh" "$dir" "$db" "$KEEP_DAILY" "$KEEP_MONTHLY" || { echo "WARNING: retention failed for $db"; failed=1; }
    fi
  else
    rm -f -- "${tmp:?}"
    echo "DUMP_FAILED $db" >&2; failed=1
  fi
done
exit "$failed"
