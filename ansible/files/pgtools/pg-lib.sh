# Shared helpers for the PostgreSQL backup tools (sourced, not run). Managed by cornil-gateway.
# Everything talks to the database through `podman exec` into the `postgres` container, so the client tools
# always have the same version as the server. No password is needed or used: inside the container the
# operating-system user `postgres` is the superuser (pg_hba.conf, "peer").
PODMAN=${PODMAN:-podman}
PG_CONTAINER=${PG_CONTAINER:-postgres}

die() { echo "ERROR: $*" >&2; exit 1; }

pg()    { "$PODMAN" exec -i "$PG_CONTAINER" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
pg_tA() { "$PODMAN" exec -i "$PG_CONTAINER" psql -U postgres -X -tA -v ON_ERROR_STOP=1 "$@"; }

# A database name an app may have: lower-case letters, digits, underscore.
valid_db()   { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9_]{1,40}$'; }
# A dump file name made by pg-dump.sh for database $1 (no directories allowed).
valid_dump() { printf '%s' "$2" | grep -Eq "^$1-[0-9]{8}T[0-9]{6}Z\.dump\$"; }
# The only database names the drill may create and drop.
valid_drill_name() { printf '%s' "$1" | grep -Eq '^drill_[a-z][a-z0-9_]*_[0-9]{8}t[0-9]{6}$'; }
valid_restoring_name() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9_]*_restoring_[0-9]{8}t[0-9]{6}$'; }
valid_aside_name()     { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9_]*_old_[0-9]{8}t[0-9]{6}$'; }

# Row count of every user table in database $1, as "schema.table<TAB>count", sorted.
counts_in_db() {
  pg_tA -d "$1" -F '	' -c "
    select table_schema || '.' || table_name,
           (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
    from information_schema.tables
    where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
    order by 1" | LC_ALL=C sort
}

# Row count of every table that has a data section in dump file $1, read from the dump's own COPY sections
# (what the dump CONTAINS, independent of any database). Same format as counts_in_db.
counts_in_dump() {
  "$PODMAN" exec -i "$PG_CONTAINER" pg_restore --data-only -f - < "$1" | awk '
    /^COPY / { name = $2; gsub(/"/, "", name); n = 0; incopy = 1; next }
    incopy && $0 == "\\." { printf "%s\t%d\n", name, n; incopy = 0; next }
    incopy { n++ }' | LC_ALL=C sort
}

# Compare dump counts ($1) with database counts ($2). Every table in the dump must match exactly;
# a table that is only in the database must be empty. Prints differences; returns non-zero if any.
compare_counts() {
  awk -F '\t' '
    NR == FNR { dump[$1] = $2; next }
    { seen[$1] = 1; have = ($1 in dump) ? dump[$1] : 0
      if ($2 != have) { printf "DIFFERENT %s dump=%s database=%s\n", $1, have, $2; bad = 1 } }
    END { for (t in dump) if (!(t in seen)) { printf "MISSING %s dump=%s\n", t, dump[t]; bad = 1 }
          exit bad }' "$1" "$2"
}

newest_dump() { # $1 dir, $2 db
  ls -1 "$1" 2>/dev/null | grep -E "^$2-[0-9]{8}T[0-9]{6}Z\.dump\$" | sort | tail -1
}
