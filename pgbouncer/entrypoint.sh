#!/bin/sh
# ===========================================
# PgBouncer Entrypoint
# ===========================================
# Genere le fichier userlist.txt a partir des variables d'environnement
# puis demarre pgbouncer.
#
# Format MD5 PostgreSQL : md5(password + username)

set -e

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

echo "==> Generating pgbouncer userlist..."

# md5(password + username) — format standard PostgreSQL
pg_md5="md5$(echo -n "${POSTGRES_PASSWORD}${POSTGRES_USER}" | md5sum | cut -d' ' -f1)"
admin_md5="md5$(echo -n "${POSTGRES_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)"
stats_md5="md5$(echo -n "${POSTGRES_PASSWORD}pgbouncer_stats" | md5sum | cut -d' ' -f1)"

cat > "$USERLIST_FILE" <<EOF
"${POSTGRES_USER}" "${pg_md5}"
"pgbouncer_admin" "${admin_md5}"
"pgbouncer_stats" "${stats_md5}"
EOF

chmod 600 "$USERLIST_FILE"
echo "==> userlist.txt generated for user: ${POSTGRES_USER}"

# Demarrer pgbouncer
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
