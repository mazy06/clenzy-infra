#!/bin/bash
# Fix Liquibase checksum mismatch for changeset 0065
# This resets the stored checksum so Liquibase recalculates it on next startup

echo "Resetting Liquibase checksum for changeset 0065..."
docker exec clenzy-postgres-dev psql -U clenzy -d clenzy_dev -c \
  "UPDATE databasechangelog SET md5sum = NULL WHERE id = '0065-migrate-assigned-to-awaiting-payment';"

if [ $? -eq 0 ]; then
  echo "Done. Restart the server now."
else
  echo "Error: could not connect to clenzy-postgres-dev container."
  exit 1
fi
