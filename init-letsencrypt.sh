#!/bin/bash
# ===========================================
# Clenzy - Initialisation Let's Encrypt
# ===========================================
# Ce script genere les certificats SSL via Let's Encrypt (Certbot)
# A executer UNE SEULE FOIS lors du premier deploiement en production
#
# Prerequis :
#   - Les domaines doivent pointer vers l'IP du serveur (DNS A records)
#   - Le port 80 doit etre accessible depuis Internet
#   - Le fichier .env doit etre configure avec les domaines

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Charger les variables d'environnement
if [ ! -f ".env" ]; then
    echo "Erreur : fichier .env introuvable"
    echo "Copier .env.example en .env et configurer les domaines"
    exit 1
fi

source .env

# Domaines a certifier
DOMAINS="${DOMAIN:-clenzy.fr}"
APP_DOM="${APP_DOMAIN:-app.clenzy.fr}"
AUTH_DOM="${AUTH_DOMAIN:-auth.clenzy.fr}"
MONITORING_DOM="${MONITORING_DOMAIN:-monitoring.clenzy.fr}"
PROMETHEUS_DOM="${PROMETHEUS_DOMAIN:-prometheus.clenzy.fr}"
KAFKA_UI_DOM="${KAFKA_UI_DOMAIN:-kafka.clenzy.fr}"
SITE_DOM="${SITE_DOMAIN:-}"

# Liste des domaines du certificat, construite dynamiquement.
#
# Let's Encrypt valide TOUT OU RIEN : un seul domaine qui ne resout pas fait
# echouer la demande entiere, et les six autres vhosts restent sans certificat.
# Le site marketing (SITE_DOMAIN) n'est donc ajoute que s'il est reellement
# configure et distinct du domaine principal — nginx le sert sous le meme
# CERTBOT_CERT_NAME, mais il reste facultatif. Sans cette garde, le defaut du
# compose (baitly.ma) partait dans la demande et la faisait echouer.
CERT_DOMAINS="-d ${DOMAINS} -d www.${DOMAINS} -d ${APP_DOM} -d ${AUTH_DOM} -d ${MONITORING_DOM} -d ${PROMETHEUS_DOM} -d ${KAFKA_UI_DOM}"
if [ -n "$SITE_DOM" ] && [ "$SITE_DOM" != "$DOMAINS" ]; then
  CERT_DOMAINS="$CERT_DOMAINS -d ${SITE_DOM} -d www.${SITE_DOM}"
fi
CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-${DOMAINS}}"

# Email pour les notifications Let's Encrypt (expiration, etc.)
EMAIL="${LETSENCRYPT_EMAIL:-admin@${DOMAINS}}"

echo "=== Initialisation Let's Encrypt ==="
echo ""
echo "Domaines : $(printf '%s' "${CERT_DOMAINS}" | sed 's/-d //g')"
echo "Cert Name: ${CERTBOT_CERT_NAME}"
echo "Email    : ${EMAIL}"
echo ""

# Etape 1 : Creer un certificat auto-signe temporaire
# Nginx a besoin d'un certificat pour demarrer, meme invalide
echo "[1/4] Creation d'un certificat temporaire..."

# Le repertoire doit exister DANS LE VOLUME, pas sur l'hote : le compose monte
# le volume nomme `certbot-certs` sur /etc/letsencrypt, pas un bind mount. Un
# mkdir cote hote ne l'atteint donc jamais, et openssl echouait sur
# « Can't open .../privkey.pem for writing » — invisible tant que le volume
# avait deja servi, revele au premier demarrage d'une nouvelle instance.
docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  mkdir -p /etc/letsencrypt/live/${CERTBOT_CERT_NAME}" certbot

docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout '/etc/letsencrypt/live/${CERTBOT_CERT_NAME}/privkey.pem' \
    -out '/etc/letsencrypt/live/${CERTBOT_CERT_NAME}/fullchain.pem' \
    -subj '/CN=localhost'" certbot

echo ""

# Etape 2 : Demarrer Nginx avec le certificat temporaire
echo "[2/4] Demarrage de Nginx..."

docker compose -f docker-compose.prod.yml --env-file .env up -d nginx
sleep 5

echo ""

# Etape 3 : Supprimer le certificat temporaire et demander le vrai
echo "[3/4] Demande des certificats Let's Encrypt..."

docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  rm -rf /etc/letsencrypt/live/${CERTBOT_CERT_NAME} && \
  rm -rf /etc/letsencrypt/archive/${CERTBOT_CERT_NAME} && \
  rm -rf /etc/letsencrypt/renewal/${CERTBOT_CERT_NAME}.conf" certbot

docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    --email ${EMAIL} \
    --cert-name ${CERTBOT_CERT_NAME} \
    ${CERT_DOMAINS} \
    --rsa-key-size 4096 \
    --agree-tos \
    --no-eff-email \
    --force-renewal" certbot

echo ""

# Etape 4 : Recharger Nginx avec les vrais certificats
echo "[4/4] Rechargement de Nginx avec les certificats Let's Encrypt..."

docker compose -f docker-compose.prod.yml --env-file .env exec nginx nginx -s reload

echo ""
echo "=== Certificats Let's Encrypt installes avec succes ! ==="
echo ""
echo "Les certificats seront renouveles automatiquement par le service certbot."
echo "Vous pouvez maintenant lancer tous les services : ./start-prod.sh"
