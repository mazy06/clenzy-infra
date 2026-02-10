#!/bin/bash
# ===========================================
# Clenzy - Démarrage environnement DEV
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Démarrage de Clenzy en mode DÉVELOPPEMENT..."
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

# Vérification des projets
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

# Démarrage
echo "🐳 Build et démarrage des conteneurs..."
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build "$@"
