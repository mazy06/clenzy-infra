#!/bin/bash
# ============================================================
# Nettoyage des proprietes et/ou reservations + dependances
# ============================================================
# Usage:
#   ./clean-properties-reservations.sh                 # mode interactif (defaut: reservations)
#   ./clean-properties-reservations.sh reservations    # nettoie reservations + lies
#   ./clean-properties-reservations.sh properties      # nettoie proprietes + lies (= tout reset)
#   ./clean-properties-reservations.sh all             # equivalent a 'properties'
#
# Variables d'environnement:
#   DB_CONTAINER  (defaut: clenzy-postgres-dev)
#   DB_USER       (defaut: clenzy)
#   DB_NAME       (defaut: clenzy_dev)
#   FORCE         (defaut: 0)  → si 1, skip la confirmation interactive
# ============================================================

set -euo pipefail

# ───────── Config ─────────
CONTAINER="${DB_CONTAINER:-clenzy-postgres-dev}"
DB_USER="${DB_USER:-clenzy}"
DB_NAME="${DB_NAME:-clenzy_dev}"
MODE="${1:-reservations}"
FORCE="${FORCE:-0}"

# ───────── Couleurs ─────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ───────── Validation ─────────
case "$MODE" in
  reservations|properties|all) ;;
  *)
    echo -e "${RED}❌ Mode invalide : $MODE${NC}"
    echo "Modes valides : reservations | properties | all"
    exit 1
    ;;
esac

# ───────── Affichage du contexte ─────────
echo -e "${BLUE}=========================================="
echo -e "  Nettoyage DB Clenzy"
echo -e "==========================================${NC}"
echo -e "  Container : ${YELLOW}${CONTAINER}${NC}"
echo -e "  Database  : ${YELLOW}${DB_NAME}${NC}"
echo -e "  User      : ${YELLOW}${DB_USER}${NC}"
echo -e "  Mode      : ${YELLOW}${MODE}${NC}"
echo ""

# ───────── Compteurs avant ─────────
echo -e "${BLUE}📊 Etat avant nettoyage :${NC}"
docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
  SELECT 'properties: ' || count(*) FROM properties UNION ALL
  SELECT 'reservations: ' || count(*) FROM reservations UNION ALL
  SELECT 'service_requests: ' || count(*) FROM service_requests UNION ALL
  SELECT 'interventions: ' || count(*) FROM interventions UNION ALL
  SELECT 'calendar_days: ' || count(*) FROM calendar_days UNION ALL
  SELECT 'ical_feeds: ' || count(*) FROM ical_feeds UNION ALL
  SELECT 'property_photos: ' || count(*) FROM property_photos
" | sed 's/^/  /'
echo ""

# ───────── Confirmation ─────────
if [ "$FORCE" != "1" ]; then
  case "$MODE" in
    reservations)
      echo -e "${YELLOW}⚠️  Va supprimer : reservations + tout ce qui en depend${NC}"
      echo "    (calendar_days reservation_id, service_requests, interventions,"
      echo "     conversations, guest_message_log, online_checkins, etc.)"
      echo "    Les proprietes et leurs photos seront PRESERVEES."
      ;;
    properties|all)
      echo -e "${RED}⚠️  RESET COMPLET : va supprimer TOUTES les proprietes${NC}"
      echo "    + reservations + service_requests + interventions"
      echo "    + ical_feeds + photos + calendar_days + tous les liens"
      echo "    Les utilisateurs, organisations et settings sont PRESERVES."
      ;;
  esac
  echo ""
  read -p "Confirmer ? (tape 'yes' pour continuer) : " confirm
  if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Annule.${NC}"
    exit 0
  fi
fi

echo ""
echo -e "${BLUE}🧹 Nettoyage en cours...${NC}"

# ───────── Execution ─────────
case "$MODE" in
  reservations)
    docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

