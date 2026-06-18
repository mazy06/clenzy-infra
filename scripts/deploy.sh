#!/bin/bash
# ===========================================
# Clenzy — Deploy Script
# ===========================================
# Logique de deploiement extraite du workflow CD.
# Execute par cd-deploy.yml apres git pull et provisioning .env.
#
# Redeploy 2026-06-02 : relance de la stack (mode update) apres annulation
# d'un full-rebuild interrompu — incident prod down. Aucun changement de logique.
#
# Pre-requis :
#   - Working directory = racine clenzy-infra
#   - .env charge dans le shell (set -a; . ./.env; set +a)
#   - DEPLOY_MODE   : 'update' | 'full-rebuild'
#   - DEPLOY_SERVICES : liste de services separee par virgule (optionnel)

set -e

DC="docker compose -f docker-compose.prod.yml --env-file .env"

# ===========================================
# Observabilite deploiement (Pushgateway + Alertmanager)
# ===========================================
# Statut du deploiement pousse au Pushgateway (scrute par Prometheus) :
#   - clenzy_deploy_status            (job clenzy-deploy)          : 1=OK, 0=KO du DERNIER deploy
#   - clenzy_deploy_last_success_timestamp_seconds (job clenzy-deploy-success) : horodatage du
#     dernier succes, dans un job SEPARE pour survivre aux pushes d'echec (regle ClenzyDeployStale).
PUSHGATEWAY_URL="${DEPLOY_PUSHGATEWAY_URL:-http://127.0.0.1:9091}"

push_metric() { # $1=job  $2=corps-metrics
  printf '%s\n' "$2" \
    | curl -fsS --max-time 5 --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/$1" >/dev/null 2>&1 \
    && return 0 || return 1
}

on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    if push_metric clenzy-deploy "clenzy_deploy_status 1" \
       && push_metric clenzy-deploy-success "clenzy_deploy_last_success_timestamp_seconds $(date +%s)"; then
      echo "   📈 Statut deploiement pousse au Pushgateway (succes)."
    fi
  else
    push_metric clenzy-deploy "clenzy_deploy_status 0" \
      && echo "   📈 Statut deploiement pousse au Pushgateway (echec)." || true
  fi
}
trap on_exit EXIT

# Token partage Alertmanager -> app (credentials_file lu par Alertmanager). Ecrit depuis
# l'env (.env charge par cd-deploy) ; jamais commite. Memo valeur que CLENZY_OPS_ALERT_TOKEN
# cote pms-server et le secret GitHub OPS_ALERT_TOKEN.
# On ecrit TOUJOURS le fichier (vide si token absent) : Alertmanager refuse de demarrer
# si son credentials_file est introuvable. Vide -> l'app rejette (fail-closed), mais le
# conteneur tourne au lieu de crash-looper.
mkdir -p monitoring/alertmanager
( umask 077; printf '%s' "${CLENZY_OPS_ALERT_TOKEN:-}" > monitoring/alertmanager/ops_token )
if [ -n "${CLENZY_OPS_ALERT_TOKEN:-}" ]; then
  echo "🔐 Token Alertmanager provisionne (monitoring/alertmanager/ops_token)."
else
  echo "⚠️  CLENZY_OPS_ALERT_TOKEN absent : fichier token vide ecrit (Alertmanager ne pourra pas notifier l'app)."
fi

# ===========================================
# 0. Pre-flight checks
# ===========================================

if [ -z "$KAFKA_CLUSTER_ID" ]; then
  echo "❌ KAFKA_CLUSTER_ID manquant dans .env."
  echo "   Generer avec : head -c 16 /dev/urandom | base64 | tr '/+' '_-' | head -c 22"
  exit 1
fi

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
# 1b. Mise a jour du repo applicatif (clenzy)
# ===========================================
# Le docker-compose.prod.yml reference ../clenzy/client et ../clenzy/server
# pour les builds. Il faut synchroniser ce repo avec la branche production.

