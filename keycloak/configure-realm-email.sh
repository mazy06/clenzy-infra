#!/bin/bash
#
# Configure les COURRIELS envoyes par Keycloak : le relais, et la langue.
#
# POURQUOI CE SCRIPT EXISTE
#
# `realm-clenzy.json` n'est importe que si le royaume n'existe PAS encore
# (--import-realm). Sur un royaume deja cree — c'est-a-dire partout apres la
# premiere installation — y ajouter une section `smtpServer` ne change rien.
# La configuration doit donc passer par l'API d'administration.
#
# CE QUE SON ABSENCE COUTE
#
# Sans SMTP, Keycloak ne peut envoyer AUCUN courriel : ni « mot de passe
# oublie », ni verification d'adresse, ni invitation a definir un mot de passe.
# `executeActionsEmail` repond 500. Un compte cree sans invitation est un compte
# que personne ne peut ouvrir.
#
# LA LANGUE FAIT PARTIE DU PROBLEME : sans internationalisation activee,
# Keycloak ecrit en anglais. « Update Your Account » adresse a un prestataire
# francais qui vient de candidater sur un site francais, c'est un courriel qu'on
# prend pour du spam.
#
# PILOTE PAR L'ENVIRONNEMENT, jamais en dur : en developpement on vise Mailpit,
# en production le vrai relais. Le meme script sert les deux.
#
# IDEMPOTENT : le rejouer reapplique la meme configuration, sans effet de bord.
#
# Usage :
#   ./configure-realm-email.sh [realm ...]   (defaut : clenzy clenzy-guests)
#
# Variables :
#   KEYCLOAK_URL             defaut http://localhost:8086
#   KEYCLOAK_ADMIN           obligatoire
#   KEYCLOAK_ADMIN_PASSWORD  obligatoire
#   SMTP_HOST                defaut clenzy-mailpit   (alias reseau de Mailpit)
#   SMTP_PORT                defaut 1025
#   SMTP_FROM                defaut info@clenzy.fr
#   SMTP_FROM_NAME           defaut Baitly
#   SMTP_USER / SMTP_PASSWORD  facultatifs : si vides, pas d'authentification
#   SMTP_STARTTLS / SMTP_SSL   "true" pour activer (defaut "false")
#   REALM_LOCALES           defaut "fr,en,ar" (langues du produit)
#   REALM_DEFAULT_LOCALE    defaut "fr"

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8086}"
SMTP_HOST="${SMTP_HOST:-clenzy-mailpit}"
SMTP_PORT="${SMTP_PORT:-1025}"
SMTP_FROM="${SMTP_FROM:-info@clenzy.fr}"
SMTP_FROM_NAME="${SMTP_FROM_NAME:-Baitly}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_STARTTLS="${SMTP_STARTTLS:-false}"
SMTP_SSL="${SMTP_SSL:-false}"
REALM_LOCALES="${REALM_LOCALES:-fr,en,ar}"
REALM_DEFAULT_LOCALE="${REALM_DEFAULT_LOCALE:-fr}"

if [ -z "${KEYCLOAK_ADMIN:-}" ] || [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
    echo "KEYCLOAK_ADMIN et KEYCLOAK_ADMIN_PASSWORD sont obligatoires." >&2
    exit 1
fi

REALMS=("$@")
if [ ${#REALMS[@]} -eq 0 ]; then
    REALMS=("clenzy" "clenzy-guests")
fi

echo "Authentification aupres de ${KEYCLOAK_URL}..."
TOKEN=$(curl -sS -X POST \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    echo "Impossible d'obtenir un jeton d'administration." >&2
    exit 1
fi

# `auth` n'est active que si un utilisateur est fourni : Mailpit accepte les
# connexions anonymes, un relais de production non.
if [ -n "$SMTP_USER" ]; then
    AUTH_BLOCK="\"auth\":\"true\",\"user\":\"${SMTP_USER}\",\"password\":\"${SMTP_PASSWORD}\""
else
    AUTH_BLOCK="\"auth\":\"\""
fi

# Les langues sont passees en JSON : "fr,en,ar" devient ["fr","en","ar"].
SUPPORTED=$(printf '"%s",' $(echo "$REALM_LOCALES" | tr ',' ' ') | sed 's/,$//')

PAYLOAD=$(cat <<JSON
{
 "internationalizationEnabled": true,
 "supportedLocales": [${SUPPORTED}],
 "defaultLocale": "${REALM_DEFAULT_LOCALE}",
 "smtpServer":{
  "host":"${SMTP_HOST}",
  "port":"${SMTP_PORT}",
  "from":"${SMTP_FROM}",
  "fromDisplayName":"${SMTP_FROM_NAME}",
  "replyTo":"${SMTP_FROM}",
  "starttls":"${SMTP_STARTTLS}",
  "ssl":"${SMTP_SSL}",
  ${AUTH_BLOCK}
 }
}
JSON
)

STATUS=0
for REALM in "${REALMS[@]}"; do
    printf "  %-16s " "$REALM"
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}")
    if [ "$CODE" = "204" ]; then
        echo "OK (SMTP ${SMTP_HOST}:${SMTP_PORT}, langue ${REALM_DEFAULT_LOCALE})"
    else
        echo "ECHEC (HTTP ${CODE})"
        STATUS=1
    fi
done

exit $STATUS
