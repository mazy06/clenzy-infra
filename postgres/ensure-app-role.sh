#!/usr/bin/env bash
# ==============================================================================
# Cree / met a jour le role applicatif NON-SUPERUSER utilise par pms-server.
# Audit securite 2026-07-26 — constat P4-03, plan REM-T-02.
# ==============================================================================
#
# POURQUOI
#   L'application, Liquibase, Keycloak, pgbouncer, l'exporter et la replication
#   partagent aujourd'hui le superuser cree par l'image PostgreSQL. Or un
#   superuser contourne la Row-Level Security *meme* posee et FORCEE — c'est
#   demontre par RlsEnforcementIT#superuserBypassesRls_documentsPrerequisite.
#   Activer la RLS sans changer de compte n'apporterait donc aucune protection.
#
# EXECUTION
#   Ce script tourne dans le service one-shot `db-app-role` de docker-compose,
#   a chaque deploiement, APRES que postgres soit healthy et AVANT pms-server.
#   Il ne requiert aucune intervention sur le VPS : tout vient du .env, lui-meme
#   recharge depuis les secrets GitHub.
#
#   Il n'est volontairement PAS place dans /docker-entrypoint-initdb.d/ : ces
#   scripts ne s'executent qu'au tout premier init du volume (cf. le commentaire
#   de sync-password.sh), donc jamais sur une base deja en place.
#
# IDEMPOTENT — rejoue sans risque a chaque deploiement : le role est cree s'il
# manque, son mot de passe resynchronise sinon. Aucun privilege n'est accorde ici,
# c'est le role du changeset Liquibase 0362 applique au boot de pms-server.
#
# NO-OP TANT QUE LE SECRET N'EST PAS POSE
#   Sans CLENZY_APP_DB_PASSWORD, le script sort en succes sans rien faire. Le
#   service peut donc etre deploye avant que le secret n'existe, sans rien casser.
#
# NOM DU ROLE
#   Fige a `clenzy_app`, en accord avec le changeset 0362 qui y accorde les
#   privileges. Le rendre configurable ici sans le rendre configurable la-bas
#   creerait une incoherence silencieuse.

set -euo pipefail

APP_ROLE="clenzy_app"

if [ -z "${CLENZY_APP_DB_PASSWORD:-}" ]; then
  echo "→ CLENZY_APP_DB_PASSWORD absent : role applicatif non cree (no-op)."
  echo "  Renseigner ce secret dans le .env pour activer l'etape 1 de REM-T-02."
  exit 0
fi

if [ "${#CLENZY_APP_DB_PASSWORD}" -lt 24 ]; then
  echo "ERREUR : CLENZY_APP_DB_PASSWORD fait moins de 24 caracteres." >&2
  echo "         Ce role porte l'acces aux donnees de tous les tenants." >&2
  exit 1
fi

echo "→ Role applicatif : ${APP_ROLE} (base ${PGDATABASE}, hote ${PGHOST})"

# Le mot de passe transite par une variable d'environnement psql (:'var'), jamais
# par la ligne de commande : il n'apparait donc pas dans la table des processus.
APP_PASSWORD="${CLENZY_APP_DB_PASSWORD}" \
psql -v ON_ERROR_STOP=1 -v app_role="${APP_ROLE}" <<'SQL'
\set app_password `echo "$APP_PASSWORD"`

-- CREATE si le role manque, ALTER sinon : idempotent et rejouable.
SELECT format(
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role')
         THEN 'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L'
         ELSE 'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L'
    END, :'app_role', :'app_password') AS stmt
\gset

-- Le point-virgule est indispensable : sans lui psql concatene avec la requete suivante.
:stmt ;

-- Controle : NOBYPASSRLS et NOSUPERUSER sont la raison d'etre de ce role.
SELECT rolname, rolsuper, rolbypassrls, rolcanlogin
  FROM pg_roles WHERE rolname = :'app_role';
SQL

echo "✓ Role ${APP_ROLE} pret (NOSUPERUSER, NOBYPASSRLS)."
echo "  Les privileges DML sont accordes par le changeset 0362 au boot de pms-server."
