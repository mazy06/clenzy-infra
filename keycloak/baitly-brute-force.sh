#!/usr/bin/env bash
# Run through Baitly Keycloak Security CI. Does not restart any container.
set -euo pipefail
MODE="${1:---check}"
case "$MODE" in --check|--apply) ;; *) exit 2 ;; esac
docker compose -f docker-compose.prod.yml --env-file .env exec -T \
  -e BAITLY_SECURITY_MODE="$MODE" keycloak sh -s <<'KEYCLOAK'
set -eu
set +x
CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT
KCADM=/opt/keycloak/bin/kcadm.sh
$KCADM config credentials --config "$CONFIG" --server http://localhost:8080 \
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null
if [ "$BAITLY_SECURITY_MODE" = '--apply' ]; then
  $KCADM update realms/clenzy --config "$CONFIG" \
    -s bruteForceProtected=true -s permanentLockout=false -s failureFactor=10 \
    -s waitIncrementSeconds=60 -s maxFailureWaitSeconds=900 \
    -s quickLoginCheckMilliSeconds=1000 -s minimumQuickLoginWaitSeconds=60 \
    -s maxDeltaTimeSeconds=43200
fi
# Output only these reviewed fields, never realm keys/client credentials/users.
$KCADM get realms/clenzy --config "$CONFIG" \
  --fields bruteForceProtected,permanentLockout,failureFactor,waitIncrementSeconds,maxFailureWaitSeconds,quickLoginCheckMilliSeconds,minimumQuickLoginWaitSeconds,maxDeltaTimeSeconds
KEYCLOAK
