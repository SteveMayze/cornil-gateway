#!/bin/sh
# Creates ONE Podman secret on the server from a value you type at a hidden prompt ON THE SERVER (through ssh).
# The value never appears on a command line, in a file, in shell history or in this repository, and nobody
# else (including Claude) sees it. It refuses to overwrite an existing secret.
# Usage: scripts/restic-secret.sh <secret-name>     (or: make restic-secret NAME=<secret-name>)
set -eu
name=${1:?give the secret name, for example restic-repo-password}
printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]{2,40}$' || { echo "secret names are lower-case letters, digits and - only" >&2; exit 2; }
host=$(awk '/^\[gateway\]/{f=1;next} /^\[/{f=0} f&&$1!~/^#/&&NF{for(i=1;i<=NF;i++){if($i~/^ansible_host=/)h=substr($i,14); if($i~/^ansible_user=/)u=substr($i,14)} print u"@"h; exit}' local/inventory.ini)
echo "You will be asked for the value on the server. Typing is hidden. Keep a copy of it OUTSIDE the server."
ssh -t "$host" "if podman secret exists $name; then echo 'The secret $name already exists. Nothing was changed.'; exit 1; fi; printf 'Value for $name: '; stty -echo; read -r v; stty echo; echo; printf '%s' \"\$v\" | podman secret create $name - >/dev/null && echo 'Secret $name created.'"
