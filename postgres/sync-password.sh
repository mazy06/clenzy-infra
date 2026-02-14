#!/bin/bash
# ===========================================
# Synchronise le mot de passe de l'utilisateur PostgreSQL
# avec la variable POSTGRES_PASSWORD du .env
# ===========================================
# Ce script s'exécute à chaque démarrage de PostgreSQL
# via /docker-entrypoint-initdb.d/ (premier init uniquement)
# ou via un volume monté exécuté manuellement.
#
# Problème résolu : PostgreSQL stocke le mot de passe au premier
# init dans le volume. Si le .env change ensuite, le mot de passe
# en base ne change pas → les autres services ne peuvent plus
# se connecter.

set -e

if [ -n "$POSTGRES_USER" ] && [ -n "$POSTGRES_PASSWORD" ]; then
    echo "Synchronizing password for user '$POSTGRES_USER'..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        ALTER USER "$POSTGRES_USER" WITH PASSWORD '$POSTGRES_PASSWORD';
EOSQL
    echo "Password synchronized successfully."
fi
