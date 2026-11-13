#!/bin/bash
# Tests for the PostgreSQL backup tools and the disk health job. They run the REAL files
# (ansible/files/pgtools/*.sh and the rendered disk-health script) against a stand-in `podman`, `smartctl` and
# `dmesg` that live in a temporary folder. No server and no database are involved.
# Called from scripts/test.sh with the folder of the rendered files; can also be run by itself:
#   bash scripts/test-pgtools.sh <rendered-dir>
set -u
cd "$(dirname "$0")/.."
exec < /dev/null   # the stand-in tools must never wait for a terminal or a pipe
R=${1:?rendered dir (from make render)}
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
TOOLS=$PWD/ansible/files/pgtools

# ---- stand-in podman -----------------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/podman" <<'STUB'
#!/bin/bash
# Stand-in for `podman exec [-i] postgres <tool> ...`. Logs every SQL statement it is given to $STUB_LOG.
args="$*"
[ "$1" = exec ] || { echo "stub: unexpected $args" >&2; exit 99; }
case "$args" in
  *" pg_dump "*)
    db=${args##* }
    [ "$db" = baddb ] && { echo "pg_dump: error" >&2; exit 1; }
    printf 'DUMPDATA %s\n' "$db" ;;
  *" pg_restore --list"*)
    read -r first; case "$first" in DUMPDATA*) exit 0 ;; *) echo "not a dump" >&2; exit 1 ;; esac ;;
  *" pg_restore --data-only"*)
    cat > /dev/null
    printf 'COPY public.parts_part (id, name) FROM stdin;\n1\ta\n2\tb\n3\tc\n\\.\n'
    printf 'COPY public."order" (id) FROM stdin;\n1\n\\.\n' ;;
  *" pg_restore "*)
    cat > /dev/null; echo "RESTORE_INTO $args" >> "$STUB_LOG"
    [ -n "${STUB_RESTORE_FAILS:-}" ] && exit 1; exit 0 ;;
  *" psql "*)
    stdin=""; [ -t 0 ] || stdin=$(cat)
    sql="$args $stdin"
    echo "SQL: $sql" | tr '\n' ' ' >> "$STUB_LOG"; echo >> "$STUB_LOG"
    case "$sql" in
      *"select datname from pg_database"*) printf 'partsdb\ntaxtool\nbaddb\n' ;;
      *"select 1 from pg_database where datname"*) echo 1 ;;
      *"information_schema.tables"*)
        printf 'public.parts_part\t%s\npublic.order\t1\npublic.empty_table\t0\n' "${STUB_PARTS_COUNT:-3}" ;;
    esac ;;
  *) echo "stub: unhandled $args" >&2; exit 98 ;;
esac
STUB
chmod +x "$T/bin/podman"
export PATH="$T/bin:$PATH" STUB_LOG="$T/psql.log" BACKUP_ROOT="$T/backups"
mkdir -p "$BACKUP_ROOT"; : > "$STUB_LOG"
export KEEP_DAILY=14 KEEP_MONTHLY=12

echo "2c. PostgreSQL backup tools (real scripts, stand-in podman)"
check "scripts are syntactically valid bash" "for f in $TOOLS/*.sh; do bash -n \$f || exit 1; done"

# ---- name guards ---------------------------------------------------------------------------------------
check "drill guard accepts only drill_<db>_<time> names" "
  . $TOOLS/pg-lib.sh
  valid_drill_name drill_partsdb_20261103t021500 &&
  ! valid_drill_name partsdb && ! valid_drill_name postgres && ! valid_drill_name drill_ &&
  ! valid_drill_name 'drill_x;drop' && ! valid_drill_name partsdb_old_20261103t021500 && ! valid_drill_name 'drill_partsdb_20261103T021500'"
check "dump file names cannot contain a path or belong to another database" "
  . $TOOLS/pg-lib.sh
  valid_dump partsdb partsdb-20261103T021500Z.dump &&
  ! valid_dump partsdb ../partsdb-20261103T021500Z.dump && ! valid_dump partsdb taxtool-20261103T021500Z.dump &&
  ! valid_dump partsdb 'partsdb-20261103T021500Z.dump;x'"

