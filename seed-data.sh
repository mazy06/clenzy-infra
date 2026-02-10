#!/bin/bash
# ===========================================
# Clenzy - Seed des donnees initiales
# ===========================================
# Execute les scripts SQL de seed apres que le backend
# ait cree les tables via Hibernate.
#
# Usage: ./seed-data.sh
# Prerequis: les conteneurs doivent etre demarres (./start-dev.sh)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

POSTGRES_CONTAINER="clenzy-postgres-dev"
DB_NAME="clenzy_dev"
DB_USER="clenzy"

echo "=== Seed des donnees Clenzy ==="
echo ""

# Verifier que Postgres est demarre
if ! docker ps --format '{{.Names}}' | grep -q "$POSTGRES_CONTAINER"; then
    echo "Erreur : le conteneur $POSTGRES_CONTAINER n'est pas demarre"
    echo "Lancez d'abord : ./start-dev.sh"
    exit 1
fi

# Verifier que les tables existent (creees par Hibernate)
TABLE_COUNT=$(docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('roles', 'permissions', 'role_permissions');" 2>/dev/null | tr -d ' ')

if [ "$TABLE_COUNT" != "3" ]; then
    echo "Les tables ne sont pas encore creees par le backend."
    echo "Attendez que le backend Spring Boot soit demarre, puis relancez ce script."
    exit 1
fi

# Executer le seed
echo "[1/2] Insertion des roles, permissions et mappings..."
docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f /docker-entrypoint-initdb.d/02-seed-roles-permissions.sql

echo ""
echo "[2/2] Verification..."
echo ""

echo "Roles :"
docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT name, display_name FROM roles ORDER BY id;"

echo "Permissions par module :"
docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT module, COUNT(*) FROM permissions GROUP BY module ORDER BY module;"

echo "Permissions par role :"
docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT r.name, COUNT(rp.id) as nb_permissions FROM roles r LEFT JOIN role_permissions rp ON r.id = rp.role_id GROUP BY r.name ORDER BY r.name;"

# Vider le cache Redis
echo ""
echo "Vidage du cache Redis..."
docker exec clenzy-redis-dev redis-cli FLUSHALL > /dev/null 2>&1 && echo "Cache Redis vide."

echo ""
echo "=== Seed termine avec succes ! ==="
echo "Rechargez la page du PMS pour voir les changements."
