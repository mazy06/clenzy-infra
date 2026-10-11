#!/bin/sh
# Carte Baitly · prépare le moteur de rendu d'images (baitly-maps-renderer, tileserver-gl).
#
# Lancé à chaque déploiement par le service baitly-maps-renderer-init, AVANT le moteur :
#   1. télécharge le paquet de rendu (styles, sprites, épingles, glyphes) publié dans le
#      conteneur OVH PUBLIC des cartes par clenzy/scripts/maps/upload-baitly-tiles.sh ;
#   2. écrit la configuration tileserver-gl, qui lit l'archive PMTiles directement dans ce
#      même conteneur (requêtes Range) — rien de lourd n'est copié sur le serveur.
#
# Variable : BAITLY_MAPS_ORIGIN (ex. https://baitly-cartes.s3.gra.io.cloud.ovh.net/maps).
# Paquet indisponible : on garde celui du déploiement précédent s'il existe (le volume
# persiste), sinon échec explicite — le moteur ne démarre pas sans style.
set -eu

ORIGIN="${BAITLY_MAPS_ORIGIN%/}"
case "$ORIGIN" in https://*) ;; *) echo "[maps-renderer] BAITLY_MAPS_ORIGIN doit commencer par https://" >&2; exit 1 ;; esac

DATA=/data
TMP="$(mktemp -d)"
if wget -q -O "$TMP/bundle.tar.gz" "$ORIGIN/render-bundle.tar.gz"; then
  rm -rf "$DATA/styles" "$DATA/icons" "$DATA/fonts"
  tar -xzf "$TMP/bundle.tar.gz" -C "$DATA"
  echo "[maps-renderer] paquet de rendu installé depuis $ORIGIN"
elif [ -d "$DATA/styles" ]; then
  echo "[maps-renderer] paquet injoignable : conservation du paquet précédent" >&2
else
  echo "[maps-renderer] paquet injoignable et aucun paquet précédent : arrêt" >&2
  exit 1
fi
rm -rf "$TMP"

cat > "$DATA/config.json" <<JSON
{
  "options": {
    "paths": { "root": "$DATA", "fonts": "fonts", "styles": "styles", "icons": "icons" },
    "serveAllFonts": false,
    "serveStaticMaps": true,
    "maxScaleFactor": 2,
    "maxSize": 1200,
    "allowRemoteMarkerIcons": false
  },
  "styles": {
    "baitly-paper-fr": { "style": "baitly-paper-fr.json", "serve_data": false },
    "baitly-paper-en": { "style": "baitly-paper-en.json", "serve_data": false },
    "baitly-paper-ar": { "style": "baitly-paper-ar.json", "serve_data": false }
  },
  "data": {
    "baitly": { "pmtiles": "$ORIGIN/baitly.pmtiles" },
    "terrain": { "pmtiles": "$ORIGIN/terrain.pmtiles" }
  }
}
JSON
echo "[maps-renderer] configuration écrite"
