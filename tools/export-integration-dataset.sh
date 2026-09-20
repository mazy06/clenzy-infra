#!/bin/bash
# ============================================================================
# Export du jeu de donnees METIER de la base de dev vers l'integration.
#
# Produit UN fichier SQL, rejouable et reversible, qui AJOUTE les logements,
# voyageurs, reservations, interventions et jours de calendrier du poste de dev
# a la base cible.
#
# ── Ce qu'il ne fait PAS, et pourquoi ──────────────────────────────────────
#
# Il ne supprime rien de l'existant. Trente-huit tables referencent
# `properties` et douze referencent `reservations` : « remplacer » les donnees
# metier ne toucherait pas cinq tables mais une cinquantaine, et echouerait sur
# la premiere contrainte tenue.
#
# Il ne transporte ni utilisateurs, ni organisations, ni factures, ni secrets.
# Les comptes portent un `keycloak_id` du realm de dev : les importer creerait
# des comptes inutilisables et ecraserait potentiellement les vrais. Les lignes
# importees sont rattachees a une organisation et a un proprietaire QUI
# EXISTENT DEJA dans la cible, passes en parametres.
#
# ── Pourquoi un schema de transit ─────────────────────────────────────────
#
# Les identifiants de dev entrent en collision avec ceux de la cible (voyageurs
# et jours de calendrier). Il faut donc les decaler. Le faire par UPDATE APRES
# insertion ne marche pas : les cles etrangeres ne sont pas DEFERRABLE, et
# decaler `properties.id` casserait immediatement les references qui le
# pointent. On charge donc le dump dans un schema de transit SANS contraintes,
# puis on transfere vers les vraies tables en appliquant le decalage dans le
# SELECT, parents d'abord.
#
# ── Reversibilite ─────────────────────────────────────────────────────────
#
# Toutes les lignes importees portent un identifiant >= ID_OFFSET. L'import se
# retire integralement par les DELETE en tete du fichier genere.
#
# Usage :
#   ./tools/export-integration-dataset.sh > seed/integration-dataset.sql
# ============================================================================

set -euo pipefail

SOURCE_CONTAINER="${SOURCE_CONTAINER:-clenzy-postgres-dev}"
SOURCE_DB="${SOURCE_DB:-clenzy_dev}"
SOURCE_USER="${SOURCE_USER:-clenzy}"

# Decalage applique a TOUS les identifiants importes. Au-dessus de n'importe
# quelle plage plausible de la cible, et rond pour se reperer d'un coup d'oeil.
ID_OFFSET="${ID_OFFSET:-100000}"

# Ordre = ordre des dependances. Les parents d'abord.
TABLES="properties guests interventions reservations calendar_days"

# Tableaux associatifs volontairement evites : bash 3.2 (celui de macOS) ne les
# connait pas, et ce script doit tourner sur le poste comme sur un runner.

# Colonnes portant une reference a un autre enregistrement importe : elles
# subissent le MEME decalage que la cle primaire.
fk_shift() {
  case "$1" in
    interventions) echo "property_id" ;;
    reservations)  echo "property_id guest_id intervention_id" ;;
    calendar_days) echo "property_id reservation_id" ;;
    *)             echo "" ;;
  esac
}

# Colonnes liees a l'ENVIRONNEMENT : elles designent des ressources absentes de
# la cible (listing Airbnb, session Stripe, feed iCal, fichier du stockage objet
# de dev). Les transporter laisserait des references mortes, et ferait entrer
# des identifiants de dev dans un systeme expose.
neutralise() {
  case "$1" in
    properties)    echo "airbnb_listing_id airbnb_url" ;;
    guests)        echo "avatar_url" ;;
    interventions) echo "stripe_payment_intent_id stripe_session_id service_request_id before_photos_urls after_photos_urls assigned_user_id" ;;
    reservations)  echo "channex_crs_booking_id external_uid ical_feed_id stripe_customer_id stripe_payment_method_id stripe_session_id booking_voucher_id" ;;
    *)             echo "" ;;
  esac
}

# Colonnes rattachees a la cible plutot que copiees.
remap() {
  case "$1" in
    properties)    echo "organization_id=:org_id owner_id=:owner_id" ;;
    interventions) echo "organization_id=:org_id requestor_id=:owner_id" ;;
    guests|reservations|calendar_days) echo "organization_id=:org_id" ;;
    *)             echo "" ;;
  esac
}

if ! docker ps --format '{{.Names}}' | grep -q "^${SOURCE_CONTAINER}$"; then
  echo "Erreur : le conteneur ${SOURCE_CONTAINER} n'est pas demarre." >&2
  exit 1
fi

psql_src() { docker exec "$SOURCE_CONTAINER" psql -U "$SOURCE_USER" -d "$SOURCE_DB" -tAc "$1"; }
in_list()  { local n="$1"; shift; for x in $*; do [ "$x" = "$n" ] && return 0; done; return 1; }

cat <<HEADER
-- ============================================================================
-- Jeu de donnees metier — dev -> integration
-- Genere le $(date +%Y-%m-%d) par tools/export-integration-dataset.sh
-- NE PAS EDITER A LA MAIN : regenerer.
--
-- AJOUTE (sans rien supprimer) logements, voyageurs, interventions,
-- reservations et jours de calendrier du poste de dev.
--
-- Deux parametres, qui doivent EXISTER dans la cible :
--   psql -v org_id=<organisation d'accueil> -v owner_id=<proprietaire> -f ce_fichier
--
-- Tous les identifiants importes valent >= ${ID_OFFSET} : l'import se retire
-- integralement par les DELETE ci-dessous.
-- ============================================================================

