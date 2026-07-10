#!/bin/bash
# ===========================================
# Clenzy - Arrêt de tous les services
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🛑 Arrêt de Clenzy..."

# Déterminer quel compose file utiliser
SITES_FILES=""
if [ "$1" = "prod" ]; then
    COMPOSE_FILE="docker-compose.prod.yml"
    ENV_FILE=".env"
else
    COMPOSE_FILE="docker-compose.dev.yml"
    ENV_FILE=".env.dev"
    # clenzy-sites (SSR) : inclure l'override dev s'il est présent, sinon son container resterait orphelin.
    [ -d "../clenzy-sites" ] && SITES_FILES="-f docker-compose.sites.dev.yml"
fi

echo "   Environnement : ${1:-dev}"

docker compose -f "$COMPOSE_FILE" $SITES_FILES --env-file "$ENV_FILE" down "$@"

echo "✅ Tous les services sont arrêtés."
