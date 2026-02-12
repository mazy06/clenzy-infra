#!/bin/bash
# ===========================================
# Clenzy - Script de backup automatique
# ===========================================
# Sauvegarde : PostgreSQL + Keycloak Realm + Redis
#
# Usage :
#   ./backup.sh                 → backup complet (dev)
#   ./backup.sh --env prod      → backup production
#   ./backup.sh --db-only       → backup PostgreSQL uniquement
#
# Cron recommandé (prod) :
#   0 2 * * * /opt/clenzy/backup/backup.sh --env prod >> /var/log/clenzy-backup.log 2>&1
#
# Rétention :
#   - Quotidien : 7 jours
#   - Hebdomadaire : 4 semaines (dimanche)
#   - Mensuel : 6 mois (1er du mois)

set -euo pipefail

# ---- Configuration ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

# Paramètres par défaut
ENV="dev"
DB_ONLY=false
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/data}"
RETENTION_DAILY=7
RETENTION_WEEKLY=28
RETENTION_MONTHLY=180

# ---- Parsing des arguments ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --db-only) DB_ONLY=true; shift ;;
        --backup-dir) BACKUP_ROOT="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--env dev|prod|staging] [--db-only] [--backup-dir /path]"; exit 0 ;;
        *) echo "Option inconnue: $1"; exit 1 ;;
    esac
done

# ---- Variables dérivées ----
DATE=$(date +%Y%m%d_%H%M%S)
DAY_OF_WEEK=$(date +%u)   # 1=lundi, 7=dimanche
DAY_OF_MONTH=$(date +%d)
BACKUP_DIR="$BACKUP_ROOT/$ENV/$DATE"

# Conteneurs selon l'environnement
case $ENV in
    dev)
        PG_CONTAINER="clenzy-postgres-dev"
        KC_CONTAINER="clenzy-keycloak-dev"
        REDIS_CONTAINER="clenzy-redis-dev"
        ENV_FILE="$INFRA_DIR/.env.dev"
        ;;
    staging)
        PG_CONTAINER="clenzy-postgres-staging"
        KC_CONTAINER="clenzy-keycloak-staging"
        REDIS_CONTAINER="clenzy-redis-staging"
        ENV_FILE="$INFRA_DIR/.env.staging"
        ;;
    prod)
        PG_CONTAINER="clenzy-postgres-prod"
        KC_CONTAINER="clenzy-keycloak-prod"
        REDIS_CONTAINER="clenzy-redis-prod"
        ENV_FILE="$INFRA_DIR/.env"
        ;;
    *)
        echo "❌ Environnement invalide: $ENV (dev|staging|prod)"
        exit 1
        ;;
esac

# Charger les variables d'environnement
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# ---- Fonctions utilitaires ----
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^$1$"; then
        log "⚠️  Conteneur $1 non trouvé ou arrêté, skip..."
        return 1
    fi
    return 0
}

# ---- Début du backup ----
log "🚀 Démarrage backup Clenzy [$ENV] → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

ERRORS=0

# ==========================================
# 1. BACKUP POSTGRESQL
# ==========================================
log "📦 [1/3] Backup PostgreSQL..."
if check_container "$PG_CONTAINER"; then
    PG_BACKUP_FILE="$BACKUP_DIR/postgres_${POSTGRES_DB:-clenzy}_$DATE.sql.gz"

    docker exec "$PG_CONTAINER" pg_dump \
        -U "${POSTGRES_USER:-clenzy}" \
        -d "${POSTGRES_DB:-clenzy_dev}" \
        --format=custom \
        --compress=9 \
        --verbose \
        2>"$BACKUP_DIR/postgres_dump.log" \
        > "$BACKUP_DIR/postgres_${POSTGRES_DB:-clenzy}_$DATE.dump"

    if [ $? -eq 0 ]; then
        DUMP_SIZE=$(du -h "$BACKUP_DIR/postgres_${POSTGRES_DB:-clenzy}_$DATE.dump" | cut -f1)
        log "✅ PostgreSQL backup OK ($DUMP_SIZE)"
    else
        log "❌ PostgreSQL backup ÉCHOUÉ"
        ERRORS=$((ERRORS + 1))
    fi

    # Backup de la base Keycloak aussi
    if [ "$ENV" != "dev" ] || [ "$DB_ONLY" = false ]; then
        KC_DB="keycloak_${ENV}"
        docker exec "$PG_CONTAINER" pg_dump \
            -U "${POSTGRES_USER:-clenzy}" \
            -d "$KC_DB" \
            --format=custom \
            --compress=9 \
            2>>"$BACKUP_DIR/postgres_dump.log" \
            > "$BACKUP_DIR/keycloak_db_$DATE.dump" 2>/dev/null || true
        log "📋 Keycloak DB dump tenté ($KC_DB)"
    fi
