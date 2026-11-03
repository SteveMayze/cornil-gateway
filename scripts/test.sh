#!/bin/bash
# Tests on the REAL artifacts: the rendered Caddyfile is validated and run by a real Caddy in front of two
# stand-in apps; the rendered Quadlet files are inspected; the sudo policy is checked over the Makefile and
# playbooks. Run with: make test   (part of make check)
set -u
cd "$(dirname "$0")/.."
VENV=.venv-infra/bin
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT

echo "1. Playbooks are well-formed"
export ANSIBLE_CONFIG=ansible/ansible.cfg
for p in deploy backup-caddy-data restore-caddy-data status root-cert bootstrap-ports cutover rollback-legacy render postgres-deploy postgres-status pg-create-app pg-backup-deploy pg-backup-now pg-restore-drill pg-restore restic-deploy bootstrap-disk-health disk-status; do
  check "syntax-check $p.yml" "$VENV/ansible-playbook -i local/inventory.example.ini --syntax-check ansible/$p.yml"
done

echo "2. Rendered files (standard ports, then trial ports)"
render() { # $1 = dir, $2.. = extra vars
  d=$1; shift
  $VENV/ansible-playbook -i localhost, ansible/render.yml -e "render_dir=$d" -e @ansible/group_vars/all.yml "$@" >/dev/null
}
render "$tmp/std"
check "Caddyfile uses 80/443 by default" "grep -q 'http_port 80' $tmp/std/Caddyfile && grep -q 'https_port 443' $tmp/std/Caddyfile"
check "Caddyfile has tls internal and no HSTS" "grep -q 'tls internal' $tmp/std/Caddyfile && ! grep -qi strict-transport $tmp/std/Caddyfile"
check "Caddyfile has no API token or Authorization route" "! grep -qiE 'token|Authorization|TEXTECK|local_certs' $tmp/std/Caddyfile"
check "Caddyfile serves the portal from /etc/caddy/portal (inside the existing read-only mount)" "grep -q 'root \\* /etc/caddy/portal' $tmp/std/Caddyfile"
check "portal page is rendered, with no leftover template syntax" "[ -s $tmp/std/portal/index.html ] && ! grep -qE '\\{\\{|\\{%' $tmp/std/portal/index.html"
check "portal page loads nothing external (no scripts, only the SVG namespace URL)" "python3 -I -c \"
import re
h = open('$tmp/std/portal/index.html').read()
assert '<script' not in h.lower()
assert not [u for u in re.findall(r'https?://[^\\s\\\"\\'<>)]+', h) if u != 'http://www.w3.org/2000/svg']
\""
check "every portal_apps path has a matching route in the Caddyfile" "$VENV/python -I -c \"
import sys, yaml
apps = yaml.safe_load(open('ansible/group_vars/all.yml'))['portal_apps']
cf = open('$tmp/std/Caddyfile').read()
assert apps, 'portal_apps is empty'
for a in apps:
    p = a['path']
    assert p.startswith('/') and p.endswith('/'), p
    assert 'handle_path ' + p + '*' in cf, 'no handle_path for ' + p
    assert 'redir ' + p.rstrip('/') + ' ' + p + ' 308' in cf, 'no redirect for ' + p
    assert 'href=\\\"' + p + '\\\"' in open('$tmp/std/portal/index.html').read(), 'page lacks link ' + p
\""
Q=$tmp/std/caddy.container
check "unit: rootless-safe hardening" "grep -q '^ReadOnly=true' $Q && grep -q '^NoNewPrivileges=true' $Q && grep -q '^DropCapability=ALL' $Q"
check "unit: joins the gateway network" "grep -q '^Network=gateway.network' $Q"
check "unit: Caddyfile mounted read-only as a directory" "grep -q ':/etc/caddy:ro' $Q"
check "unit: no secrets or env files" "! grep -qiE 'secret|password|token|EnvironmentFile' $Q"
check "unit: wanted by default.target (user systemd)" "grep -q 'WantedBy=default.target' $Q"

