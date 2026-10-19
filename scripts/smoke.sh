#!/bin/sh
# Smoke test through the gateway, using the root certificate. Run with: make smoke
# Checks: the gateway answers, each app path redirects to or serves its page, and HTTP redirects to HTTPS.
set -u
HOST="${HOST:-cornil.fritz.box}"
PORT="${HTTPS_PORT:-443}"
HTTP_PORT="${HTTP_PORT:-80}"
CERT="${CERT:-local/cornil-root.crt}"
[ -s "$CERT" ] || { echo "Missing $CERT: run 'make root-cert' first." >&2; exit 2; }
base="https://$HOST"; [ "$PORT" = 443 ] || base="$base:$PORT"
fail=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

req() { curl -sS --max-time 10 --cacert "$CERT" -o "${TMPDIR:-/tmp}"/smoke.$$ -w '%{http_code} %{redirect_url}' "$@" 2>&1; }

echo "Gateway at $base"
out=$(req "$base/"); code=${out%% *}
if [ "$code" = 200 ] && grep -q "parts-db and tax-healthcare" "${TMPDIR:-/tmp}"/smoke.$$; then ok "/ answers 200 with the gateway page (certificate trusted)"; else bad "/ -> $out"; fi

out=$(req "$base/parts-db"); code=${out%% *}
[ "$code" = 308 ] && ok "/parts-db redirects (308) to /parts-db/" || bad "/parts-db -> $out"
out=$(req "$base/tax-healthcare"); code=${out%% *}
[ "$code" = 308 ] && ok "/tax-healthcare redirects (308) to /tax-healthcare/" || bad "/tax-healthcare -> $out"

out=$(req "$base/tax-healthcare/"); code=${out%% *}
case "$out" in
  200*|30[1237]*login*) ok "/tax-healthcare/ -> $out" ;;
  *) bad "/tax-healthcare/ expected its login page or a redirect to it -> $out" ;;
esac

out=$(req "$base/parts-db/"); code=${out%% *}
case "$code" in
  2*|3*) ok "/parts-db/ reaches parts-db -> $out"
         case "$out" in *"/parts-db/"*) ;; *) echo "        note: parts-db does not yet add the /parts-db prefix to its own redirects (Part B)";; esac ;;
  *) bad "/parts-db/ -> $out" ;;
esac

if [ "$HTTP_PORT" != "-" ]; then
  out=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' "http://$HOST:$HTTP_PORT/" 2>&1)
  case "$out" in 30[1278]*https://*) ok "plain HTTP on $HTTP_PORT redirects to HTTPS" ;; *) bad "http://$HOST:$HTTP_PORT/ -> $out" ;; esac
fi
rm -f "${TMPDIR:-/tmp}"/smoke.$$
[ "$fail" = 0 ] && echo "SMOKE OK" || { echo "SMOKE FAILED"; exit 1; }
