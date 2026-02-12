#!/bin/bash
# ===========================================
# Clenzy - Script de restauration
# ===========================================
# Restaure un backup créé par backup.sh
#
# Usage :
#   ./restore.sh --archive backup_file.tar.gz --env dev
#   ./restore.sh --list --env prod          → liste les backups disponibles
#   ./restore.sh --latest --env prod        → restaure le dernier backup
#
# ⚠️  ATTENTION : Ce script ÉCRASE les données existantes !

set -euo pipefail

# ---- Configuration ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/data}"

# Paramètres par défaut
ENV="dev"
ARCHIVE=""
LIST_MODE=false
LATEST_MODE=false
SKIP_CONFIRM=false

# ---- Parsing des arguments ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --list) LIST_MODE=true; shift ;;
        --latest) LATEST_MODE=true; shift ;;
        --yes|-y) SKIP_CONFIRM=true; shift ;;
        --help)
            echo "Usage: $0 --archive <file.tar.gz> --env <dev|staging|prod>"
            echo "       $0 --list --env <env>      → lister les backups"
            echo "       $0 --latest --env <env>     → restaurer le dernier"
            echo "       $0 --yes                    → skip confirmation"
            exit 0
            ;;
        *) echo "Option inconnue: $1"; exit 1 ;;
    esac
done

# ---- Variables dérivées ----
case $ENV in
    dev)
        PG_CONTAINER="clenzy-postgres-dev"
        REDIS_CONTAINER="clenzy-redis-dev"
        ENV_FILE="$INFRA_DIR/.env.dev"
        ;;
    staging)
        PG_CONTAINER="clenzy-postgres-staging"
        REDIS_CONTAINER="clenzy-redis-staging"
        ENV_FILE="$INFRA_DIR/.env.staging"
        ;;
    prod)
        PG_CONTAINER="clenzy-postgres-prod"
        REDIS_CONTAINER="clenzy-redis-prod"
        ENV_FILE="$INFRA_DIR/.env"
        ;;
    *)
        echo "❌ Environnement invalide: $ENV"
        exit 1
        ;;
esac

# Charger les variables
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ---- Mode liste ----
if [ "$LIST_MODE" = true ]; then
    log "📋 Backups disponibles pour [$ENV] :"
    echo ""
    if ls "$BACKUP_ROOT/$ENV"/clenzy_backup_${ENV}_*.tar.gz 1>/dev/null 2>&1; then
        ls -lh "$BACKUP_ROOT/$ENV"/clenzy_backup_${ENV}_*.tar.gz | awk '{print "  " $NF " (" $5 ")"}'
    else
        echo "  (aucun backup trouvé)"
    fi
    exit 0
fi

# ---- Mode latest ----
if [ "$LATEST_MODE" = true ]; then
    ARCHIVE=$(ls -t "$BACKUP_ROOT/$ENV"/clenzy_backup_${ENV}_*.tar.gz 2>/dev/null | head -1)
    if [ -z "$ARCHIVE" ]; then
        log "❌ Aucun backup trouvé pour l'environnement [$ENV]"
        exit 1
    fi
    log "📂 Dernier backup trouvé: $(basename "$ARCHIVE")"
fi

# ---- Validation ----
if [ -z "$ARCHIVE" ]; then
    echo "❌ Spécifiez une archive: --archive <file.tar.gz> ou --latest"
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "❌ Archive introuvable: $ARCHIVE"
    exit 1
fi

# ---- Confirmation ----
if [ "$SKIP_CONFIRM" = false ]; then
    echo ""
    echo "⚠️  =========================================="
    echo "⚠️  RESTAURATION - ENVIRONNEMENT: $ENV"
    echo "⚠️  Archive: $(basename "$ARCHIVE")"
    echo "⚠️  "
    echo "⚠️  Cette opération va ÉCRASER les données"
    echo "⚠️  actuelles de PostgreSQL et Redis !"
    echo "⚠️  =========================================="
    echo ""
    read -p "Confirmer la restauration ? (oui/non) : " CONFIRM
    if [ "$CONFIRM" != "oui" ]; then
        log "❌ Restauration annulée."
        exit 0
    fi
fi

# ---- Extraction ----
log "🚀 Démarrage restauration [$ENV]..."
TEMP_DIR=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

# Trouver le sous-dossier extrait
EXTRACTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)

if [ -z "$EXTRACTED_DIR" ]; then
    log "❌ Structure d'archive invalide"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# ==========================================
# 1. RESTAURATION POSTGRESQL
# ==========================================
PG_DUMP=$(find "$EXTRACTED_DIR" -name "postgres_*.dump" | head -1)
if [ -n "$PG_DUMP" ] && docker ps --format '{{.Names}}' | grep -q "^$PG_CONTAINER$"; then
    log "📦 [1/2] Restauration PostgreSQL..."

    # Copier le dump dans le conteneur
    docker cp "$PG_DUMP" "$PG_CONTAINER:/tmp/restore.dump"

    # Restaurer (drop + create)
    docker exec "$PG_CONTAINER" pg_restore \
        -U "${POSTGRES_USER:-clenzy}" \
        -d "${POSTGRES_DB:-clenzy_dev}" \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        /tmp/restore.dump 2>/dev/null || true

    # Nettoyage
    docker exec "$PG_CONTAINER" rm -f /tmp/restore.dump

    log "✅ PostgreSQL restauré"
else
    log "⚠️  Pas de dump PostgreSQL trouvé ou conteneur arrêté"
fi

# ==========================================
# 2. RESTAURATION REDIS
# ==========================================
REDIS_RDB=$(find "$EXTRACTED_DIR" -name "redis_dump_*.rdb" | head -1)
if [ -n "$REDIS_RDB" ] && docker ps --format '{{.Names}}' | grep -q "^$REDIS_CONTAINER$"; then
    log "📦 [2/2] Restauration Redis..."

    # Arrêter Redis, copier le RDB, redémarrer
    docker exec "$REDIS_CONTAINER" redis-cli SHUTDOWN NOSAVE 2>/dev/null || true
    sleep 2
    docker cp "$REDIS_RDB" "$REDIS_CONTAINER:/data/dump.rdb"
    docker restart "$REDIS_CONTAINER"

    log "✅ Redis restauré"
else
    log "⚠️  Pas de dump Redis trouvé ou conteneur arrêté"
fi

# ---- Nettoyage ----
rm -rf "$TEMP_DIR"

# ---- Résumé ----
echo ""
log "========================================"
log "✅ RESTAURATION TERMINÉE [$ENV]"
log "📁 Archive: $(basename "$ARCHIVE")"
log "========================================"
log ""
log "💡 Redémarrez l'application pour prendre en compte les changements :"
log "   docker compose -f docker-compose.${ENV}.yml restart pms-server"
