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
for p in deploy backup-caddy-data status root-cert bootstrap-ports cutover rollback-legacy render; do
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
Q=$tmp/std/caddy.container
check "unit: rootless-safe hardening" "grep -q '^ReadOnly=true' $Q && grep -q '^NoNewPrivileges=true' $Q && grep -q '^DropCapability=ALL' $Q"
check "unit: joins the gateway network" "grep -q '^Network=gateway.network' $Q"
check "unit: Caddyfile mounted read-only as a directory" "grep -q ':/etc/caddy:ro' $Q"
check "unit: no secrets or env files" "! grep -qiE 'secret|password|token|EnvironmentFile' $Q"
check "unit: wanted by default.target (user systemd)" "grep -q 'WantedBy=default.target' $Q"

echo "3. Caddy runs the rendered Caddyfile (real Caddy, stand-in apps)"
if ! command -v caddy >/dev/null; then
  echo "  SKIP  caddy not installed locally (brew install caddy). Behaviour tests NOT run."; fail=1
else
  render "$tmp/trial" -e gateway_http_port=18080 -e gateway_https_port=18443 \
         -e tax_upstream=127.0.0.1:18882 -e partsdb_upstream=127.0.0.1:18881
  check "caddy validate (rendered Caddyfile)" "caddy validate --config $tmp/trial/Caddyfile --adapter caddyfile"
  python3 -I scripts/echo_server.py 18881 parts-db & python3 -I scripts/echo_server.py 18882 tax &
  XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/conf caddy run --config $tmp/trial/Caddyfile --adapter caddyfile >"$tmp/caddy.log" 2>&1 &
  for i in $(seq 1 40); do [ -s "$tmp/data/caddy/pki/authorities/local/root.crt" ] && curl -s -o /dev/null http://127.0.0.1:18080/ && break; sleep 0.5; done
  cert=$tmp/data/caddy/pki/authorities/local/root.crt
  c() { curl -s --cacert "$cert" --resolve cornil.fritz.box:18443:127.0.0.1 "$@"; }
  U=https://cornil.fritz.box:18443
  check "/ answers the gateway page over HTTPS with the internal CA" "[ \"\$(c $U/)\" = 'cornil: parts-db and tax-healthcare' ]"
  check "/parts-db -> 308 /parts-db/" "[ \"\$(c -o /dev/null -w '%{http_code} %{redirect_url}' $U/parts-db)\" = '308 $U/parts-db/' ]"
  check "/tax-healthcare -> 308 /tax-healthcare/" "[ \"\$(c -o /dev/null -w '%{http_code}' $U/tax-healthcare)\" = 308 ]"
  check "/tax-healthcare/x/ reaches the tax stand-in with the prefix stripped" "c $U/tax-healthcare/accounts/login/ | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[\"app\"]==\"tax\" and d[\"path\"]==\"/accounts/login/\"'"
  check "/parts-db/x reaches the parts-db stand-in with the prefix stripped" "c $U/parts-db/parts/ | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[\"app\"]==\"parts-db\" and d[\"path\"]==\"/parts/\"'"
  check "app sees Host cornil.fritz.box and X-Forwarded-Proto https" "c $U/tax-healthcare/ | python3 -I -c 'import json,sys; h=json.load(sys.stdin)[\"headers\"]; assert h[\"Host\"].startswith(\"cornil.fritz.box\") and h[\"X-Forwarded-Proto\"]==\"https\"'"
  check "plain HTTP redirects to HTTPS" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/ -H 'Host: cornil.fritz.box')\" = 308 ]"
  check "no Strict-Transport-Security header (HSTS stays off)" "! c -I $U/ | grep -qi strict-transport"
  check "reload accepts the same file (what make deploy does)" "XDG_DATA_HOME=$tmp/data XDG_CONFIG_HOME=$tmp/conf caddy reload --config $tmp/trial/Caddyfile --adapter caddyfile"
  check "a broken Caddyfile is rejected by validate" "! (printf 'cornil.fritz.box {\n  reverse_proxy\n  bogus_directive\n}\n' > $tmp/bad && caddy validate --config $tmp/bad --adapter caddyfile)"
fi

echo "4. No sudo outside the labelled one-time steps"
routine="deploy status backup-caddy-data root-cert smoke check test render"
for t in $routine; do
  out=$(make -n "$t" 2>&1)
  if echo "$out" | grep -qE '(^|[[:space:]])(sudo|-K|--ask-become-pass|-b)([[:space:]]|$)|become'; then bad "make $t must not use sudo"; else ok "make $t uses no sudo"; fi
done
for p in deploy backup-caddy-data status root-cert render; do
  check "$p.yml has no become/sudo" "! grep -vE '^[[:space:]]*#' ansible/$p.yml | grep -qE 'become|sudo'"
done
for p in bootstrap-ports cutover rollback-legacy; do
  check "$p.yml says it needs sudo in its header" "head -4 ansible/$p.yml | grep -qi 'sudo'"
done

echo "5. Secrets and ownership"
check "no private key material tracked" "! git ls-files | xargs grep -lE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' 2>/dev/null | grep -v '^scripts/test.sh$' | grep ."
check "Caddy configuration lives only in ansible/templates" "[ -z \"\$(git ls-files | grep -iE '(^|/)Caddyfile' | grep -v '^ansible/templates/Caddyfile.j2$')\" ]"

[ "$fail" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
