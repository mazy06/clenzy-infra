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

# Arrêter les services existants proprement
echo "🛑 Arrêt des services existants..."
docker compose -f docker-compose.dev.yml --env-file .env.dev down --remove-orphans 2>/dev/null || true

# Forcer le rebuild du frontend sans cache (pour toujours inclure les derniers changements)
echo "🧹 Reconstruction du frontend (sans cache)..."
docker compose -f docker-compose.dev.yml --env-file .env.dev build --no-cache pms-client

# Démarrage de tous les services
echo "🐳 Démarrage des conteneurs..."
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d

# Attendre que les services soient prêts
echo "⏳ Attente du démarrage des services..."
sleep 10

# Vérifier le statut des services
echo ""
echo "📊 Statut des services :"
docker compose -f docker-compose.dev.yml --env-file .env.dev ps

echo ""
echo "✅ Environnement de développement démarré !"
echo "🌐 Landing Page : http://localhost:8080"
echo "🌐 PMS Frontend : http://localhost:3000"
echo "🔧 PMS API      : http://localhost:8084"
echo "🗄️  PostgreSQL   : localhost:5433"
echo "🔑 Redis        : localhost:6379"
echo "🔐 Keycloak     : http://localhost:8086"
echo ""
echo "🛑 Pour arrêter : ./stop.sh"
echo ""
echo "💡 Pour voir les logs en temps réel :"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-client"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-server"