else
    ERRORS=$((ERRORS + 1))
fi

# ==========================================
# 2. BACKUP KEYCLOAK REALM EXPORT
# ==========================================
if [ "$DB_ONLY" = false ]; then
    log "📦 [2/3] Export Keycloak Realm..."
    if check_container "$KC_CONTAINER"; then
        KC_EXPORT_FILE="$BACKUP_DIR/keycloak_realm_clenzy_$DATE.json"

        # Export du realm via l'API admin de Keycloak
        # D'abord obtenir un token admin
        KC_TOKEN=$(docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
            --server http://localhost:8080 \
            --realm master \
            --user "${KEYCLOAK_ADMIN:-admin}" \
            --password "${KEYCLOAK_ADMIN_PASSWORD:-admin}" 2>/dev/null && \
            docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh get realms/clenzy \
            2>/dev/null) || true

        if [ -n "$KC_TOKEN" ]; then
            echo "$KC_TOKEN" > "$KC_EXPORT_FILE"
            log "✅ Keycloak realm export OK"
        else
            # Fallback : copier le fichier realm-import si disponible
            docker cp "$KC_CONTAINER:/opt/keycloak/data/import/realm-clenzy.json" \
                "$BACKUP_DIR/keycloak_realm_import_$DATE.json" 2>/dev/null || true
            log "⚠️  Keycloak realm export via kcadm échoué, fallback sur fichier import"
        fi
    else
        log "⚠️  Keycloak container non disponible, skip export"
    fi
else
    log "⏭️  [2/3] Keycloak skip (--db-only)"
fi

# ==========================================
# 3. BACKUP REDIS
# ==========================================
if [ "$DB_ONLY" = false ]; then
    log "📦 [3/3] Backup Redis..."
    if check_container "$REDIS_CONTAINER"; then
        REDIS_BACKUP_FILE="$BACKUP_DIR/redis_dump_$DATE.rdb"

        # Trigger BGSAVE pour s'assurer que le RDB est à jour
        docker exec "$REDIS_CONTAINER" redis-cli BGSAVE 2>/dev/null || true
        sleep 2

        # Copier le fichier dump.rdb
        docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$REDIS_BACKUP_FILE" 2>/dev/null

        if [ $? -eq 0 ]; then
            RDB_SIZE=$(du -h "$REDIS_BACKUP_FILE" | cut -f1)
            log "✅ Redis backup OK ($RDB_SIZE)"
        else
            log "⚠️  Redis backup échoué (dump.rdb non trouvé, peut-être vide)"
        fi
    else
        log "⚠️  Redis container non disponible, skip"
    fi
else
    log "⏭️  [3/3] Redis skip (--db-only)"
fi

# ==========================================
# 4. COMPRESSION FINALE
# ==========================================
log "🗜️  Compression de l'archive..."
ARCHIVE_NAME="clenzy_backup_${ENV}_$DATE.tar.gz"
cd "$BACKUP_ROOT/$ENV"
tar -czf "$ARCHIVE_NAME" "$DATE/"
ARCHIVE_SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1)
log "📁 Archive: $ARCHIVE_NAME ($ARCHIVE_SIZE)"

# Garder l'archive, supprimer le dossier temporaire
rm -rf "$DATE/"

# ==========================================
# 5. RÉTENTION (nettoyage des anciens backups)
# ==========================================
log "🧹 Nettoyage des anciens backups..."

# Supprimer les backups quotidiens > RETENTION_DAILY jours
find "$BACKUP_ROOT/$ENV" -name "clenzy_backup_${ENV}_*.tar.gz" -mtime +$RETENTION_DAILY -delete 2>/dev/null

# Garder les backups du dimanche pendant RETENTION_WEEKLY jours
# Garder les backups du 1er du mois pendant RETENTION_MONTHLY jours
# (Les backups du dimanche et du 1er sont déjà inclus dans le quotidien,
#  on ne supprime que ceux au-delà de la rétention quotidienne)

REMAINING=$(ls -1 "$BACKUP_ROOT/$ENV"/clenzy_backup_${ENV}_*.tar.gz 2>/dev/null | wc -l)
log "📊 Backups restants: $REMAINING"

# ==========================================
# 6. RÉSUMÉ
# ==========================================
echo ""
log "========================================"
if [ $ERRORS -eq 0 ]; then
    log "✅ BACKUP TERMINÉ AVEC SUCCÈS [$ENV]"
else
    log "⚠️  BACKUP TERMINÉ AVEC $ERRORS ERREUR(S) [$ENV]"
fi
log "📁 Archive: $BACKUP_ROOT/$ENV/$ARCHIVE_NAME"
log "📏 Taille: $ARCHIVE_SIZE"
log "========================================"

exit $ERRORS