echo "2b. PostgreSQL platform: rendered units (ADR 0005, 0006)"
P=$tmp/std/postgres.container
N=$tmp/std/db.network
H=$tmp/std/pg_hba.conf
check "postgres unit: no PublishPort (reachable only from the db network)" "[ -s $P ] && ! grep -qi 'PublishPort' $P"
check "postgres unit: joins the db network" "grep -q '^Network=db.network' $P"
check "db.network: NetworkName=db with a fixed subnet" "grep -q '^NetworkName=db\$' $N && grep -qE '^Subnet=[0-9.]+/[0-9]+\$' $N"
check "postgres unit: image pinned to an exact tag, not latest" "grep -qE '^Image=.*postgres:[0-9]+\\.[0-9]+(-[a-z]+)?\$' $P && ! grep -qiE 'latest|postgres:[0-9]+\$' $P"
check "postgres unit: mount guard (mountpoint check, retries, no start limit)" "grep -q '^ExecStartPre=/usr/bin/mountpoint -q /u01\$' $P && grep -q '^Restart=always' $P && grep -q '^StartLimitIntervalSec=0' $P"
check "postgres unit: host data path is under /u01/data" "grep -qE '^Volume=/u01/data/postgres:/var/lib/postgresql/data\$' $P"
check "postgres unit: PGDATA is a sub-folder of the mounted volume" "grep -q '^Environment=PGDATA=/var/lib/postgresql/data/[a-z]' $P"
check "postgres unit: password only via Secret= (mount), file path only in Environment" "grep -q '^Secret=postgres-superuser-password,type=mount' $P && grep -q '^Environment=POSTGRES_PASSWORD_FILE=/run/secrets/' $P && ! grep -qE '^Environment=POSTGRES_PASSWORD=' $P"
check "postgres unit: no password text anywhere in the rendered files (comments aside)" "! (grep -hvE '^#|^Secret=postgres-superuser-password,type=mount|^Environment=POSTGRES_PASSWORD_FILE=/run/secrets/postgres-superuser-password\$' $P $N $H | sed -e 's/password_encryption//g' | grep -qiE 'password|passwd|secret|token|trust')"
check "postgres unit: hardening (read-only root, no new privileges, no capabilities)" "grep -q '^ReadOnly=true' $P && grep -q '^NoNewPrivileges=true' $P && grep -q '^DropCapability=ALL' $P && ! grep -q '^AddCapability' $P"
check "postgres unit: durability stays on (fsync, synchronous_commit, full_page_writes)" "grep -q 'fsync=on' $P && grep -q 'synchronous_commit=on' $P && grep -q 'full_page_writes=on' $P && ! grep -qE '(fsync|synchronous_commit|full_page_writes)=off' $P"
check "postgres unit: memory and pid limits, health check, stop timeout" "grep -q -- '--memory=' $P && grep -q -- '--pids-limit=' $P && grep -q '^HealthCmd=pg_isready' $P && grep -q '^StopTimeout=' $P && grep -q '^TimeoutStopSec=' $P"
check "postgres unit: runs as the image's postgres user mapped to the service user" "grep -q '^UserNS=keep-id:uid=999,gid=999' $P && grep -q '^User=999:999' $P"
check "pg_hba.conf: scram-sha-256 only from the db subnet, no trust, no catch-all" "grep -qE '^host +all +all +10\\.89\\.100\\.0/24 +scram-sha-256' $H && ! grep -qiE '(trust|md5|password) *\$' $H && ! grep -qE '0\\.0\\.0\\.0/0|::/0|[[:space:]]all[[:space:]]+(trust|md5)' $H"
check "pg_hba.conf subnet equals the db.network subnet" "[ \"\$(sed -n 's/^Subnet=//p' $N)\" = \"\$(awk '/^host/{print \$4}' $H)\" ]"
check "the deployed unit does not weaken the guard on Caddy (caddy unit unchanged: no mountpoint check)" "! grep -q mountpoint $Q"
check "pg-create-app: contains no DROP or DELETE statements" "! grep -vE '^[[:space:]]*#' ansible/pg-create-app.yml | grep -qiE 'drop (database|role|user|table)|delete from|state: absent|rm -r|--delete'"
check "pg-create-app: validates the app name and never sets a password on an existing role" "grep -q 'is match(' ansible/pg-create-app.yml && ! grep -qiE 'ALTER (ROLE|USER)' ansible/pg-create-app.yml"
check "pg-create-app and postgres-deploy: secret tasks use no_log" "[ \"\$(grep -c 'no_log: true' ansible/pg-create-app.yml)\" -ge 2 ] && [ \"\$(grep -c 'no_log: true' ansible/postgres-deploy.yml)\" -ge 1 ]"
check "postgres-deploy checks that /u01 is a mount point before writing" "grep -q 'mountpoint -q' ansible/postgres-deploy.yml"
check "pg-create-app makes the role a non-superuser, revokes PUBLIC connect" "grep -q 'NOSUPERUSER' ansible/pg-create-app.yml && grep -q 'REVOKE ALL ON DATABASE' ansible/pg-create-app.yml"
check "pg-create-app also closes the postgres maintenance database to PUBLIC" "grep -q 'REVOKE ALL ON DATABASE postgres FROM PUBLIC' ansible/pg-create-app.yml"
check "quadlet-dryrun script sends the postgres and db units too" "grep -q 'postgres.container' scripts/quadlet-dryrun.sh && grep -q 'db.network' scripts/quadlet-dryrun.sh"

