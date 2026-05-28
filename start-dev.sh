#!/bin/bash
# ===========================================
# Clenzy - Démarrage environnement DEV
# ===========================================
#
# Usage :
#   ./start-dev.sh                       démarrage normal (cleanup auto si crash détecté)
#   ./start-dev.sh --reset-kafka         force le reset du volume Kafka (data corrompue)
#   ./start-dev.sh --deep-clean          prune agressif (images -a, builder -a) si VM Docker saturée
#   ./start-dev.sh --purge-anon-volumes  vire les volumes anonymes orphelins (SHA-named) avec confirmation interactive
#   ./start-dev.sh --help                affiche cette aide
#
# Note : --purge-anon-volumes demande TOUJOURS confirmation (Docker est partagé
# avec Testcontainers et autres projets — pas d'auto-trigger destructif).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Parsing des options ─────────────────────────────────────────────────
FORCE_RESET_KAFKA=false
DEEP_CLEAN=false
FORCE_PURGE_ANON=false
for arg in "$@"; do
    case "$arg" in
        --reset-kafka)         FORCE_RESET_KAFKA=true ;;
        --deep-clean)          DEEP_CLEAN=true ;;
        --purge-anon-volumes)  FORCE_PURGE_ANON=true ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *)
            echo "❌ Option inconnue : $arg (utilise --help pour la liste)"
            exit 1
            ;;
    esac
done

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

# ─── Détection pré-down : Kafka a-t-il crashé lors de la session précédente ?
# Si oui, son log __cluster_metadata-0 est probablement corrompu (ENOSPC,
# OOM, kill abrupt...). On wipe le volume avant le `up` pour repartir sur un
# cluster sain — aucune donnée critique en dev (events reprocessed par les
# producers Outbox).
RESET_KAFKA_REASON=""
KAFKA_LAST_EXIT=$(docker inspect clenzy-kafka-dev --format '{{.State.ExitCode}}' 2>/dev/null || echo "")
if [ -n "$KAFKA_LAST_EXIT" ] && [ "$KAFKA_LAST_EXIT" != "0" ]; then
    RESET_KAFKA_REASON="exit code $KAFKA_LAST_EXIT lors de la dernière session"
elif [ "$FORCE_RESET_KAFKA" = true ]; then
    RESET_KAFKA_REASON="--reset-kafka demandé manuellement"
fi

# Arrêter les services existants proprement
echo "🛑 Arrêt des services existants..."
docker compose -f docker-compose.dev.yml --env-file .env.dev down --remove-orphans 2>/dev/null || true

# ─── Reset du volume Kafka si crash détecté ──────────────────────────────
if [ -n "$RESET_KAFKA_REASON" ]; then
    echo ""
    echo "⚠️  Reset Kafka : $RESET_KAFKA_REASON"
    docker volume rm clenzy-infra_kafka-data-dev 2>/dev/null \
        && echo "   ✅ Volume kafka-data-dev supprimé (sera recréé à neuf)" \
        || echo "   ℹ️  Volume déjà inexistant ou attaché — sera recréé au `up`"
fi

# ─── Nettoyage Docker pour éviter ENOSPC (no space left on device) ───────
echo ""
echo "🧹 Nettoyage Docker (images orphelines, caches build, containers arrêtés)..."

if [ "$DEEP_CLEAN" = true ]; then
    # Mode agressif : supprime TOUTES les images non utilisées (pas que dangling)
    # + build cache complet. Libère plusieurs Go quand la VM Docker est saturée.
    docker image prune -a -f 2>/dev/null || true
    docker builder prune -a -f 2>/dev/null || true
    docker container prune -f 2>/dev/null || true
else
    # Mode standard : prune sûr (containers stoppés, réseaux orphelins,
    # images dangling, cache build léger). N'efface PAS les images utilisées
    # par d'autres projets ni les volumes nommés.
    docker system prune -f 2>/dev/null || true
    docker builder prune -f 2>/dev/null || true
fi

# ❌ Pas de `docker volume prune` global ici : risquerait de supprimer
#    postgres-data-dev / keycloak-data-dev quand les containers sont stoppés
#    (`down --remove-orphans` les marque "unused" temporairement).
#    Volumes nommés persistent intentionnellement.
echo "   ✅ Nettoyage terminé"

