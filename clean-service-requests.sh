#!/bin/bash
# ============================================================
# Nettoyage complet : demandes de service, interventions
# et données liées
# ============================================================

set -euo pipefail

CONTAINER="clenzy-postgres-dev"
DB_USER="clenzy"
DB_NAME="clenzy_dev"

echo "=== Nettoyage des demandes de service et interventions ==="
echo ""

docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" \
  -c "UPDATE reservations SET intervention_id = NULL WHERE intervention_id IS NOT NULL;" \
  -c "DELETE FROM payment_transactions WHERE source_type IN ('SERVICE_REQUEST', 'INTERVENTION');" \
  -c "TRUNCATE TABLE interventions CASCADE;" \
  -c "TRUNCATE TABLE service_requests CASCADE;" \
  -c "UPDATE databasechangelog SET md5sum = NULL WHERE id = '0065-migrate-assigned-to-awaiting-payment';" \
  -c "SELECT 'interventions' AS table_name, count(*) AS remaining FROM interventions UNION ALL SELECT 'service_requests', count(*) FROM service_requests ORDER BY table_name;"

echo ""
echo "=== Nettoyage termine ==="