echo "2b-2. Backup units (rendered), then the backup tools and the disk health job run for real"
D=$tmp/std
check "dump service: mount guard, runs the installed script, retention numbers from group_vars" "grep -q '^ExecStartPre=/usr/bin/mountpoint -q /u01\$' $D/pg-dump.service && grep -q '^ExecStart=%h/cornil-platform/bin/pg-dump.sh' $D/pg-dump.service && grep -q '^Environment=KEEP_DAILY=14\$' $D/pg-dump.service && grep -q '^Environment=KEEP_MONTHLY=12\$' $D/pg-dump.service && grep -q '^Environment=BACKUP_ROOT=/u01/data/backups/postgres\$' $D/pg-dump.service"
check "dump timer: Persistent=true and a random delay" "grep -q '^Persistent=true' $D/pg-dump.timer && grep -q '^RandomizedDelaySec=' $D/pg-dump.timer && grep -q '^OnCalendar=' $D/pg-dump.timer"
check "restic service: password only by Podman secret name, repository from a variable, no credential text" "grep -q -- '--secret restic-repo-password,type=mount' $D/restic-backup.service && grep -q 'RESTIC_PASSWORD_FILE=/run/secrets/restic-repo-password' $D/restic-backup.service && ! grep -E '^[^#]*(RESTIC_PASSWORD=|--password|AWS_SECRET_ACCESS_KEY=[A-Za-z0-9])' $D/restic-backup.service"
check "restic service: every backed-up folder is mounted read-only, under /u01/data, nothing from the eMMC" "[ \"\$(grep -c -- '-v /u01/data/.*:ro' $D/restic-backup.service)\" = 3 ] && ! grep -E -- '-v (/home|%h)[^ ]*:/backup' $D/restic-backup.service"
check "restic service: mount guard, hardening, prune retention from group_vars" "grep -q '^ExecStartPre=/usr/bin/mountpoint -q /u01\$' $D/restic-backup.service && grep -q -- '--cap-drop=all' $D/restic-backup.service && grep -q -- '--security-opt=no-new-privileges' $D/restic-backup.service && grep -q -- 'forget --host cornil --tag cornil --prune --keep-daily 7 --keep-weekly 5 --keep-monthly 12' $D/restic-backup.service"
check "restic image is pinned to an exact version" "grep -Eq -- 'restic/restic:[0-9]+\\.[0-9]+\\.[0-9]+( |\$)' $D/restic-backup.service && ! grep -q 'latest' $D/restic-backup.service"
check "restic: no repository address or credential is tracked (placeholder only)" "grep -q '^restic_repository: CHANGE-ME' ansible/group_vars/all.yml && ! git ls-files -z | xargs -0 grep -lE 'sftp:[a-z]+@[0-9]|s3:https://[a-z0-9.-]+/[a-z]' 2>/dev/null | grep -v -e 'local/vars.example.yml' -e 'docs/' -e 'scripts/test' | grep ."
check "disk health units: timer is daily; long self-test is off by default" "grep -q '^OnCalendar=' $D/disk-health.timer && grep -q '^disk_smart_long_test: false' ansible/group_vars/all.yml"
check "disk health bootstrap says it needs sudo and adds no group to the service user" "head -3 ansible/bootstrap-disk-health.yml | grep -qi sudo && ! grep -vE '^[[:space:]]*#' ansible/bootstrap-disk-health.yml | grep -qiE 'ansible.builtin.user|usermod|sudoers|append: *true|groups:'"
bash scripts/test-pgtools.sh "$D" || fail=1

