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

# ─── Nettoyage Docker pour éviter ENOSPC (no space left on device) ───────
echo "🧹 Nettoyage Docker (images orphelines, caches build, containers arrêtés)..."
# Supprimer les containers arrêtés, réseaux orphelins, images pendantes et cache build
docker system prune -f 2>/dev/null || true
# Supprimer spécifiquement le cache BuildKit qui grossit à chaque --no-cache
docker builder prune -f 2>/dev/null || true
echo "   ✅ Nettoyage terminé"
echo ""

# Forcer le rebuild du frontend et du backend sans cache (pour toujours inclure les derniers changements)
echo "🔨 Reconstruction du frontend et du backend (sans cache)..."
docker compose -f docker-compose.dev.yml --env-file .env.dev build --no-cache pms-client pms-server

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
echo ""
echo "── Applications ──────────────────────────────"
echo "🌐 Landing Page  : http://localhost:8080"
echo "🌐 PMS Frontend  : http://localhost:3000"
echo "🔧 PMS API       : http://localhost:8084"
echo ""
echo "── Infrastructure ────────────────────────────"
echo "🗄️  PostgreSQL    : localhost:5433"
echo "🔑 Redis         : localhost:6379"
echo "🔐 Keycloak      : http://localhost:8086"
echo "📨 Kafka         : localhost:9092"
echo ""
echo "── Outils dev ────────────────────────────────"
echo "📊 Kafka UI      : http://localhost:8085"
echo "📧 Mailpit       : http://localhost:8025"
echo "📈 Prometheus    : http://localhost:9090"
echo "📉 Grafana       : http://localhost:3001  (admin/admin)"
echo "📋 Loki          : http://localhost:3100"
echo ""
echo "🛑 Pour arrêter : ./stop.sh"
echo ""
echo "💡 Pour voir les logs en temps réel :"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-client"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-server"
