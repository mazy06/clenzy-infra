#!/usr/bin/env bash
# Baitly: configure only the staging analytics destination from GitHub environment variables.
set -euo pipefail

# Production is deliberately untouched, including a variable configured at repository level.
[ "${DEPLOY_EXPECTED_DOMAIN:-}" = app.clenzy.fr ] || exit 0
[ -n "${DEPLOY_POSTHOG_KEY:-}${DEPLOY_SENTRY_WEB_DSN:-}${DEPLOY_SENTRY_API_DSN:-}" ] || exit 0
[ "${APP_DOMAIN:-}" = app.clenzy.fr ] || { echo 'Telemetry target mismatch' >&2; exit 1; }
[[ "${DEPLOY_POSTHOG_KEY:-}" =~ ^phc_[A-Za-z0-9_]{20,128}$ ]] || {
  echo 'Invalid PostHog public project key' >&2; exit 1;
}
# Only EU Sentry ingestion DSNs, never arbitrary URLs or shell expressions.
for dsn in "${DEPLOY_SENTRY_WEB_DSN:-}" "${DEPLOY_SENTRY_API_DSN:-}"; do
  if [ -n "$dsn" ] && ! [[ "$dsn" =~ ^https://[a-f0-9]+@o4512297046048768\.ingest\.de\.sentry\.io/[0-9]+$ ]]; then
    echo 'Invalid staging Sentry ingestion DSN' >&2; exit 1
  fi
done
[ -f .env ] && [ ! -L .env ] || { echo 'Regular deployment environment file required' >&2; exit 1; }

umask 077
temporary="$(mktemp .env.telemetry.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
awk '!/^(VITE_ENV|VITE_POSTHOG_KEY|VITE_POSTHOG_HOST)=/' .env > "$temporary"
printf 'VITE_ENV=staging\nVITE_POSTHOG_KEY=%s\nVITE_POSTHOG_HOST=https://eu.i.posthog.com\n' \
  "$DEPLOY_POSTHOG_KEY" >> "$temporary"
if [ -n "${DEPLOY_SENTRY_WEB_DSN:-}" ] && [ -n "${DEPLOY_SENTRY_API_DSN:-}" ]; then
  filtered="$(mktemp .env.telemetry.XXXXXX)"
  awk '!/^(VITE_SENTRY_DSN|SENTRY_DSN|SENTRY_ENVIRONMENT)=/' "$temporary" > "$filtered"
  cat "$filtered" > "$temporary"
  rm -f "$filtered"
  printf 'VITE_SENTRY_DSN=%s\nSENTRY_DSN=%s\nSENTRY_ENVIRONMENT=staging\n' \
    "$DEPLOY_SENTRY_WEB_DSN" "$DEPLOY_SENTRY_API_DSN" >> "$temporary"
fi
chmod 600 "$temporary"
mv "$temporary" .env
echo 'Baitly staging telemetry configured (EU ingestion; public key not logged)'
