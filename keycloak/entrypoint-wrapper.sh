#!/bin/bash
# ===========================================
# Keycloak — Entrypoint Wrapper
# ===========================================
# Keycloak 24 ne retente pas les connexions DB.
# Si postgres n'est pas joignable au demarrage, Keycloak crash immediatement.
# Ce wrapper attend que postgres soit accessible en TCP avant de lancer Keycloak.
set -e

DB_HOST="postgres"
DB_PORT="5432"
MAX_WAIT=120
INTERVAL=3

echo "[keycloak-wrapper] Attente de ${DB_HOST}:${DB_PORT}..."
elapsed=0
until echo > /dev/tcp/${DB_HOST}/${DB_PORT} 2>/dev/null; do
  elapsed=$((elapsed + INTERVAL))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "[keycloak-wrapper] ERREUR: ${DB_HOST}:${DB_PORT} inaccessible apres ${MAX_WAIT}s"
    exit 1
  fi
  sleep "$INTERVAL"
done
echo "[keycloak-wrapper] ${DB_HOST}:${DB_PORT} accessible, demarrage de Keycloak..."

exec /opt/keycloak/bin/kc.sh "$@"