\\set ON_ERROR_STOP on

BEGIN;

-- Parametres materialises : un bloc DO ne voit PAS les variables psql, il lui
-- faut une table.
CREATE TEMP TABLE _import_params ON COMMIT DROP AS
  SELECT (:org_id)::bigint AS org_id, (:owner_id)::bigint AS owner_id;

DO \$\$
DECLARE p record;
BEGIN
  SELECT * INTO p FROM _import_params;
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p.org_id) THEN
    RAISE EXCEPTION 'Organisation % introuvable dans la cible', p.org_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p.owner_id) THEN
    RAISE EXCEPTION 'Utilisateur % introuvable dans la cible', p.owner_id;
  END IF;
END
\$\$;

-- Rejouable : on retire un eventuel import precedent, enfants d'abord.
DELETE FROM calendar_days WHERE id >= ${ID_OFFSET};
DELETE FROM reservations  WHERE id >= ${ID_OFFSET};
DELETE FROM interventions WHERE id >= ${ID_OFFSET};
DELETE FROM guests        WHERE id >= ${ID_OFFSET};
DELETE FROM properties    WHERE id >= ${ID_OFFSET};

-- Schema de transit : copie de structure SANS contraintes ni index, le temps
-- d'appliquer le decalage des identifiants.
DROP SCHEMA IF EXISTS import_stage CASCADE;
CREATE SCHEMA import_stage;
HEADER

for t in $TABLES; do
  echo "CREATE TABLE import_stage.${t} (LIKE public.${t});"
done
echo ""

# ── Donnees brutes, redirigees vers le schema de transit ───────────────────
for t in $TABLES; do
  echo "-- ─── ${t} (transit) ──────────────────────────────────────────────"
  docker exec "$SOURCE_CONTAINER" pg_dump -U "$SOURCE_USER" -d "$SOURCE_DB" \
      --data-only --column-inserts --no-owner --no-privileges -t "$t" \
    | awk '
        # pg_dump --column-inserts emet des INSERT SUR PLUSIEURS LIGNES des
        # une valeur contient un retour a la ligne. Filtrer sur
        # /^INSERT INTO/ jetait les lignes de continuation et laissait une
        # chaine non fermee. On laisse donc passer TOUT ce qui suit le premier
        # INSERT, en ne reecrivant que les lignes qui en ouvrent un.
        !started && /^INSERT INTO public\./ { started = 1 }
        # pg_dump recent encadre sa sortie de meta-commandes psql
        # \\restrict / \\unrestrict. On demarre apres la premiere, il faut
        # donc aussi ecarter la fermante, sinon psql refuse une sortie de mode
        # restreint dans lequel il n est jamais entre.
        /^\\(un)?restrict / { next }
        started {
          if ($0 ~ /^INSERT INTO public\./) sub(/^INSERT INTO public\./, "INSERT INTO import_stage.")
          print
        }'
  echo ""
done

# ── Transfert vers les vraies tables, parents d'abord ──────────────────────
echo "-- ── Transfert avec decalage des identifiants et rattachement ─────────"
for t in $TABLES; do
  cols=$(psql_src "SELECT string_agg(column_name, ' ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}'")
  collist=""; sellist=""
  for c in $cols; do
    [ -n "$collist" ] && { collist="${collist}, "; sellist="${sellist}, "; }
    collist="${collist}${c}"
    remapped=""
    for pair in $(remap "$t"); do
      [ "${pair%%=*}" = "$c" ] && remapped="${pair#*=}"
    done
    if [ "$c" = "id" ]; then
      sellist="${sellist}id + ${ID_OFFSET}"
    elif in_list "$c" "$(fk_shift "$t")"; then
      # NULL reste NULL : une reference absente ne doit pas devenir l'offset.
      sellist="${sellist}${c} + ${ID_OFFSET}"
    elif in_list "$c" "$(neutralise "$t")"; then
      sellist="${sellist}NULL"
    elif [ -n "$remapped" ]; then
      sellist="${sellist}${remapped}"
    else
      sellist="${sellist}${c}"
    fi
  done
  echo "INSERT INTO public.${t} (${collist})"
  echo "SELECT ${sellist} FROM import_stage.${t};"
  echo ""
done

cat <<TAIL
DROP SCHEMA import_stage CASCADE;

-- ── Sequences ─────────────────────────────────────────────────────────────
-- Sans cela, la prochaine creation depuis l'application reutiliserait un
-- identifiant deja pris par l'import.
SELECT setval(pg_get_serial_sequence('properties',    'id'), (SELECT max(id) FROM properties));
SELECT setval(pg_get_serial_sequence('guests',        'id'), (SELECT max(id) FROM guests));
SELECT setval(pg_get_serial_sequence('reservations',  'id'), (SELECT max(id) FROM reservations));
SELECT setval(pg_get_serial_sequence('interventions', 'id'), (SELECT max(id) FROM interventions));
SELECT setval(pg_get_serial_sequence('calendar_days', 'id'), (SELECT max(id) FROM calendar_days));

COMMIT;

\\echo 'Import termine.'
TAIL
