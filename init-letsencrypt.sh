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

# Email pour les notifications Let's Encrypt (expiration, etc.)
EMAIL="${LETSENCRYPT_EMAIL:-admin@${DOMAINS}}"

echo "=== Initialisation Let's Encrypt ==="
echo ""
echo "Domaines : ${DOMAINS}, www.${DOMAINS}, ${APP_DOM}, ${AUTH_DOM}"
echo "Email    : ${EMAIL}"
echo ""

# Etape 1 : Creer un certificat auto-signe temporaire
# Nginx a besoin d'un certificat pour demarrer, meme invalide
echo "[1/4] Creation d'un certificat temporaire..."

mkdir -p "$SCRIPT_DIR/certbot/conf/live/${DOMAINS}"

docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout '/etc/letsencrypt/live/${DOMAINS}/privkey.pem' \
    -out '/etc/letsencrypt/live/${DOMAINS}/fullchain.pem' \
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
  rm -rf /etc/letsencrypt/live/${DOMAINS} && \
  rm -rf /etc/letsencrypt/archive/${DOMAINS} && \
  rm -rf /etc/letsencrypt/renewal/${DOMAINS}.conf" certbot

docker compose -f docker-compose.prod.yml --env-file .env run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    --email ${EMAIL} \
    -d ${DOMAINS} \
    -d www.${DOMAINS} \
    -d ${APP_DOM} \
    -d ${AUTH_DOM} \
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
