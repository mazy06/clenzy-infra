#!/bin/bash
# ===========================================
# Clenzy - Script de déploiement VPS
# ===========================================
# Usage :
#   ./deploy.sh                     # Met à jour tous les services applicatifs
#   ./deploy.sh --service pms-server   # Met à jour un service spécifique
#   ./deploy.sh --full              # Rebuild complet de tous les services
#   ./deploy.sh --infra-only        # Met à jour uniquement l'infra (nginx, monitoring...)
#
# Ce script est conçu pour être exécuté sur le VPS OVH
# Il peut être appelé manuellement ou par le workflow GitHub Actions

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE=".env"
GHCR_OWNER="mazy06"
APP_SERVICES="pms-server pms-client landing"
INFRA_SERVICES="nginx postgres redis keycloak kafka"
MONITORING_SERVICES="prometheus grafana loki promtail"

# ---- Fonctions ----

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --service SERVICE   Met à jour un service spécifique"
    echo "  --full              Rebuild complet (force-recreate)"
    echo "  --infra-only        Met à jour uniquement nginx, monitoring, etc."
    echo "  --app-only          Met à jour uniquement les services applicatifs"
    echo "  --backup            Exécuter un backup avant le déploiement"
    echo "  --no-prune          Ne pas nettoyer les anciennes images"
    echo "  --help              Afficher cette aide"
    exit 0
}

check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker n'est pas installé"
        exit 1
    fi

    if ! docker info &> /dev/null 2>&1; then
        log_error "Docker daemon n'est pas démarré"
        exit 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        log_error "Fichier $ENV_FILE introuvable"
        echo "   Copier .env.example en .env et configurer les valeurs"
        exit 1
    fi

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Fichier $COMPOSE_FILE introuvable"
        exit 1
    fi
}

login_ghcr() {
    if [ -n "$GHCR_TOKEN" ]; then
        log_info "Connexion au GitHub Container Registry..."
        echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_OWNER" --password-stdin 2>/dev/null
        log_success "Connecté à GHCR"
    else
        log_warning "Variable GHCR_TOKEN non définie, tentative sans authentification..."
    fi
}

backup() {
    if [ -f "./backup/backup.sh" ]; then
        log_info "Backup pré-déploiement en cours..."
        bash ./backup/backup.sh --env prod --db-only 2>/dev/null || log_warning "Backup ignoré"
    else
        log_warning "Script de backup non trouvé"
    fi
}

healthcheck() {
    log_info "Vérification de santé des services..."
    echo ""

    local FAILED=0
    local SERVICES="$@"

    if [ -z "$SERVICES" ]; then
        SERVICES="nginx pms-server pms-client landing postgres redis keycloak kafka"
    fi

    for SERVICE in $SERVICES; do
        local STATUS
        STATUS=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.State}}' "$SERVICE" 2>/dev/null || echo "not found")
        if [ "$STATUS" = "running" ]; then
            echo -e "   ${GREEN}✅ $SERVICE : running${NC}"
        else
            echo -e "   ${RED}❌ $SERVICE : $STATUS${NC}"
            FAILED=1
        fi
    done

    echo ""
    if [ $FAILED -eq 1 ]; then
        log_warning "Certains services ne sont pas en bonne santé"
        echo "   Vérifiez les logs : docker compose -f $COMPOSE_FILE logs"
        return 1
    else
        log_success "Tous les services sont opérationnels"
    fi
}

# ---- Parsing des arguments ----

DEPLOY_MODE="app"
SERVICE=""
DO_BACKUP=false
DO_PRUNE=true
FULL_REBUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SERVICE="$2"
            DEPLOY_MODE="single"
            shift 2
            ;;
        --full)
            FULL_REBUILD=true
            DEPLOY_MODE="full"
            shift
            ;;
        --infra-only)
            DEPLOY_MODE="infra"
            shift
            ;;
        --app-only)
            DEPLOY_MODE="app"
            shift
            ;;
        --backup)
            DO_BACKUP=true
            shift
            ;;
        --no-prune)
            DO_PRUNE=false
            shift
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Option inconnue: $1"
            usage
            ;;
    esac
done

# ---- Exécution ----

echo "=========================================="
echo "🚀 Clenzy — Déploiement Production"
echo "=========================================="
echo ""
echo "Mode : $DEPLOY_MODE"
echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

check_prerequisites
login_ghcr

if [ "$DO_BACKUP" = true ]; then
    backup
fi

case $DEPLOY_MODE in
    single)
        log_info "Mise à jour du service : $SERVICE"
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull "$SERVICE" 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d "$SERVICE"
        sleep 10
        healthcheck "$SERVICE"
        ;;
    app)
        log_info "Mise à jour des services applicatifs..."
        for SVC in $APP_SERVICES; do
            log_info "  Pull $SVC..."
            docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull "$SVC" 2>/dev/null || true
        done
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d $APP_SERVICES
        sleep 15
        healthcheck $APP_SERVICES
        ;;
    infra)
        log_info "Mise à jour de l'infrastructure..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d $INFRA_SERVICES $MONITORING_SERVICES
        sleep 20
        healthcheck $INFRA_SERVICES
        ;;
    full)
        log_info "Rebuild complet de tous les services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate
        sleep 30
        healthcheck
        ;;
esac

if [ "$DO_PRUNE" = true ]; then
    log_info "Nettoyage des anciennes images..."
    docker image prune -f > /dev/null 2>&1
    log_success "Nettoyage terminé"
fi

echo ""
echo "=========================================="
log_success "Déploiement terminé !"
echo "=========================================="
echo ""
echo "🌐 Services :"
echo "   - Landing   : https://clenzy.fr"
echo "   - PMS       : https://app.clenzy.fr"
echo "   - API       : https://app.clenzy.fr/api"
echo "   - Auth      : https://auth.clenzy.fr"
echo ""
