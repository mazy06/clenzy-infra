#!/bin/bash
# ===========================================
# Clenzy - Arrêt de tous les services
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🛑 Arrêt de Clenzy..."

# Déterminer quel compose file utiliser
if [ "$1" = "prod" ]; then
    COMPOSE_FILE="docker-compose.prod.yml"
    ENV_FILE=".env"
else
    COMPOSE_FILE="docker-compose.dev.yml"
    ENV_FILE=".env.dev"
fi

echo "   Environnement : ${1:-dev}"

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down "$@"

echo "✅ Tous les services sont arrêtés."