echo "3. Caddy runs the rendered Caddyfile (real Caddy, stand-in apps)"
if ! command -v caddy >/dev/null; then
  echo "  SKIP  caddy not installed locally (brew install caddy). Behaviour tests NOT run."; fail=1
else
  render "$tmp/trial" -e gateway_http_port=18080 -e gateway_https_port=18443 \
         -e tax_upstream=127.0.0.1:18882 -e partsdb_upstream=127.0.0.1:18881 \
         -e gateway_portal_dir=$tmp/trial/portal
  check "caddy validate (rendered Caddyfile)" "caddy validate --config $tmp/trial/Caddyfile --adapter caddyfile"
  python3 -I scripts/echo_server.py 18881 parts-db & python3 -I scripts/echo_server.py 18882 tax &
  XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/conf caddy run --config $tmp/trial/Caddyfile --adapter caddyfile >"$tmp/caddy.log" 2>&1 &
  for i in $(seq 1 40); do [ -s "$tmp/data/caddy/pki/authorities/local/root.crt" ] && curl -s -o /dev/null http://127.0.0.1:18080/ && break; sleep 0.5; done
  cert=$tmp/data/caddy/pki/authorities/local/root.crt
  c() { curl -s --cacert "$cert" --resolve cornil.fritz.box:18443:127.0.0.1 "$@"; }
  U=https://cornil.fritz.box:18443
  check "/ answers 200 text/html over HTTPS with the internal CA" "[ \"\$(c -o /dev/null -w '%{http_code} %{content_type}' $U/)\" = '200 text/html; charset=utf-8' ]"
  check "/ is the portal page with links to both apps" "c $U/ | grep -q '<title>Cornil</title>' && c $U/ | grep -q 'href=\"/parts-db/\"' && c $U/ | grep -q 'href=\"/tax-healthcare/\"'"
  check "/ carries the security headers" "h=\$(c -I $U/ | tr -d '\\r' | tr 'A-Z' 'a-z'); echo \"\$h\" | grep -q '^x-content-type-options: nosniff' && echo \"\$h\" | grep -q '^referrer-policy: no-referrer' && echo \"\$h\" | grep -q '^content-security-policy: default-src .none.'"
  check "/index.html is not a second way in (404)" "[ \"\$(c -o /dev/null -w '%{http_code}' $U/index.html)\" = 404 ]"
  check "an unknown path /nope is 404, not the portal" "[ \"\$(c -o /dev/null -w '%{http_code}' $U/nope)\" = 404 ]"
  check "/parts-db -> 308 /parts-db/" "[ \"\$(c -o /dev/null -w '%{http_code} %{redirect_url}' $U/parts-db)\" = '308 $U/parts-db/' ]"
  check "/tax-healthcare -> 308 /tax-healthcare/" "[ \"\$(c -o /dev/null -w '%{http_code}' $U/tax-healthcare)\" = 308 ]"
  check "/tax-healthcare/x/ reaches the tax stand-in with the prefix stripped" "c $U/tax-healthcare/accounts/login/ | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[\"app\"]==\"tax\" and d[\"path\"]==\"/accounts/login/\"'"
  check "/parts-db/x reaches the parts-db stand-in with the prefix stripped" "c $U/parts-db/parts/ | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[\"app\"]==\"parts-db\" and d[\"path\"]==\"/parts/\"'"
  check "app sees Host cornil.fritz.box and X-Forwarded-Proto https" "c $U/tax-healthcare/ | python3 -I -c 'import json,sys; h=json.load(sys.stdin)[\"headers\"]; assert h[\"Host\"].startswith(\"cornil.fritz.box\") and h[\"X-Forwarded-Proto\"]==\"https\"'"
  check "parts-db stand-in also sees Host cornil.fritz.box and X-Forwarded-Proto https" "c $U/parts-db/ | python3 -I -c 'import json,sys; h=json.load(sys.stdin)[\"headers\"]; assert h[\"Host\"].startswith(\"cornil.fritz.box\") and h[\"X-Forwarded-Proto\"]==\"https\"'"
  check "plain HTTP redirects to HTTPS" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/ -H 'Host: cornil.fritz.box')\" = 308 ]"
  check "no Strict-Transport-Security header (HSTS stays off)" "! c -I $U/ | grep -qi strict-transport"
  check "reload accepts the same file (what make deploy does)" "XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/conf caddy reload --config $tmp/trial/Caddyfile --adapter caddyfile"
  check "a broken Caddyfile is rejected by validate" "! (printf 'cornil.fritz.box {\n  reverse_proxy\n  bogus_directive\n}\n' > $tmp/bad && caddy validate --config $tmp/bad --adapter caddyfile)"
