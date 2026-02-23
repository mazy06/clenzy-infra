#!/bin/bash
# ===========================================
# Clenzy — Deploy Script
# ===========================================
# Logique de deploiement extraite du workflow CD.
# Execute par cd-deploy.yml apres git pull et provisioning .env.
#
# Pre-requis :
#   - Working directory = racine clenzy-infra
#   - .env charge dans le shell (set -a; . ./.env; set +a)
#   - DEPLOY_MODE   : 'update' | 'full-rebuild'
#   - DEPLOY_SERVICES : liste de services separee par virgule (optionnel)

set -e

DC="docker compose -f docker-compose.prod.yml --env-file .env"

# ===========================================
# 1. Bootstrap PostgreSQL & Keycloak DB
# ===========================================

KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak_prod}"
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "❌ POSTGRES_PASSWORD manquant dans .env."
  exit 1
fi
PG_USER_LIT=$(printf '%s' "${POSTGRES_USER}" | sed "s/'/''/g")
PG_USER_IDENT=$(printf '%s' "${POSTGRES_USER}" | sed 's/"/""/g')
PG_PASSWORD_LIT=$(printf '%s' "${POSTGRES_PASSWORD}" | sed "s/'/''/g")
KC_DB_NAME_LIT=$(printf '%s' "${KEYCLOAK_DB_NAME}" | sed "s/'/''/g")
KC_DB_NAME_IDENT=$(printf '%s' "${KEYCLOAK_DB_NAME}" | sed 's/"/""/g')

echo "🗄️  Demarrage de PostgreSQL..."
$DC up -d postgres

ATTEMPTS=0
until $DC exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge 30 ]; then
    echo "❌ PostgreSQL non pret apres attente."
    exit 1
  fi
  sleep 2
done

echo "🔑 Synchronisation du mot de passe PostgreSQL (${POSTGRES_USER})..."
$DC exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
  -c "ALTER USER \"${PG_USER_IDENT}\" WITH PASSWORD '${PG_PASSWORD_LIT}';"

