#!/bin/bash
# ===========================================
# Synchronise les redirect URIs du client Keycloak clenzy-web
# avec le domaine de production (APP_DOMAIN).
# Ce script est exécuté sur le VPS via le workflow keycloak-sync.yml
# ou manuellement.
# ===========================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.prod.yml"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Fichier $ENV_FILE introuvable"
    exit 1
fi

# Charger les variables d'environnement
set -a
. ./"$ENV_FILE"
set +a

echo "🔗 Synchronisation des redirect URIs du client clenzy-web..."

# Authenticate kcadm.sh
echo "   Authentification admin..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T keycloak \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "${KEYCLOAK_ADMIN}" \
    --password "${KEYCLOAK_ADMIN_PASSWORD}" || { echo "❌ Authentification admin échouée"; exit 1; }

# Get client internal UUID
echo "   Recherche du client clenzy-web..."
KC_WEB_ID=$(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T keycloak \
  /opt/keycloak/bin/kcadm.sh get clients -r clenzy --fields id,clientId \
  | grep -B1 '"clenzy-web"' | grep '"id"' | head -1 | sed 's/.*: *"//;s/".*//' || true)

if [ -z "$KC_WEB_ID" ]; then
    echo "❌ Client clenzy-web non trouvé dans le realm clenzy"
    exit 1
fi

echo "   Client clenzy-web trouvé (id: ${KC_WEB_ID})"

# Update redirect URIs
echo "   Mise à jour des redirectUris et webOrigins..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T keycloak \
  /opt/keycloak/bin/kcadm.sh update "clients/${KC_WEB_ID}" -r clenzy \
    -s "redirectUris=[\"http://localhost:3000/*\",\"http://localhost:3001/*\",\"https://${APP_DOMAIN}/*\"]" \
    -s "webOrigins=[\"http://localhost:3000\",\"http://localhost:3001\",\"https://${APP_DOMAIN}\"]"

echo "✅ Redirect URIs synchronisées pour clenzy-web"
echo "   - http://localhost:3000/*"
echo "   - http://localhost:3001/*"
echo "   - https://${APP_DOMAIN}/*"