# ---- dump ----------------------------------------------------------------------------------------------
out=$("$TOOLS/pg-dump.sh" 2>"$T/dump.err"); rc=$?
check "dump: every database is dumped; the broken one makes the run fail but not the others" "[ $rc -ne 0 ] && echo '$out' | grep -q 'DUMP_OK partsdb' && echo '$out' | grep -q 'DUMP_OK taxtool' && grep -q 'DUMP_FAILED baddb' $T/dump.err"
check "dump: files land in <root>/<db>/<db>-<UTC time>.dump, mode 600, content verified" "
  f=\$(ls $BACKUP_ROOT/partsdb/partsdb-*Z.dump) && head -1 \$f | grep -q 'DUMPDATA partsdb' && [ \"\$(stat -f %Lp \$f 2>/dev/null || stat -c %a \$f)\" = 600 ]"
check "dump: nothing temporary is left behind, also after a failure" "[ -z \"\$(find $BACKUP_ROOT -name '*.tmp')\" ] && [ ! -e $BACKUP_ROOT/baddb/*.dump ]"
check "dump: refuses a relative backup folder" "! BACKUP_ROOT=relative/path $TOOLS/pg-dump.sh partsdb"

# ---- retention -----------------------------------------------------------------------------------------
R1=$T/ret; mkdir -p "$R1"
python3 -I - "$R1" <<'PY'
import datetime, sys, pathlib
d = pathlib.Path(sys.argv[1])
today = datetime.date(2026, 11, 3)
for i in range(0, 120):                      # one dump a day for 120 days
    day = today - datetime.timedelta(days=i)
    for hh in (2, 14) if i < 3 else (2,):   # two dumps on the newest three days
        (d / f"partsdb-{day:%Y%m%d}T{hh:02d}0000Z.dump").write_text("x")
for i in range(1, 30):                       # other files that must never be touched
    pass
(d / "notes.txt").write_text("x")
(d / ".partsdb-20200101T000000Z.dump.tmp").write_text("x")
(d / "taxtool-20200101T000000Z.dump").write_text("x")
(d / "partsdb-20200101T000000Z.dump.bak").write_text("x")
PY
"$TOOLS/pg-retention.sh" "$R1" partsdb 14 12 --dry-run > "$T/ret.dry"
check "retention: --dry-run deletes nothing" "[ \"\$(ls -A $R1 | wc -l | tr -d ' ')\" = \"\$(( 120 + 3 + 4 ))\" ]"
"$TOOLS/pg-retention.sh" "$R1" partsdb 14 12 > "$T/ret.out"
check "retention: keeps exactly what the rule says (independent re-computation)" "python3 -I - $R1 <<'PY'
import datetime, sys, pathlib, re
d = pathlib.Path(sys.argv[1])
today = datetime.date(2026, 11, 3)
allf = []
for i in range(0, 120):
    day = today - datetime.timedelta(days=i)
    for hh in ((14, 2) if i < 3 else (2,)):
        allf.append(f'partsdb-{day:%Y%m%d}T{hh:02d}0000Z.dump')
allf.sort(reverse=True)
keep = {allf[0]}
days, mons = [], []
for f in allf:
    s = f.split('-')[-1]; day, mon = s[:8], s[:6]
    if day not in days: days.append(day); (len(days) <= 14) and keep.add(f)
    if mon not in mons: mons.append(mon); (len(mons) <= 12) and keep.add(f)
have = {p.name for p in d.iterdir() if re.fullmatch(r'partsdb-\d{8}T\d{6}Z\.dump', p.name)}
assert have == keep, (sorted(have ^ keep)[:5], len(have), len(keep))
PY"
check "retention: always keeps the newest dump" "ls $R1 | grep -q 'partsdb-20261103T140000Z.dump'"
check "retention: never touches other files, other databases, temp or backup copies" "[ -e $R1/notes.txt ] && [ -e $R1/.partsdb-20200101T000000Z.dump.tmp ] && [ -e $R1/taxtool-20200101T000000Z.dump ] && [ -e $R1/partsdb-20200101T000000Z.dump.bak ]"
check "retention: refuses a database name that could escape the folder" "! $TOOLS/pg-retention.sh $R1 '../x' 14 12 --dry-run"

# ---- drill ---------------------------------------------------------------------------------------------
: > "$STUB_LOG"
out=$("$TOOLS/pg-restore-drill.sh" partsdb 2>&1); rc=$?
check "drill: prints DRILL_OK and exits 0 when counts match the dump's contents" "[ $rc -eq 0 ] && echo '$out' | grep -q 'DRILL_OK partsdb'"
check "drill: creates and drops one throw-away database, and nothing else" "
  [ \"\$(grep -c 'CREATE DATABASE' $STUB_LOG)\" = 1 ] && [ \"\$(grep -c 'DROP DATABASE' $STUB_LOG)\" = 1 ] &&
  grep 'CREATE DATABASE' $STUB_LOG | grep -Eq 'drill_partsdb_[0-9]{8}t[0-9]{6}' &&
  grep 'DROP DATABASE' $STUB_LOG | grep -Eq 'drill_partsdb_[0-9]{8}t[0-9]{6}' &&
  ! grep -E 'DROP DATABASE' $STUB_LOG | grep -Ev 'drill_partsdb_' | grep ."
: > "$STUB_LOG"
out=$(STUB_PARTS_COUNT=99 "$TOOLS/pg-restore-drill.sh" partsdb 2>&1); rc=$?
check "drill: a row-count mismatch fails the drill, names the table, and still drops the throw-away database" "
  [ $rc -ne 0 ] && echo '$out' | grep -q 'DIFFERENT public.parts_part dump=3 database=99' && echo '$out' | grep -q DRILL_FAILED && [ \"\$(grep -c 'DROP DATABASE' $STUB_LOG)\" = 1 ]"
: > "$STUB_LOG"
check "drill: a failing restore still cleans up and fails" "STUB_RESTORE_FAILS=1 $TOOLS/pg-restore-drill.sh partsdb; [ \$? -ne 0 ] && grep -q 'DROP DATABASE' $STUB_LOG"
: > "$STUB_LOG"
check "drill: refuses a dump name with a path or from another database, before touching the database" "
  ! $TOOLS/pg-restore-drill.sh partsdb ../taxtool-20261103T021500Z.dump && ! $TOOLS/pg-restore-drill.sh partsdb taxtool-20261103T021500Z.dump && [ ! -s $STUB_LOG ]"
check "drill: refuses a database name that is not an app name" "! $TOOLS/pg-restore-drill.sh 'x;drop' && ! $TOOLS/pg-restore-drill.sh '../x'"
# A dump fetched from the offsite copy lives in another folder (the restore scratch folder).
FETCHED="$T/restore-scratch/backup/u01/data/backups/postgres/partsdb"
mkdir -p "$FETCHED"
src=$(ls "$BACKUP_ROOT/partsdb" | grep -E '^partsdb-.*Z\.dump$' | head -1)
cp "$BACKUP_ROOT/partsdb/$src" "$FETCHED/partsdb-20991231T000000Z.dump"
: > "$STUB_LOG"
out=$("$TOOLS/pg-restore-drill.sh" partsdb "" "$FETCHED/" 2>&1); rc=$?
check "drill: with a dump folder, drills the newest dump from THAT folder (not the live one) and prints DRILL_OK" "
  [ $rc -eq 0 ] && echo '$out' | grep -q 'DRILL_OK partsdb partsdb-20991231T000000Z.dump' && echo '$out' | grep -q 'not the live dump folder' &&
  ! ls $BACKUP_ROOT/partsdb | grep -q 20991231"
check "drill: with a dump folder, still creates and drops only a throw-away database" "
  grep 'CREATE DATABASE' $STUB_LOG | grep -Eq 'drill_partsdb_[0-9]{8}t[0-9]{6}' && ! grep -E 'DROP DATABASE' $STUB_LOG | grep -Ev 'drill_partsdb_' | grep ."
: > "$STUB_LOG"
check "drill: refuses a relative, '..' or missing dump folder, before touching the database" "
  ! $TOOLS/pg-restore-drill.sh partsdb '' restore-scratch && ! $TOOLS/pg-restore-drill.sh partsdb '' '$FETCHED/../../postgres' &&
  ! $TOOLS/pg-restore-drill.sh partsdb '' '$T/does-not-exist' && [ ! -s $STUB_LOG ]"
check "drill: the dump-name check still applies inside a dump folder" "! $TOOLS/pg-restore-drill.sh partsdb ../x.dump '$FETCHED' && ! $TOOLS/pg-restore-drill.sh partsdb taxtool-20261103T021500Z.dump '$FETCHED'"

# ---- real restore --------------------------------------------------------------------------------------
dump=$(ls "$BACKUP_ROOT/partsdb" | grep -E '^partsdb-.*Z\.dump$' | head -1)
: > "$STUB_LOG"
check "restore: refuses without CONFIRM=RESTORE and changes nothing" "! $TOOLS/pg-restore.sh partsdb $dump && [ ! -s $STUB_LOG ]"
: > "$STUB_LOG"
out=$(CONFIRM=RESTORE "$TOOLS/pg-restore.sh" partsdb "$dump" 2>&1); rc=$?
check "restore: prints RESTORE_OK" "[ $rc -eq 0 ] && echo '$out' | grep -q 'RESTORE_OK partsdb'"
check "restore: renames the old database aside and never drops anything" "
  grep -Eq 'RENAME TO .partsdb_old_[0-9]{8}t[0-9]{6}' $STUB_LOG && grep -Eq 'partsdb_restoring_[0-9]{8}t[0-9]{6}. RENAME TO .partsdb' $STUB_LOG && ! grep -q 'DROP DATABASE' $STUB_LOG"
check "restore: the source dump still exists afterwards (the safety dump must not thin it out)" "[ -s $BACKUP_ROOT/partsdb/$dump ]"
check "restore: takes a safety dump before changing anything" "[ \"\$(ls $BACKUP_ROOT/partsdb | grep -c 'Z.dump\$')\" -ge 2 ] && [ \"\$(echo '$out' | grep -n 'safety dump' | head -1 | cut -d: -f1)\" = 1 ]"
: > "$STUB_LOG"
check "restore: a mismatch stops before the rename" "! STUB_PARTS_COUNT=99 CONFIRM=RESTORE $TOOLS/pg-restore.sh partsdb $dump && ! grep -q 'RENAME TO' $STUB_LOG"

# ---- disk health job -----------------------------------------------------------------------------------
echo "2d. Disk health job (rendered script, stand-in smartctl and dmesg)"
mkdir -p "$T/dh/bin" "$T/dh/out"
cat > "$T/dh/bin/smartctl" <<'STUB'
#!/bin/sh
echo "Serial Number:    FAKESERIAL123"
case "$*" in
  *-H*) echo "SMART overall-health self-assessment test result: PASSED" ;;
  *-A*) cat <<EOT
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   099   099   000    Old_age   Always       -       1234
 12 Power_Cycle_Count       0x0032   100   100   000    Old_age   Always       -       56
194 Temperature_Celsius     0x0022   034   040   000    Old_age   Always       -       34 (Min/Max 20/45)
197 Current_Pending_Sector  0x0032   100   100   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0030   100   100   000    Old_age   Offline      -       0
199 UDMA_CRC_Error_Count    0x0032   200   200   000    Old_age   Always       -       0
EOT
  ;;
  *selftest*) echo "# 1  Short offline       Completed without error       00%      1200         -" ;;