-- 1. Detacher les references intervention <-> reservation pour eviter les cycles
UPDATE reservations SET intervention_id = NULL WHERE intervention_id IS NOT NULL;

-- 2. Liberer les calendar_days lies a une reservation
UPDATE calendar_days
   SET status = 'AVAILABLE', reservation_id = NULL, source = 'CLEANUP'
 WHERE reservation_id IS NOT NULL;

-- 3. Annuler les paiements lies aux reservations (avant truncate)
DELETE FROM payment_transactions
 WHERE source_type IN ('RESERVATION', 'SERVICE_REQUEST', 'INTERVENTION');

-- 4. Truncate des tables qui dependent des reservations
TRUNCATE TABLE
  reservation_service_items,
  online_checkins,
  guest_message_log,
  automation_executions,
  welcome_guide_tokens,
  laundry_quotes
RESTART IDENTITY CASCADE;

-- 5. Truncate interventions et service_requests (ils referencent les reservations)
TRUNCATE TABLE interventions, service_requests RESTART IDENTITY CASCADE;

-- 6. Conversations liees a une reservation
DELETE FROM conversations WHERE reservation_id IS NOT NULL;

-- 7. Truncate reservations
TRUNCATE TABLE reservations RESTART IDENTITY CASCADE;

COMMIT;
SQL
    ;;

  properties|all)
    docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

-- 1. Detacher les references croisees
UPDATE reservations SET intervention_id = NULL WHERE intervention_id IS NOT NULL;

-- 2. Paiements lies (avant truncate des proprietes)
DELETE FROM payment_transactions
 WHERE source_type IN ('RESERVATION', 'SERVICE_REQUEST', 'INTERVENTION', 'PROPERTY');

-- 3. Tables dependantes des reservations
TRUNCATE TABLE
  reservation_service_items,
  online_checkins,
  guest_message_log,
  automation_executions,
  welcome_guide_tokens,
  laundry_quotes
RESTART IDENTITY CASCADE;

-- 4. Conversations
DELETE FROM conversations
 WHERE reservation_id IS NOT NULL OR property_id IS NOT NULL;

-- 5. Tables operationnelles
TRUNCATE TABLE interventions, service_requests RESTART IDENTITY CASCADE;

-- 6. Tables dependantes des proprietes
TRUNCATE TABLE
  reservations,
  calendar_days,
  ical_feeds,
  property_photos,
  property_inventory_items,
  property_laundry_items,
  property_teams,
  rate_overrides,
  rate_plans,
  yield_rules,
  occupancy_pricing,
  length_of_stay_discounts,
  channel_rate_modifiers,
  airbnb_listing_mappings,
  booking_restrictions,
  check_in_instructions,
  noise_alert_configs,
  noise_alerts,
  noise_devices,
  smart_lock_devices,
  key_exchange_points,
  manager_properties,
  provider_expenses,
  welcome_guides
RESTART IDENTITY CASCADE;

-- 7. Truncate proprietes (ON DELETE CASCADE devrait gerer le reste)
TRUNCATE TABLE properties RESTART IDENTITY CASCADE;

COMMIT;
SQL
    ;;
esac

# ───────── Compteurs apres ─────────
echo ""
echo -e "${GREEN}✅ Nettoyage termine.${NC}"
echo ""
echo -e "${BLUE}📊 Etat apres nettoyage :${NC}"
docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
  SELECT 'properties: ' || count(*) FROM properties UNION ALL
  SELECT 'reservations: ' || count(*) FROM reservations UNION ALL
  SELECT 'service_requests: ' || count(*) FROM service_requests UNION ALL
  SELECT 'interventions: ' || count(*) FROM interventions UNION ALL
  SELECT 'calendar_days: ' || count(*) FROM calendar_days UNION ALL
  SELECT 'ical_feeds: ' || count(*) FROM ical_feeds UNION ALL
  SELECT 'property_photos: ' || count(*) FROM property_photos
" | sed 's/^/  /'
echo ""