AUTH_OK=$($DC exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  psql -h localhost -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SELECT 1" 2>/dev/null || true)
if [ "$AUTH_OK" != "1" ]; then
  echo "❌ Echec de la synchronisation du mot de passe PostgreSQL."
  exit 1
fi
echo "   ✅ Mot de passe PostgreSQL synchronise."

echo "🗄️  Verification base Keycloak (${KEYCLOAK_DB_NAME})..."
DB_EXISTS=$($DC exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${KC_DB_NAME_LIT}'")
if [ "$DB_EXISTS" != "1" ]; then
  echo "➕ Creation de la base ${KEYCLOAK_DB_NAME}..."
  $DC exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${KC_DB_NAME_IDENT}\" OWNER \"${PG_USER_IDENT}\";"
fi

$DC exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
  -c "GRANT ALL PRIVILEGES ON DATABASE \"${KC_DB_NAME_IDENT}\" TO \"${PG_USER_IDENT}\";"

AUTH_KC=$($DC exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  psql -h localhost -U "${POSTGRES_USER}" -d "${KEYCLOAK_DB_NAME}" -tAc "SELECT 1" 2>/dev/null || true)
if [ "$AUTH_KC" != "1" ]; then
  echo "❌ Auth DB Keycloak invalide (${POSTGRES_USER}@${KEYCLOAK_DB_NAME})."
  exit 1
fi
echo "   ✅ Base Keycloak OK."

# ===========================================
# 2. Backup pre-deploiement
# ===========================================

echo "💾 Backup pre-deploiement..."
if [ -f "./backup/backup.sh" ]; then
  bash ./backup/backup.sh --env prod --db-only 2>/dev/null || echo "⚠️  Backup ignore (base non disponible)"
fi

# ===========================================
# 3. Deploiement par phases
# ===========================================
# Phase 1 : postgres + redis (base infra) demarres EN PREMIER
# Phase 2 : tous les autres services (keycloak, pms-server, etc.)
# Evite le race condition ou keycloak/pms-server demarrent
# avant que postgres soit pret (surtout apres pull d'une nouvelle image).

SERVICES_LIST=$(echo "${DEPLOY_SERVICES}" | tr ',' ' ')

wait_pg() {
  local label="$1"
  local attempt=0
  until $DC exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      echo "❌ PostgreSQL non pret ($label)."
      exit 1
    fi
    sleep 2
  done
  echo "   ✅ PostgreSQL pret."
}

if [ "$DEPLOY_MODE" = "full-rebuild" ]; then
  echo "🔄 Rebuild complet de tous les services..."
  $DC pull
  echo "   Arret de tous les services..."
  $DC down --timeout 30
  echo "   Phase 1 — Demarrage PostgreSQL + Redis..."
  $DC up -d postgres redis
  wait_pg "apres rebuild"
  echo "   Phase 2 — Demarrage de tous les services..."
  $DC up -d
  HEALTH_SERVICES="nginx pms-server pms-client landing postgres redis keycloak kafka"
else
  if [ -n "$SERVICES_LIST" ]; then
    echo "📦 Mise a jour des services : $SERVICES_LIST"
    $DC pull $SERVICES_LIST
    $DC up -d $SERVICES_LIST
    HEALTH_SERVICES="$SERVICES_LIST"
  else
    echo "📦 Mise a jour de tous les services..."
    $DC pull
    echo "   Phase 1 — Infrastructure de base (postgres, redis)..."
    $DC up -d postgres redis
    wait_pg "apres mise a jour"
    echo "   Phase 2 — Demarrage de tous les services..."
    $DC up -d
    HEALTH_SERVICES="nginx pms-server pms-client landing postgres redis keycloak kafka"
  fi
fi

# ===========================================
# 3b. Detection crash-loop + force-recreate
# ===========================================
# docker compose up -d ne recree PAS les containers dont la config n'a
# pas change. Si un service etait deja en crash-loop (deploy precedent
# echoue), il reste bloque. On detecte et on force-recreate.

CRASH_LOOP_FIXED=0
for SVC in keycloak pms-server pgbouncer; do
  SVC_STATE=$($DC ps --format '{{.State}}' "$SVC" 2>/dev/null || echo "not found")
  if [ "$SVC_STATE" = "restarting" ]; then
    echo "   ⚠️  $SVC en crash-loop, recreation forcee..."
    $DC up -d --force-recreate --no-deps "$SVC"
    CRASH_LOOP_FIXED=1
  fi
done

if [ "$CRASH_LOOP_FIXED" -eq 1 ]; then
  echo "   Attente de PostgreSQL apres force-recreate..."
  wait_pg "post-force-recreate"
  sleep 5
fi

# ===========================================
# 4. Nettoyage + Nginx reload
# ===========================================

echo "🧹 Nettoyage des anciennes images..."
docker image prune -f

echo "♻️  Recreation de Nginx pour recharger la configuration..."
$DC up -d --no-deps --force-recreate nginx

# ===========================================
# 5. Healthcheck avec retry
# ===========================================

echo ""
echo "⏳ Attente de PostgreSQL (post-deploy)..."
wait_pg "post-deploy"

echo ""
echo "📊 Etat des services :"
$DC ps

echo ""
echo "🏥 Verification de sante (attente max 120s) :"

# Keycloak a son propre check HTTP ci-dessous
BASIC_SERVICES=""
for S in $HEALTH_SERVICES; do
  [ "$S" != "keycloak" ] && BASIC_SERVICES="$BASIC_SERVICES $S"
done

FAILED=0
STILL_WAITING="$BASIC_SERVICES"
ELAPSED=0
MAX_WAIT=120
INTERVAL=5

while [ -n "$STILL_WAITING" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  NEXT_WAITING=""
  for SERVICE in $STILL_WAITING; do
    STATUS=$(docker compose -f docker-compose.prod.yml ps --format '{{.State}}' $SERVICE 2>/dev/null || echo "not found")
    if [ "$STATUS" != "running" ]; then
      NEXT_WAITING="$NEXT_WAITING $SERVICE"
    fi
  done
  STILL_WAITING="$NEXT_WAITING"
done

for SERVICE in $BASIC_SERVICES; do
  STATUS=$(docker compose -f docker-compose.prod.yml ps --format '{{.State}}' $SERVICE 2>/dev/null || echo "not found")
  if [ "$STATUS" = "running" ]; then
    echo "   ✅ $SERVICE : running"
  else
    echo "   ❌ $SERVICE : $STATUS"
    echo "   📋 Logs recents de $SERVICE :"
    $DC logs --tail=20 $SERVICE 2>&1 | tail -15 || true
    FAILED=1
  fi
done

# ===========================================
# 6. Keycloak readiness HTTP + admin sync
# ===========================================

if echo " $HEALTH_SERVICES " | grep -q " keycloak "; then
  echo "🔎 Verification readiness HTTP de Keycloak..."
  KEYCLOAK_READY=0
  for _ in $(seq 1 60); do
    READY_PAYLOAD=$($DC exec -T postgres sh -c "wget -qO- http://clenzy-keycloak:8080/health/ready" 2>/dev/null || true)
    if echo "$READY_PAYLOAD" | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then
      KEYCLOAK_READY=1
      break
    fi
    sleep 2
  done

  if [ "$KEYCLOAK_READY" -eq 1 ]; then
    echo "   ✅ keycloak readiness HTTP: UP"

    if [ -n "${KEYCLOAK_ADMIN}" ] && [ -n "${KEYCLOAK_ADMIN_PASSWORD}" ]; then
      echo "🔑 Verification du mot de passe admin Keycloak..."
      KC_LOGIN_OK=0
      $DC exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080 --realm master \
        --user "${KEYCLOAK_ADMIN}" --password "${KEYCLOAK_ADMIN_PASSWORD}" 2>/dev/null || KC_LOGIN_OK=$?

      if [ "$KC_LOGIN_OK" -ne 0 ]; then
        echo "   ⚠️  Mot de passe admin desynchronise, reset via PBKDF2 + SQL..."

        KC_MASTER_REALM_ID=$($DC exec -T postgres psql -U "${POSTGRES_USER}" \
          -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -tAc \
          "SELECT id FROM realm WHERE name='master'" 2>/dev/null | tr -d '[:space:]')

        KC_ADMIN_ID=""
        if [ -n "$KC_MASTER_REALM_ID" ]; then
          KC_ADMIN_ID=$($DC exec -T postgres psql -U "${POSTGRES_USER}" \
            -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -tAc \
            "SELECT id FROM user_entity WHERE username='${KEYCLOAK_ADMIN}' AND realm_id='${KC_MASTER_REALM_ID}'" 2>/dev/null | tr -d '[:space:]')
        fi

        if [ -n "$KC_ADMIN_ID" ]; then
          echo "   Admin user trouve (id: ${KC_ADMIN_ID})"

          KC_CURRENT_ALGO=$($DC exec -T postgres psql -U "${POSTGRES_USER}" \
            -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -tAc \
            "SELECT credential_data::json->>'algorithm' FROM credential WHERE user_id='${KC_ADMIN_ID}' AND type='password';" 2>/dev/null | tr -d '[:space:]')
          KC_CURRENT_ITER=$($DC exec -T postgres psql -U "${POSTGRES_USER}" \
            -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -tAc \
            "SELECT credential_data::json->>'hashIterations' FROM credential WHERE user_id='${KC_ADMIN_ID}' AND type='password';" 2>/dev/null | tr -d '[:space:]')

          KC_ALGO="${KC_CURRENT_ALGO:-pbkdf2-sha256}"
          KC_ITER="${KC_CURRENT_ITER:-27500}"
          case "$KC_ALGO" in
            pbkdf2-sha512) KC_DIGEST="SHA512" ; KC_KEYLEN=64 ;;
            pbkdf2-sha256) KC_DIGEST="SHA256" ; KC_KEYLEN=64 ;;
            *)             KC_DIGEST="SHA256" ; KC_KEYLEN=64 ; KC_ALGO="pbkdf2-sha256" ;;
          esac

          KC_SALT_HEX=$(openssl rand -hex 16)
          KC_HASH_COLON=$(openssl kdf -keylen "$KC_KEYLEN" -kdfopt "digest:${KC_DIGEST}" \
            -kdfopt "pass:${KEYCLOAK_ADMIN_PASSWORD}" -kdfopt "hexsalt:${KC_SALT_HEX}" \
            -kdfopt "iter:${KC_ITER}" PBKDF2 2>/dev/null || true)
          KC_HASH_B64=""
          KC_SALT_B64=""
          if [ -n "$KC_HASH_COLON" ]; then
            KC_HASH_HEX=$(echo "$KC_HASH_COLON" | tr -d ':[:space:]')
            KC_HASH_B64=$(printf '%s' "$KC_HASH_HEX" | xxd -r -p | base64 -w0)
            KC_SALT_B64=$(printf '%s' "$KC_SALT_HEX" | xxd -r -p | base64 -w0)
          fi

          if [ -n "$KC_HASH_B64" ] && [ -n "$KC_SALT_B64" ]; then
            echo "   Hash genere, mise a jour en base..."
            KC_SECRET_DATA="{\"value\":\"${KC_HASH_B64}\",\"salt\":\"${KC_SALT_B64}\"}"
            KC_CRED_DATA="{\"hashIterations\":${KC_ITER},\"algorithm\":\"${KC_ALGO}\",\"additionalParameters\":{}}"

            $DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -c \
              "UPDATE credential SET secret_data='${KC_SECRET_DATA}', credential_data='${KC_CRED_DATA}' WHERE user_id='${KC_ADMIN_ID}' AND type='password';" 2>&1 || true

            echo "   Suppression des required_actions..."
            $DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -c \
              "DELETE FROM user_required_action WHERE user_id='${KC_ADMIN_ID}';" 2>&1 || true

            CRED_COUNT=$($DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -tAc \
              "SELECT count(*) FROM credential WHERE user_id='${KC_ADMIN_ID}' AND type='password';" 2>/dev/null | tr -d '[:space:]')
            if [ "$CRED_COUNT" = "0" ]; then
              $DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${KEYCLOAK_DB_NAME:-keycloak_prod}" -c \
                "INSERT INTO credential (id, user_id, type, secret_data, credential_data, priority) VALUES (gen_random_uuid()::text, '${KC_ADMIN_ID}', 'password', '${KC_SECRET_DATA}', '${KC_CRED_DATA}', 10);" 2>&1 || true
            fi

            echo "   Redemarrage de Keycloak (flush cache)..."
            $DC restart keycloak
            for _ in $(seq 1 40); do
              KC_READY2=$($DC exec -T postgres sh -c "wget -qO- http://clenzy-keycloak:8080/health/ready" 2>/dev/null || true)
              if echo "$KC_READY2" | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then break; fi
              sleep 3
            done

            echo "   Verification du login admin..."
            KC_RETRY=0
            $DC exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
              --server http://localhost:8080 --realm master \
              --user "${KEYCLOAK_ADMIN}" --password "${KEYCLOAK_ADMIN_PASSWORD}" 2>&1 || KC_RETRY=$?
            if [ "$KC_RETRY" -eq 0 ]; then
              echo "   ✅ Mot de passe admin Keycloak synchronise."
            else
              echo "   ⚠️  Login admin echoue (code: ${KC_RETRY}). Verifiez manuellement."
              $DC logs --tail=30 keycloak 2>&1 | tail -20 || true
            fi
          else
            echo "   ⚠️  Impossible de generer le hash PBKDF2 (openssl kdf non disponible?). Verifiez manuellement."
          fi
        else
          echo "   ⚠️  Utilisateur admin non trouve en base Keycloak."
        fi
      else
        echo "   ✅ Mot de passe admin Keycloak OK."
      fi
    fi

  else
    echo "   ❌ keycloak readiness HTTP: KO"
    $DC logs --tail=120 keycloak || true
    FAILED=1
  fi
