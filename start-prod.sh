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

# Vérification des certificats SSL
if [ ! -f "nginx/ssl/clenzy.fr.crt" ] || [ ! -f "nginx/ssl/clenzy.fr.key" ]; then
    echo "⚠️  Certificats SSL introuvables dans nginx/ssl/"
    echo "   Placez vos certificats :"
    echo "   - nginx/ssl/clenzy.fr.crt"
    echo "   - nginx/ssl/clenzy.fr.key"
    echo ""
    read -p "Continuer sans SSL ? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
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
