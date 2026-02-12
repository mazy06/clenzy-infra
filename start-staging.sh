#!/bin/bash
# ===========================================
# Clenzy - Démarrage environnement STAGING
# ===========================================
# Usage: ./start-staging.sh [--build]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_FLAG=""
if [[ "${1:-}" == "--build" ]]; then
    BUILD_FLAG="--build"
fi

echo "🚀 Démarrage Clenzy STAGING..."
echo ""

# Vérifier que le fichier .env.staging existe
if [ ! -f .env.staging ]; then
    echo "❌ Fichier .env.staging introuvable !"
    echo "   Copiez .env.example en .env.staging et adaptez les valeurs."
    exit 1
fi

# Vérifier les mots de passe CHANGE_ME
if grep -q "CHANGE_ME" .env.staging; then
    echo "⚠️  ATTENTION: Des valeurs CHANGE_ME ont été détectées dans .env.staging"
    echo "   Mettez à jour les mots de passe avant de déployer !"
    echo ""
    read -p "Continuer quand même ? (oui/non) : " CONFIRM
    if [ "$CONFIRM" != "oui" ]; then
        echo "❌ Annulé."
        exit 1
    fi
fi

docker compose -f docker-compose.staging.yml --env-file .env.staging up -d $BUILD_FLAG

echo ""
echo "✅ Clenzy STAGING démarré !"
echo ""
echo "📋 Services :"
echo "   Landing    → https://${DOMAIN:-staging.clenzy.fr}"
echo "   PMS App    → https://${APP_DOMAIN:-app.staging.clenzy.fr}"
echo "   Keycloak   → https://${AUTH_DOMAIN:-auth.staging.clenzy.fr}"
echo "   Grafana    → https://${MONITORING_DOMAIN:-monitoring.staging.clenzy.fr}"
echo ""
echo "📊 Status :"
docker compose -f docker-compose.staging.yml ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
