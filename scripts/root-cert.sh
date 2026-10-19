#!/bin/sh
# Checks the fetched root certificate is a public certificate (never a key) and prints its fingerprint,
# so you can compare it on each device. Called by `make root-cert`.
set -eu
f="${1:-local/cornil-root.crt}"
[ -s "$f" ] || { echo "No certificate at $f" >&2; exit 1; }
if grep -q "PRIVATE KEY" "$f"; then
    echo "REFUSING: $f contains a private key. Deleting it." >&2
    rm -f "$f"; exit 1
fi
grep -q "BEGIN CERTIFICATE" "$f" || { echo "$f is not a certificate" >&2; exit 1; }
echo "Saved: $f"
openssl x509 -in "$f" -noout -subject -enddate -fingerprint -sha256
echo "Install this file on each device: see docs/trust-root-cert.md"
