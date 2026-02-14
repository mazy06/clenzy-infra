#!/bin/bash
# ===========================================
# Clenzy - Démarrage environnement PRODUCTION
# ===========================================
# Usage :
#   ./start-prod.sh          # Pull images GHCR + démarrage
#   ./start-prod.sh --build  # Build local (sans GHCR)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD_MODE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "🚀 Démarrage de Clenzy en mode PRODUCTION..."
echo ""

# Vérification des prérequis
if ! command -v docker &> /dev/null; then
    echo "❌ Docker n'est pas installé"
    exit 1
fi

if ! docker info &> /dev/null 2>&1; then
    echo "❌ Docker daemon n'est pas démarré"
    exit 1
fi

# Vérification du fichier .env
if [ ! -f ".env" ]; then
    echo "❌ Fichier .env introuvable"
    echo "   Copier .env.example en .env et configurer les valeurs"
    exit 1
fi

source .env
CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-${DOMAIN:-clenzy.fr}}"

# Vérification des certificats Let's Encrypt (volume Docker)
if ! docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "test -f /etc/letsencrypt/live/${CERTBOT_CERT_NAME}/fullchain.pem -a -f /etc/letsencrypt/live/${CERTBOT_CERT_NAME}/privkey.pem" certbot >/dev/null 2>&1; then
    echo "❌ Certificats Let's Encrypt introuvables pour '${CERTBOT_CERT_NAME}'"
    echo "   Exécuter d'abord : ./init-letsencrypt.sh"
    exit 1
fi

# Vérification des projets (nécessaire uniquement en mode build local)
if [ "$BUILD_MODE" = true ]; then
    if [ ! -d "../clenzy-landingpage" ]; then
        echo "❌ Projet clenzy-landingpage introuvable dans ../clenzy-landingpage"
        exit 1
    fi

    if [ ! -d "../clenzy" ]; then
        echo "❌ Projet clenzy (PMS) introuvable dans ../clenzy"
        exit 1
    fi

    echo "📦 Projets détectés :"
    echo "   - Landing Page : ../clenzy-landingpage"
    echo "   - PMS          : ../clenzy"
    echo ""

    echo "🐳 Build local et démarrage des conteneurs..."
    docker compose -f docker-compose.prod.yml --env-file .env up --build -d
else
    # Mode production : pull des images depuis GHCR
    echo "📦 Pull des images depuis GitHub Container Registry..."

    # Login GHCR si token disponible
    if [ -n "$GHCR_TOKEN" ]; then
        echo "$GHCR_TOKEN" | docker login ghcr.io -u mazy06 --password-stdin 2>/dev/null
    fi

    docker compose -f docker-compose.prod.yml --env-file .env pull 2>/dev/null || true

    echo "🐳 Démarrage des conteneurs..."
    docker compose -f docker-compose.prod.yml --env-file .env up -d
fi

echo ""
echo "✅ Clenzy démarré en production !"
echo ""
echo "📊 Services :"
echo "   - Landing   : https://clenzy.fr"
echo "   - PMS       : https://app.clenzy.fr"
echo "   - API       : https://app.clenzy.fr/api"
echo "   - Auth      : https://auth.clenzy.fr"
echo ""
echo "📋 Commandes utiles :"
echo "   - Logs      : docker compose -f docker-compose.prod.yml logs -f"
echo "   - Stop      : docker compose -f docker-compose.prod.yml down"
echo "   - Status    : docker compose -f docker-compose.prod.yml ps"
echo "   - Deploy    : ./deploy.sh"
echo ""
