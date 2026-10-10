#!/usr/bin/env bash
# Baitly : conserver les images de chaque service entre deux déploiements partiels.
baitly_prepare_deployment_images() {
  local expected_ref default_tag tag_file=.env.baitly-images key value service tag
  case "${DEPLOY_EXPECTED_DOMAIN:-${APP_DOMAIN:-}}" in
    app.clenzy.fr) expected_ref=main; default_tag=main ;;
    app.baitly.fr) expected_ref=production; default_tag=latest ;;
    *) echo 'Domaine de déploiement inconnu'; return 1 ;;
  esac
  [ "${APP_DOMAIN:-}" = "${DEPLOY_EXPECTED_DOMAIN:-$APP_DOMAIN}" ] || return 1
  DEPLOY_APP_REF="${DEPLOY_APP_REF:-$expected_ref}"
  [ "$DEPLOY_APP_REF" = "$expected_ref" ] || return 1
  export DEPLOY_APP_REF
  PMS_CLIENT_IMAGE_TAG=$default_tag
  PMS_SERVER_IMAGE_TAG=$default_tag
  BAITLY_SITE_IMAGE_TAG=$default_tag
  if [ -f "$tag_file" ]; then
    while IFS='=' read -r key value; do
      case "$key" in PMS_CLIENT_IMAGE_TAG|PMS_SERVER_IMAGE_TAG|BAITLY_SITE_IMAGE_TAG) ;;
        *) echo 'Clé image inconnue'; return 1 ;;
      esac
      [[ "$value" =~ ^(main|latest|production|[0-9a-f]{40})$ ]] || return 1
      # Un tag de branche ne doit jamais désigner l'autre environnement.
      if ! [[ "$value" =~ ^[0-9a-f]{40}$ ]]; then
        if [ "$expected_ref" = main ]; then
          [ "$value" = main ] || return 1
        else
          [ "$value" != main ] || return 1
        fi
      fi
      printf -v "$key" '%s' "$value"
    done < "$tag_file"
  fi
  tag="${DEPLOY_IMAGE_TAG:-}"
  if [ -n "$tag" ]; then
    [[ "$tag" =~ ^[0-9a-f]{40}$ ]] || return 1
    # Un SHA applicatif ne remplace que les services produits par ce build.
    [ -n "${DEPLOY_SERVICES:-}" ] || return 1
    local -a services
    IFS=',' read -ra services <<< "$DEPLOY_SERVICES"
    for service in "${services[@]}"; do
      case "$service" in
        pms-client) PMS_CLIENT_IMAGE_TAG=$tag ;;
        pms-server) PMS_SERVER_IMAGE_TAG=$tag ;;
        baitly-site) BAITLY_SITE_IMAGE_TAG=$tag ;;
        *) echo 'Service incompatible avec un SHA applicatif'; return 1 ;;
      esac
    done
  fi
  export PMS_CLIENT_IMAGE_TAG PMS_SERVER_IMAGE_TAG BAITLY_SITE_IMAGE_TAG
  local temporary
  temporary=$(mktemp "${tag_file}.XXXXXX") || return 1
  printf 'PMS_CLIENT_IMAGE_TAG=%s\nPMS_SERVER_IMAGE_TAG=%s\nBAITLY_SITE_IMAGE_TAG=%s\n' \
    "$PMS_CLIENT_IMAGE_TAG" "$PMS_SERVER_IMAGE_TAG" "$BAITLY_SITE_IMAGE_TAG" > "$temporary"
  mv "$temporary" "$tag_file"
}