fi

echo "4. No sudo outside the labelled one-time steps"
routine="deploy status backup-caddy-data restore-drill root-cert smoke check test render pg-deploy pg-deploy-check pg-status pg-create-app pg-backup-deploy pg-backup-now pg-restore-drill pg-restore restic-deploy restic-secret disk-status"
for t in $routine; do
  out=$(make -n "$t" 2>&1)
  if echo "$out" | grep -qE '(^|[[:space:]])(sudo|-K|--ask-become-pass|-b)([[:space:]]|$)|become'; then bad "make $t must not use sudo"; else ok "make $t uses no sudo"; fi
done
for p in deploy backup-caddy-data restore-caddy-data status root-cert render postgres-deploy postgres-status pg-create-app pg-backup-deploy pg-backup-now pg-restore-drill pg-restore restic-deploy disk-status; do
  check "$p.yml has no become/sudo" "! grep -vE '^[[:space:]]*#' ansible/$p.yml | grep -qE 'become|sudo'"
done
for p in bootstrap-ports cutover rollback-legacy bootstrap-disk-health; do
  check "$p.yml says it needs sudo in its header" "head -4 ansible/$p.yml | grep -qi 'sudo'"
done

echo "5. Secrets and ownership"
check "no private key material tracked" "! git ls-files | xargs grep -lE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' 2>/dev/null | grep -v '^scripts/test.sh$' | grep ."
check "Caddy configuration lives only in ansible/templates" "[ -z \"\$(git ls-files | grep -iE '(^|/)Caddyfile' | grep -v '^ansible/templates/Caddyfile.j2$')\" ]"

[ "$fail" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
