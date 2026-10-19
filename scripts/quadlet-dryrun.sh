#!/bin/sh
# Asks the server's own Quadlet generator what systemd units it would make from our rendered files.
# Dry run: it only prints. The files go to a temporary folder that is removed afterwards. No sudo.
# Run with: make quadlet-dryrun   (needs the inventory in local/)
set -eu
host=$(awk '/^\[gateway\]/{f=1;next} /^\[/{f=0} f&&$1!~/^#/&&NF{for(i=1;i<=NF;i++){if($i~/^ansible_host=/)h=substr($i,14); if($i~/^ansible_user=/)u=substr($i,14)} print u"@"h; exit}' local/inventory.ini)
make render >/dev/null
d=$(ssh "$host" mktemp -d)
trap 'ssh "$host" rm -rf "$d"' EXIT
scp -q build/caddy.container build/gateway.network "$host:$d/"
ssh "$host" "QUADLET_UNIT_DIRS=$d /usr/libexec/podman/quadlet -dryrun -user"