CLENZY_APP_DIR="$(cd .. && pwd)/clenzy"
if [ -d "$CLENZY_APP_DIR/.git" ]; then
  echo "📥 Mise a jour du repo applicatif ($CLENZY_APP_DIR)..."
  cd "$CLENZY_APP_DIR"

  # Defensive : les containers Docker (bind mounts) creent parfois des fichiers en root
  # dans le working tree → git reset --hard echoue avec "Permission denied".
  # On reprend la propriete recursivement avant les operations git.
  if sudo -n chown -R "$(id -u):$(id -g)" . 2>/dev/null; then
    echo "   🔧 Permissions reprises (chown defensif)."
  else
    echo "   ⚠️  Chown defensif ignore (sudo non disponible sans mot de passe)."
    echo "      Si git reset echoue, configurer NOPASSWD pour l'utilisateur de deploiement."
  fi

  # Authentifier le fetch via un token injecte par le workflow CD (secret GitHub Actions,
  # rotatable de maniere centralisee) plutot qu'un PAT longue-duree fige dans l'URL du remote
  # sur le VPS. Incident 2026-06 : ce PAT a expire -> tous les CD Deploy echouaient sur
  # "Authentication failed for github.com/<owner>/clenzy.git", le backend restait bloque sur une
  # ancienne image et la generation des devis tombait en echec.
  # Token : DEPLOY_APP_GIT_TOKEN (secret CLENZY_APP_GIT_TOKEN) si fourni, sinon repli sur
  # DEPLOY_GHCR_TOKEN (deja valide, utilise pour ghcr.io).
  APP_REPO_SLUG="${DEPLOY_APP_REPO:-${DEPLOY_GHCR_OWNER:-mazy06}/clenzy}"
  APP_REPO_URL="https://github.com/${APP_REPO_SLUG}.git"
  APP_GIT_TOKEN="${DEPLOY_APP_GIT_TOKEN:-${DEPLOY_GHCR_TOKEN:-}}"
  if [ -n "$APP_GIT_TOKEN" ]; then
    git remote set-url origin "https://x-access-token:${APP_GIT_TOKEN}@github.com/${APP_REPO_SLUG}.git"
  fi

  fetch_rc=0
  git fetch origin production || fetch_rc=$?
  # Toujours restaurer une URL sans secret (ne pas laisser le token en clair dans .git/config sur le VPS)
  git remote set-url origin "$APP_REPO_URL"
  if [ "$fetch_rc" -ne 0 ]; then
    echo "❌ Echec du fetch du repo applicatif clenzy (token d'authentification invalide ou expire ?)."
    echo "   Verifier le secret CLENZY_APP_GIT_TOKEN (ou le scope repo de GHCR_TOKEN)."
    exit 1
  fi

  git checkout production 2>/dev/null || git checkout -b production origin/production
  git reset --hard origin/production
  # Nettoyer les fichiers non suivis (hors gitignore) — evite les conflits au prochain pull
  git clean -fd --quiet 2>/dev/null || true
  echo "   ✅ Repo clenzy mis a jour : $(git log --oneline -1)"
  cd - >/dev/null
else
  echo "⚠️  Repo applicatif non trouve ($CLENZY_APP_DIR). Les builds utiliseront la version existante."
fi

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
# Phase 1b: kafka (messaging) demarre apres postgres, attend healthy
# Phase 2 : tous les autres services (keycloak, pms-server, etc.)
# Evite le race condition ou keycloak/pms-server demarrent
# avant que postgres/kafka soient prets (surtout apres pull d'une nouvelle image).

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

wait_kafka() {
  local label="$1"
  local attempt=0
  local max_attempts=24  # 24 x 5s = 120s max
  echo "   Attente de Kafka ($label)..."
  until docker exec clenzy-kafka-prod kafka-broker-api-versions --bootstrap-server localhost:9092 >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "   ⚠️  Kafka non pret apres ${max_attempts} tentatives ($label). Poursuite du deploiement..."
      return 1
    fi
    sleep 5
  done
  echo "   ✅ Kafka pret."
}