fi

# ===========================================
# 7. Diagnostic des permissions
# ===========================================

echo ""
echo "🔍 Diagnostic permissions (base Clenzy)..."
echo "   Nombre de permissions en base :"
$DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
  "SELECT count(*) FROM permissions;" 2>/dev/null || echo "   ⚠️  Impossible de compter les permissions"
echo "   Permissions du role ADMIN :"
$DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
  "SELECT p.name FROM role_permissions rp JOIN permissions p ON rp.permission_id = p.id JOIN roles r ON rp.role_id = r.id WHERE r.name = 'ADMIN' AND rp.is_active = true ORDER BY p.name;" 2>/dev/null || echo "   ⚠️  Impossible de lister les permissions ADMIN"
echo "   Roles existants :"
$DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
  "SELECT name FROM roles ORDER BY name;" 2>/dev/null || echo "   ⚠️  Impossible de lister les roles"
echo "   role_permissions avec is_active NULL :"
$DC exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
  "SELECT count(*) FROM role_permissions WHERE is_active IS NULL;" 2>/dev/null || echo "   ⚠️  N/A"
echo "   Logs backend (permissions) :"
$DC logs --tail=50 pms-server 2>&1 | grep -iE "(Permission|Verification des permissions|creee|associee|initPermissions)" | tail -20 || echo "   (aucun log permission trouve)"

# ===========================================
# 8. Resultat final
# ===========================================

echo ""
if [ $FAILED -eq 1 ]; then
  echo "⚠️  Certains services ne sont pas en bonne sante !"
  echo "   Verifiez les logs : docker compose -f docker-compose.prod.yml logs"
  exit 1
else
  echo "✅ Tous les services sont operationnels !"
  echo ""
  echo "🌐 Services accessibles :"
  echo "   - Landing   : https://clenzy.fr"
  echo "   - PMS       : https://app.clenzy.fr"
  echo "   - API       : https://app.clenzy.fr/api"
  echo "   - Auth      : https://auth.clenzy.fr"
fi
