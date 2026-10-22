#!/bin/bash
# ===========================================
# Baitly - Script de backup automatique
# ===========================================
# Sauvegarde : PostgreSQL + Keycloak Realm + Redis
#
# Usage :
#   ./backup.sh                 → backup complet (dev)
#   ./backup.sh --env prod      → backup production
#   ./backup.sh --db-only       → backup PostgreSQL uniquement
#
# Pilote France : objectif RPO 1h / RTO 4h. Aucune planification n'est installee ici.
# La cadence doit couvrir aussi chiffrement et copie hors site, avant qualification.
#
# Rétention :
#   - Quotidien : 7 jours
#   - Hebdomadaire : 4 semaines (dimanche)
#   - Mensuel : 6 mois (1er du mois)

set -euo pipefail
umask 077

# ---- Configuration ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

# Paramètres par défaut
ENV="dev"
DB_ONLY=false
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/data}"

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

case "$BACKUP_ROOT" in /*) ;; *) BACKUP_ROOT="$PWD/$BACKUP_ROOT" ;; esac

# ---- Variables dérivées ----
DATE=$(date +%Y%m%d_%H%M%S)
SNAPSHOT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BACKUP_DIR="$BACKUP_ROOT/$ENV/$DATE"

# Conteneurs selon l'environnement
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
log "🚀 Démarrage backup Baitly [$ENV] → $BACKUP_DIR"
mkdir -p "$BACKUP_ROOT/$ENV"
chmod 700 "$BACKUP_ROOT/$ENV"
# A same-second invocation must not overwrite an earlier snapshot.
mkdir "$BACKUP_DIR"
ARCHIVE_PARTIAL=""
cleanup() {
    rm -rf "$BACKUP_DIR"
    if [ -n "$ARCHIVE_PARTIAL" ]; then rm -f "$ARCHIVE_PARTIAL"; fi
}
trap cleanup EXIT

ERRORS=0

# ==========================================
# 1. BACKUP POSTGRESQL
# ==========================================
log "📦 [1/3] Backup PostgreSQL..."
if check_container "$PG_CONTAINER"; then
    PG_DUMP_FILE="$BACKUP_DIR/postgres_application_$DATE.dump"
    if ! docker exec "$PG_CONTAINER" pg_dump -U "${POSTGRES_USER:-clenzy}" \
        -d "${POSTGRES_DB:-clenzy_dev}" --format=custom --compress=9 \
        >"$PG_DUMP_FILE" 2>"$BACKUP_DIR/postgres_dump.log"; then
        log "PostgreSQL backup échoué ; aucune archive complète ne sera publiée"
        exit 1
    fi
    test -s "$PG_DUMP_FILE"
    docker exec -i "$PG_CONTAINER" pg_restore --list <"$PG_DUMP_FILE" >/dev/null 2>>"$BACKUP_DIR/postgres_dump.log"
    log "PostgreSQL dump vérifié"

    # The complete authentication DB covers both PMS and guest realms, users and keys.
    KC_DB="${KEYCLOAK_DB_NAME:-keycloak_${ENV}}"
    if ! docker exec "$PG_CONTAINER" pg_dump -U "${POSTGRES_USER:-clenzy}" \
        -d "$KC_DB" --format=custom --compress=9 \
        >"$BACKUP_DIR/keycloak_db_$DATE.dump" 2>>"$BACKUP_DIR/postgres_dump.log"; then
        log "Base authentification non sauvegardée ; aucune archive complète ne sera publiée"
        exit 1
    fi
    test -s "$BACKUP_DIR/keycloak_db_$DATE.dump"
    docker exec -i "$PG_CONTAINER" pg_restore --list <"$BACKUP_DIR/keycloak_db_$DATE.dump" >/dev/null 2>>"$BACKUP_DIR/postgres_dump.log"
    log "Base authentification vérifiée"
else
    exit 1
fi

# ==========================================
# 2. AUTHENTIFICATION
# ==========================================
# No kcadm login/export: it persists admin credentials and realm metadata alone
# does not restore users, guest realms or signing keys. The DB dump above is required.
log "Authentification incluse dans le dump complet de sa base"

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
python3 "$SCRIPT_DIR/baitly_archive.py" create "$BACKUP_DIR" --environment "$ENV" --snapshot-started-at "$SNAPSHOT_STARTED_AT"
log "🗜️  Compression de l'archive..."
ARCHIVE_NAME="clenzy_backup_${ENV}_$DATE.tar.gz"
cd "$BACKUP_ROOT/$ENV"
ARCHIVE_PARTIAL=$(mktemp "$BACKUP_ROOT/$ENV/.baitly-archive.XXXXXX")
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE_PARTIAL" "$DATE/"
python3 "$SCRIPT_DIR/baitly_archive.py" verify "$ARCHIVE_PARTIAL"
# Hard link publishes atomically and refuses to replace an existing archive.
ln "$ARCHIVE_PARTIAL" "$ARCHIVE_NAME"
rm -f "$ARCHIVE_PARTIAL"
ARCHIVE_PARTIAL=""
ARCHIVE_SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1)
log "📁 Archive: $ARCHIVE_NAME ($ARCHIVE_SIZE)"

# Garder l'archive, supprimer le dossier temporaire
rm -rf "$DATE/"

# ==========================================
# 5. RÉTENTION (nettoyage des anciens backups)
# ==========================================
log "🧹 Nettoyage des anciens backups..."

# Classify each archive by its original snapshot date; monthly/weekly retention
# must not be defeated by deleting every file older than seven days first.
python3 "$SCRIPT_DIR/baitly_archive.py" retention "$BACKUP_ROOT/$ENV" --environment "$ENV" --apply

REMAINING=$(ls -1 "$BACKUP_ROOT/$ENV"/clenzy_backup_${ENV}_*.tar.gz 2>/dev/null | wc -l)
log "📊 Backups restants: $REMAINING"

# ==========================================
# 6. RÉSUMÉ
# ==========================================
echo ""
log "========================================"
if [ $ERRORS -eq 0 ]; then
    log "Sauvegarde locale des bases vérifiée [$ENV] ; documents, chiffrement et copie hors site restent à qualifier"
else
    log "⚠️  BACKUP TERMINÉ AVEC $ERRORS ERREUR(S) [$ENV]"
fi
log "📁 Archive: $BACKUP_ROOT/$ENV/$ARCHIVE_NAME"
log "📏 Taille: $ARCHIVE_SIZE"
log "========================================"

exit $ERRORS
