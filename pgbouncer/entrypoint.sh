#!/bin/sh
# ===========================================
# PgBouncer Entrypoint
# ===========================================
# Genere le fichier userlist.txt a partir des variables d'environnement
# puis demarre pgbouncer.
#
# Mots de passe en CLAIR (pas de hash md5) : PostgreSQL 15 stocke les
# credentials en SCRAM-SHA-256, et pgbouncer ne peut repondre au challenge
# SCRAM du serveur qu'avec le mot de passe en clair (ou un verifier SCRAM,
# impossible a deriver d'un hash md5). Le fichier est en chmod 600 dans le
# container — meme niveau d'exposition que la variable d'environnement.

set -e

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

echo "==> Generating pgbouncer userlist..."

cat > "$USERLIST_FILE" <<EOF
"${POSTGRES_USER}" "${POSTGRES_PASSWORD}"
"pgbouncer_admin" "${POSTGRES_PASSWORD}"
"pgbouncer_stats" "${POSTGRES_PASSWORD}"
EOF

chmod 600 "$USERLIST_FILE"
echo "==> userlist.txt generated for user: ${POSTGRES_USER}"

# Demarrer pgbouncer
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
