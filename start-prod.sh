#!/bin/bash
# ===========================================
# Clenzy - Démarrage environnement PRODUCTION
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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
if [ ! -f "nginx/ssl/clenzy.com.crt" ] || [ ! -f "nginx/ssl/clenzy.com.key" ]; then
    echo "⚠️  Certificats SSL introuvables dans nginx/ssl/"
    echo "   Placez vos certificats :"
    echo "   - nginx/ssl/clenzy.com.crt"
    echo "   - nginx/ssl/clenzy.com.key"
    echo ""
    read -p "Continuer sans SSL ? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
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

# Démarrage en mode détaché
echo "🐳 Build et démarrage des conteneurs (détaché)..."
docker compose -f docker-compose.prod.yml --env-file .env up --build -d

echo ""
echo "✅ Clenzy démarré en production !"
echo ""
echo "📊 Services :"
echo "   - Landing   : https://clenzy.com"
echo "   - PMS       : https://app.clenzy.com"
echo "   - API       : https://app.clenzy.com/api"
echo "   - Auth      : https://auth.clenzy.com"
echo ""
echo "📋 Commandes utiles :"
echo "   - Logs      : docker compose -f docker-compose.prod.yml logs -f"
echo "   - Stop      : docker compose -f docker-compose.prod.yml down"
echo "   - Status    : docker compose -f docker-compose.prod.yml ps"
