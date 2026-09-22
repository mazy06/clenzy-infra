#!/usr/bin/env bash
# Called only by the reviewed deployment workflow; never print credential values.
set -euo pipefail
case "${BAITLY_CAPTCHA_ENABLED:-false}" in
  false) ;;
  true)
    for key in TURNSTILE_SECRET_KEY TURNSTILE_ALLOWED_HOSTNAMES VITE_TURNSTILE_SITE_KEY; do
      if [ -z "${!key:-}" ]; then
        echo "Security preflight: $key is required when CAPTCHA is enabled." >&2
        exit 1
      fi
    done
    expected_hosts="${APP_DOMAIN:-},${DOMAIN:-}"
    for host in ${expected_hosts//,/ }; do
      case ",$TURNSTILE_ALLOWED_HOSTNAMES," in
        *",$host,"*) ;;
        *) echo 'TURNSTILE_ALLOWED_HOSTNAMES must include each deployed application host.' >&2; exit 1 ;;
      esac
    done
    ;;
  *) echo 'BAITLY_CAPTCHA_ENABLED must be true or false.' >&2; exit 1 ;;
esac
case "${BAITLY_ORIGIN_LOCKDOWN:-0}" in
  0) ;;
  1)
    if [ "${BAITLY_ORIGIN_PROXY_VERIFIED:-false}" != true ]; then
      echo 'Verify all public DNS records are proxied before enabling origin lockdown.' >&2
      exit 1
    fi
    ;;
  *) echo 'BAITLY_ORIGIN_LOCKDOWN must be 0 or 1.' >&2; exit 1 ;;
esac
echo 'Baitly security preflight passed.'
