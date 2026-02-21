#!/bin/bash
# ===========================================
# PgBouncer Entrypoint
# ===========================================
# Genere le fichier userlist.txt a partir des variables d'environnement
# puis demarre pgbouncer.

set -e

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

echo "==> Generating pgbouncer userlist..."

# Generer le hash MD5 du mot de passe PostgreSQL
PG_MD5=$(echo -n "${POSTGRES_PASSWORD}${POSTGRES_USER}" | md5sum | awk '{print "md5"$1}')

cat > "$USERLIST_FILE" <<EOF
"${POSTGRES_USER}" "${PG_MD5}"
"pgbouncer_admin" "${PG_MD5}"
"pgbouncer_stats" "${PG_MD5}"
EOF

chmod 600 "$USERLIST_FILE"
echo "==> userlist.txt generated for user: ${POSTGRES_USER}"

# Demarrer pgbouncer
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
