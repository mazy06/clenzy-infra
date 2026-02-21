#!/bin/bash
# ===========================================
# PostgreSQL Primary - Streaming Replication Setup
# ===========================================
# Niveau 8 — Scalabilite : configure le primary pour accepter
# les connexions de streaming replication du replica.
#
# Ce script s'execute uniquement au premier demarrage (initdb).
# Il configure les parametres WAL necessaires pour la replication.

set -e

echo "==> Configuring PostgreSQL primary for streaming replication..."

# Creer le role de replication (si pas deja existant)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${POSTGRES_REPLICATION_PASSWORD:-${POSTGRES_PASSWORD}}';
            RAISE NOTICE 'Role replicator cree';
        END IF;
    END
    \$\$;
EOSQL

echo "==> Streaming replication configured on primary."
