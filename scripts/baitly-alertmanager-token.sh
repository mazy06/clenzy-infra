#!/usr/bin/env bash
# Baitly: publish the credential for prom/alertmanager v0.27.0 (nobody:65534).+# Keep the deployment user as owner and grant only the container group read access.
set -euo pipefail
umask 077
target="${1:-monitoring/alertmanager/ops_token}"
mkdir -p "$(dirname "$target")"
temporary=$(mktemp "${target}.XXXXXX")
trap 'rm -f "$temporary"' EXIT
printf '%s' "${CLENZY_OPS_ALERT_TOKEN:-}" > "$temporary"
if [ "$(id -u)" -eq 0 ]; then
  chgrp 65534 "$temporary"
else
  sudo -n chgrp 65534 "$temporary"
fi
chmod 640 "$temporary"
# Atomic replacement: no truncated credential visible to the receiver.
mv -f "$temporary" "$target"