# ─── Purge des volumes anonymes (opt-in via --purge-anon-volumes) ────────
# Les volumes Docker créés sans nom explicite (VOLUME dans Dockerfile,
# Testcontainers, anciens compose runs...) ont un nom hash SHA-256 64 chars hex.
# Le regex ^[0-9a-f]{64}$ ne matche QUE ces volumes anonymes — JAMAIS un volume
# nommé comme `clenzy-infra_postgres-data-dev`.
#
# ⚠️  Docker est partagé entre projets sur ta machine. Confirmation interactive
#    obligatoire avant suppression (peut inclure des volumes Testcontainers
#    ou d'autres compose stacks en cours d'usage ailleurs).
if [ "$FORCE_PURGE_ANON" = true ]; then
    ANON_COUNT=$(docker volume ls -q 2>/dev/null | grep -cE '^[0-9a-f]{64}$' || echo "0")
    if [ "$ANON_COUNT" -gt 0 ]; then
        echo ""
        echo "🗑️  $ANON_COUNT volumes anonymes (SHA-256) détectés sur le démon Docker."
        echo "   ⚠️  Cela peut inclure Testcontainers ou d'autres projets — volumes"
        echo "       nommés (clenzy-infra_*, projet_*) seront PRÉSERVÉS."
        read -r -p "   Confirmer la suppression de $ANON_COUNT volumes anonymes ? [y/N] " ANON_CONFIRM
        if [ "$ANON_CONFIRM" = "y" ] || [ "$ANON_CONFIRM" = "Y" ]; then
            REMOVED=$(docker volume ls -q | grep -E '^[0-9a-f]{64}$' \
                | xargs -r docker volume rm 2>/dev/null | wc -l | tr -d ' ')
            echo "   ✅ $REMOVED volumes anonymes supprimés"
        else
            echo "   ↩️  Purge annulée par l'utilisateur"
        fi
    else
        echo "ℹ️  Aucun volume anonyme à purger"
    fi
fi

# ─── Check espace disponible dans la VM Docker ───────────────────────────
# Avertit si la VM est saturée — peut causer un nouveau crash Kafka/Postgres
# au démarrage. Threshold conservateur : 5 GB de marge minimum.
DOCKER_DF_OUT=$(docker system df 2>/dev/null || echo "")
if [ -n "$DOCKER_DF_OUT" ]; then
    RECLAIMABLE_GB=$(echo "$DOCKER_DF_OUT" | awk '/Local Volumes/ {gsub("GB","",$5); print int($5)}')
    if [ -n "$RECLAIMABLE_GB" ] && [ "$RECLAIMABLE_GB" -gt 10 ]; then
        echo ""
        echo "⚠️  $RECLAIMABLE_GB GB récupérables dans des volumes orphelins."
        echo "   Si tu manques d'espace : Docker Desktop > Settings > Resources"
        echo "   > Disk image size (passe à 96 ou 128 GB), puis Apply & Restart."
    fi
fi
echo ""

# Forcer le rebuild du frontend et du backend sans cache (pour toujours inclure les derniers changements)
echo "🔨 Reconstruction du frontend et du backend (sans cache)..."
docker compose -f docker-compose.dev.yml --env-file .env.dev build --no-cache pms-client pms-server

# ─── Setup OpenWA (WhatsApp self-hosted, profile opt-in) ─────────────────
# Idempotent : clone le repo OpenWA dans ./openwa/ si absent, genere
# OPENWA_API_MASTER_KEY dans .env.dev si placeholder. Skip silencieusement
# si setup-openwa.sh n'existe pas (compatibilite avec anciennes branches).
if [ -x "./scripts/setup-openwa.sh" ]; then
    echo ""
    echo "📱 Setup OpenWA (WhatsApp self-hosted)..."
    if ./scripts/setup-openwa.sh > /tmp/openwa-setup.log 2>&1; then
        echo "   ✓ OpenWA pret (./openwa/ + OPENWA_API_MASTER_KEY)"
    else
        echo "   ⚠️  Setup OpenWA echoue (cf. /tmp/openwa-setup.log) — on continue sans"
        OPENWA_SKIP=1
    fi
fi

# Démarrage de tous les services + profile openwa pour inclure le container
# WhatsApp (sauf si le setup a echoue). Profile docker s'additionne au profile
# default — les autres services demarrent tous comme avant.
echo "🐳 Démarrage des conteneurs..."
if [ "${OPENWA_SKIP:-0}" = "0" ] && [ -d "./openwa" ]; then
    docker compose -f docker-compose.dev.yml --env-file .env.dev --profile openwa up -d
else
    docker compose -f docker-compose.dev.yml --env-file .env.dev up -d
fi

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
if [ "${OPENWA_SKIP:-0}" = "0" ] && [ -d "./openwa" ]; then
    echo "📱 OpenWA        : http://localhost:2785/api/docs  (Swagger + Dashboard QR)"
fi
echo ""
echo "🛑 Pour arrêter : ./stop.sh"
echo ""
echo "💡 Pour voir les logs en temps réel :"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-client"
echo "   docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-server"
