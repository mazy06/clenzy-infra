#!/usr/bin/env bash
# ============================================================================
# Clenzy — Setup OpenWA (WhatsApp self-hosted)
# ----------------------------------------------------------------------------
# Idempotent : peut etre relance sans risque. Fait :
#   1. Clone le repo OpenWA dans ./openwa/ si absent
#   2. Genere OPENWA_API_MASTER_KEY si absent dans .env.dev (32 bytes hex)
#   3. Verifie que le profile docker `openwa` est present dans docker-compose.dev.yml
#   4. Print les commandes de demarrage et l'URL du dashboard
#
# Pourquoi pas un git submodule : on ne veut PAS embarquer OpenWA dans le repo
# clenzy-infra (license MIT compatible mais code tiers volumineux, mises a jour
# independantes, debug plus simple en clone standalone).
# ============================================================================

set -euo pipefail

OPENWA_REPO="https://github.com/rmyndharis/OpenWA.git"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWA_DIR="${INFRA_DIR}/openwa"
ENV_FILE="${INFRA_DIR}/.env.dev"
ENV_VAR="OPENWA_API_MASTER_KEY"

# Couleurs pour le terminal (best-effort, fallback si terminal sans color)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' RESET=''
fi

echo -e "${BLUE}=== Clenzy OpenWA Setup ===${RESET}"
echo ""

# ─── 1. Clone du repo OpenWA ──────────────────────────────────────────────

if [[ -d "${OPENWA_DIR}" ]]; then
    if [[ -d "${OPENWA_DIR}/.git" ]]; then
        echo -e "${GREEN}✓${RESET} OpenWA deja clone dans ${OPENWA_DIR}"
        echo -e "  ${YELLOW}Tip${RESET}: pour mettre a jour : cd ${OPENWA_DIR} && git pull"
    else
        echo -e "${RED}✗${RESET} ${OPENWA_DIR} existe mais n'est pas un repo git."
        echo "  Supprime-le manuellement et relance ce script."
        exit 1
    fi
else
    echo -e "${BLUE}→${RESET} Clone OpenWA depuis ${OPENWA_REPO}..."
    git clone --depth 1 "${OPENWA_REPO}" "${OPENWA_DIR}"
    echo -e "${GREEN}✓${RESET} OpenWA clone dans ${OPENWA_DIR}"
fi

# ─── 2. Generation OPENWA_API_MASTER_KEY ──────────────────────────────────

if [[ ! -f "${ENV_FILE}" ]]; then
    echo -e "${RED}✗${RESET} Fichier ${ENV_FILE} introuvable."
    echo "  Cree-le d'abord : cp .env.example .env.dev"
    exit 1
fi

if grep -q "^${ENV_VAR}=" "${ENV_FILE}"; then
    EXISTING_VAL=$(grep "^${ENV_VAR}=" "${ENV_FILE}" | cut -d'=' -f2-)
    if [[ "${EXISTING_VAL}" == "CHANGE_ME_openwa_master_key_32_hex_chars" || -z "${EXISTING_VAL}" ]]; then
        # Valeur placeholder ou vide -> on regenere
        NEW_KEY=$(openssl rand -hex 32)
        # sed -i syntax differe entre Linux et macOS
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s|^${ENV_VAR}=.*|${ENV_VAR}=${NEW_KEY}|" "${ENV_FILE}"
        else
            sed -i "s|^${ENV_VAR}=.*|${ENV_VAR}=${NEW_KEY}|" "${ENV_FILE}"
        fi
        echo -e "${GREEN}✓${RESET} ${ENV_VAR} genere (64 chars hex) dans ${ENV_FILE}"
    else
        echo -e "${GREEN}✓${RESET} ${ENV_VAR} deja defini dans ${ENV_FILE} (conserve)"
    fi
else
    NEW_KEY=$(openssl rand -hex 32)
    echo "" >> "${ENV_FILE}"
    echo "# OpenWA — genere par setup-openwa.sh" >> "${ENV_FILE}"
    echo "${ENV_VAR}=${NEW_KEY}" >> "${ENV_FILE}"
    echo -e "${GREEN}✓${RESET} ${ENV_VAR} ajoute dans ${ENV_FILE}"
fi

# ─── 3. Verification profile dans docker-compose ──────────────────────────

if grep -q "profiles:" "${INFRA_DIR}/docker-compose.dev.yml" && \
   grep -q "openwa:" "${INFRA_DIR}/docker-compose.dev.yml"; then
    echo -e "${GREEN}✓${RESET} Service 'openwa' present dans docker-compose.dev.yml"
else
    echo -e "${RED}✗${RESET} Service 'openwa' manquant dans docker-compose.dev.yml"
    echo "  Verifie que le service openwa avec profile: [openwa] existe."
    exit 1
fi

# ─── 4. Instructions de demarrage ─────────────────────────────────────────

echo ""
echo -e "${GREEN}=== Setup OpenWA termine ===${RESET}"
echo ""
echo "Pour demarrer OpenWA en dev (ajoute aux autres services qui tournent deja) :"
echo -e "  ${BLUE}docker compose -f docker-compose.dev.yml --env-file .env.dev --profile openwa up -d openwa${RESET}"
echo ""
echo "Verifier que OpenWA tourne :"
echo -e "  ${BLUE}docker logs -f clenzy-openwa-dev${RESET}"
echo -e "  ${BLUE}curl http://localhost:2785/api/health${RESET}"
echo ""
echo "Dashboard React + Swagger :"
echo -e "  ${BLUE}http://localhost:2785/api/docs${RESET}"
echo ""
echo "Stopper OpenWA seul (sans toucher aux autres services) :"
echo -e "  ${BLUE}docker compose -f docker-compose.dev.yml --profile openwa stop openwa${RESET}"
echo ""
echo -e "${YELLOW}⚠️  Reminder${RESET} : OpenWA est HORS ToS Meta. Reserve aux trials/MVP."
echo -e "  Cf. CLAUDE.md section 'Provider Strategy WhatsApp' pour les details."