esac
STUB
printf '#!/bin/sh\nprintf "[    1.0] usb 2-1: reset SuperSpeed USB device number 2\\n[    2.0] usb 2-1: reset SuperSpeed USB device number 2\\n[    3.0] blk_update_request: I/O error, dev sda\\n"\n' > "$T/dh/bin/dmesg"
printf '#!/bin/sh\necho /dev/sda1\n' > "$T/dh/bin/findmnt"
printf '#!/bin/sh\necho sda\n' > "$T/dh/bin/lsblk"
chmod +x "$T/dh/bin/"*
# render the script with the output folder pointing into the temp folder
ANSIBLE_CONFIG=ansible/ansible.cfg .venv-infra/bin/ansible-playbook -i localhost, ansible/render.yml -e "render_dir=$T/dh/r" -e @ansible/group_vars/all.yml -e "disk_health_status_dir=$T/dh/out" >/dev/null 2>&1
CORNIL_PATH="$T/dh/bin:/usr/bin:/bin" bash "$T/dh/r/disk-health.sh"; rc=$?
S=$T/dh/out/status
check "disk health: rendered script runs and writes the status file" "[ $rc -eq 0 ] && [ -s $S ]"
check "disk health: reports SMART health, counters and the USB/I-O error counts" "
  grep -q '^smart_overall=PASSED' $S && grep -q '^reallocated_sectors=0' $S && grep -q '^power_on_hours=1234' $S &&
  grep -q '^temperature_c=34' $S && grep -q '^pending_sectors=0' $S && grep -q '^usb_resets_since_boot=2' $S && grep -q '^io_errors_since_boot=1' $S"
check "disk health: the status file contains no serial number" "! grep -qi 'serial\|FAKESERIAL' $S"
check "disk health: the status file is world-readable and replaced atomically (no temp files left)" "[ \"\$(stat -f %Lp $S 2>/dev/null || stat -c %a $S)\" = 644 ] && [ \"\$(ls -A $T/dh/out | wc -l | tr -d ' ')\" = 1 ]"

[ "$fail" = 0 ]