if [ "$DEPLOY_MODE" = "full-rebuild" ]; then
  echo "🔄 Rebuild complet de tous les services..."
  echo "   Build des images locales (pms-client, pms-server)..."
  $DC build --no-cache pms-client pms-server
  $DC pull
  echo "   Arret de tous les services..."
  $DC down --timeout 30
  echo "   Phase 1 — Demarrage PostgreSQL + Redis..."
  $DC up -d postgres redis
  wait_pg "apres rebuild"
  echo "   Phase 1b — Demarrage Kafka..."
  $DC up -d kafka
  wait_kafka "apres rebuild"
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
    # --force-recreate : les configs postgres (postgresql.conf, pg_hba.conf)
    # sont des bind mounts. docker compose up -d ne detecte pas les
    # changements de contenu des bind mounts — force-recreate garantit
    # que postgres relit toujours la derniere config.
    # Les donnees sont preservees (volume nomme postgres-data-prod).
    $DC up -d --force-recreate postgres redis
    wait_pg "apres mise a jour"
    echo "   Phase 1b — Demarrage Kafka..."
    $DC up -d kafka
    wait_kafka "apres mise a jour"
    echo "   Phase 2 — Demarrage de tous les services..."
    $DC up -d
    HEALTH_SERVICES="nginx pms-server pms-client landing postgres redis keycloak kafka"
  fi
fi

# ===========================================
# 3b. Detection crash-loop + recovery
# ===========================================
# Delai pour laisser les services demarrer et potentiellement crasher.
# Keycloak est protege par le wrapper entrypoint mais on garde ce filet
# de securite pour tous les services critiques.
# On utilise stop + rm + up -d (au lieu de --force-recreate --no-deps)
# pour respecter les depends_on et obtenir un container propre.

echo "   Stabilisation post-deploy (15s)..."
sleep 15

CRASH_LOOP_FIXED=0
for SVC in keycloak pms-server pgbouncer; do
  SVC_STATE=$($DC ps --format '{{.State}}' "$SVC" 2>/dev/null || echo "not found")
  if [ "$SVC_STATE" = "restarting" ]; then
    echo "   ⚠️  $SVC en crash-loop, arret + recreation..."
    $DC stop "$SVC" 2>/dev/null || true
    $DC rm -f "$SVC" 2>/dev/null || true
    sleep 3
    $DC up -d "$SVC"
    CRASH_LOOP_FIXED=1
  fi
done

if [ "$CRASH_LOOP_FIXED" -eq 1 ]; then
  echo "   Attente apres recovery (10s)..."
  sleep 10
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

# Sonde le readiness HTTP de Keycloak sans dependre d'un binaire absent.
# Keycloak 24 sert /health/ready sur le port HTTP principal 8080 (le port
# management dedie 9000 n'existe qu'a partir de Keycloak 25) ; on tente 8080
# puis 9000 par securite. Le wget/curl est lance depuis un container qui
# possede un client HTTP : postgres (Debian) n'a NI wget NI curl, ce qui
# faisait echouer le check en silence (faux negatif depuis 2026-06-04) — on
# essaie donc plusieurs containers (redis/nginx alpine ont busybox wget).
kc_health_probe() {
  for _c in redis nginx pms-server keycloak postgres; do
    for _u in http://clenzy-keycloak:8080/health/ready http://clenzy-keycloak:9000/health/ready; do
      _out=$($DC exec -T "$_c" sh -c "wget -qO- $_u 2>/dev/null || curl -sf $_u 2>/dev/null" 2>/dev/null || true)
      if printf '%s' "$_out" | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then
        printf '%s' "$_out"
        return 0
      fi
    done
  done
  return 1
}

if echo " $HEALTH_SERVICES " | grep -q " keycloak "; then
  echo "🔎 Verification readiness HTTP de Keycloak..."
  KEYCLOAK_READY=0
  for _ in $(seq 1 60); do
    READY_PAYLOAD=$(kc_health_probe || true)
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
              KC_READY2=$(kc_health_probe || true)
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
