#!/usr/bin/env bash
# ==============================================================================
# Crée le rôle applicatif NON-SUPERUSER utilisé par pms-server.
# Audit sécurité 2026-07-26 — constat P4-03, plan REM-T-02.
# ==============================================================================
#
# POURQUOI
#   L'application, Liquibase, Keycloak, pgbouncer, l'exporter et la réplication
#   partagent aujourd'hui le superuser créé par l'image PostgreSQL. Or un
#   superuser contourne la Row-Level Security *même* posée et FORCÉE — c'est
#   démontré par RlsEnforcementIT#superuserBypassesRls_documentsPrerequisite.
#   Activer la RLS sans changer de compte n'apporterait donc aucune protection.
#
# POURQUOI UN SCRIPT ET PAS UN CHANGESET LIQUIBASE
#   Créer le rôle exige un mot de passe. Le mettre dans un changeset versionné
#   serait un secret en clair dans le dépôt (règle projet n°12). Le changeset
#   0362 accorde les privilèges ; ce script crée le rôle et pose son mot de
#   passe depuis le .env, qui n'est pas versionné.
#
# IDEMPOTENT — peut être rejoué sans risque : le rôle est créé s'il manque, son
# mot de passe est resynchronisé sinon. Aucun privilège n'est accordé ici (c'est
# le rôle du changeset 0362).
#
# USAGE (sur le VPS, depuis clenzy-infra/)
#   set -a; . ./.env; set +a
#   CLENZY_APP_DB_PASSWORD='<secret>' ./postgres/create-app-role.sh
#
# ORDRE DE DÉPLOIEMENT — voir REMEDIATION-PLAN.md, REM-T-02
#   1. Déployer le changeset 0362 (no-op tant que le rôle n'existe pas).
#   2. Exécuter CE script, puis rejouer 0362 (workflow « Liquibase Bootstrap »)
#      pour poser les privilèges.
#   3. Basculer SPRING_DATASOURCE_USERNAME/PASSWORD sur le rôle applicatif, en
#      laissant SPRING_LIQUIBASE_USERNAME sur le compte propriétaire.
#   Ensuite seulement : activer le contexte `rls` puis strict-context.
#
# ROLLBACK
#   Repasser SPRING_DATASOURCE_USERNAME sur le compte d'origine et redéployer.
#   Le rôle peut rester en place : il ne retire rien à personne.

set -euo pipefail

APP_ROLE="${CLENZY_APP_DB_ROLE:-clenzy_app}"
CONTAINER="${POSTGRES_CONTAINER:-clenzy-postgres-prod}"

: "${POSTGRES_USER:?POSTGRES_USER manquant — sourcer le .env avant d'exécuter}"
: "${POSTGRES_DB:?POSTGRES_DB manquant — sourcer le .env avant d'exécuter}"
: "${CLENZY_APP_DB_PASSWORD:?CLENZY_APP_DB_PASSWORD manquant — fournir le mot de passe du rôle applicatif}"

if [ "${#CLENZY_APP_DB_PASSWORD}" -lt 24 ]; then
  echo "ERREUR : CLENZY_APP_DB_PASSWORD fait moins de 24 caractères." >&2
  echo "         Ce rôle porte l'accès aux données de tous les tenants." >&2
  exit 1
fi

echo "→ Rôle applicatif : ${APP_ROLE} (base ${POSTGRES_DB}, conteneur ${CONTAINER})"

# Le mot de passe transite par une variable d'environnement psql (:'var'), jamais
# par la ligne de commande : il n'apparaît donc pas dans la table des processus.
docker exec -i \
  -e APP_ROLE="${APP_ROLE}" \
  -e APP_PASSWORD="${CLENZY_APP_DB_PASSWORD}" \
  "${CONTAINER}" \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
       -v app_role="${APP_ROLE}" <<'SQL'
\set app_password `echo "$APP_PASSWORD"`

-- CREATE si le rôle manque, ALTER sinon : idempotent et rejouable.
SELECT format(
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role')
         THEN 'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L'
         ELSE 'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L'
    END, :'app_role', :'app_password') AS stmt
\gset

-- Le point-virgule est indispensable : sans lui psql concatene avec la requete suivante.
:stmt ;

-- Contrôle : NOBYPASSRLS et NOSUPERUSER sont la raison d'être de ce rôle.
SELECT rolname, rolsuper, rolbypassrls, rolcanlogin
  FROM pg_roles WHERE rolname = :'app_role';
SQL

echo "✓ Rôle ${APP_ROLE} prêt (NOSUPERUSER, NOBYPASSRLS)."
echo
echo "Étape suivante : rejouer le changeset 0362 pour accorder les privilèges DML,"
echo "via le workflow « Liquibase Bootstrap » de clenzy-infra."
