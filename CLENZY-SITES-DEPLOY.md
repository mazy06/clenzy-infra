# Déploiement « Clenzy Sites » (SSR) — runbook infra

Service SSR des sites hébergés (`../clenzy-sites`, Next.js). Cadrage complet : `clenzy/analyse-concurrentielle/HANDOFF-SSR-CLENZY-SITES.md`.

> Fichiers fournis **additifs** (pas de mutation des fichiers prod live) :
> - `docker-compose.sites.yml` — service `clenzy-sites`.
> - `nginx/sites.conf.template` — vhost (à fusionner dans `nginx.conf.template` quand Cloudflare est prêt).

## Étapes (ordre)

### 1. Cloudflare for SaaS (console — prérequis)
- [ ] Acheter / ajouter la zone **`clenzy.site`** sur Cloudflare.
- [ ] Enregistrement **wildcard** `*.clenzy.site` (proxied) → cert wildcard (sous-domaines actifs d'emblée).
- [ ] Activer **Cloudflare for SaaS** + définir le **Fallback Origin** (hostname pointant vers ce VPS/nginx).
- [ ] Générer un **certificat Cloudflare Origin CA** → déposer dans `nginx/ssl/cloudflare-origin.{crt,key}`.
- [ ] (Recommandé) **Authenticated Origin Pulls** ou allowlist IP Cloudflare sur le default_server.

### 2. Repo + image clenzy-sites
- [ ] Créer le repo distant `clenzy-sites` + pousser `../clenzy-sites`.
- [ ] Cloner `../clenzy-sites` **sur l'hôte de déploiement** (build context du compose).
- [ ] (CI) Pipeline build/push `ghcr.io/mazy06/clenzy-sites:latest` (mirror du pattern clenzy-client).

### 3. Orchestration
- [ ] `SITES_BASE_DOMAIN=clenzy.site` dans `.env`.
- [ ] Lancer : `docker compose -f docker-compose.prod.yml -f docker-compose.sites.yml up -d --build clenzy-sites`
- [ ] Vérifier : `curl -H 'Host: <slug>.clenzy.site' http://clenzy-sites:3000/` (depuis le réseau docker).

### 4. nginx
- [ ] Fusionner `nginx/sites.conf.template` dans `nginx/nginx.conf.template` (bloc `http {}`),
      après avoir posé le cert origin. **Un seul `default_server` par port 443.**
- [ ] Ajouter `clenzy-sites` à `depends_on` du service `nginx` (optionnel mais propre).
- [ ] Recharger nginx.

### 5. Domaines custom (par site)
- [ ] Bridge backend `CloudflareCustomHostnameService` (repo `clenzy`, à construire — token CF requis) :
      à l'ajout d'un domaine (`POST /api/sites/{id}/domains`), créer le custom hostname Cloudflare,
      stocker `cloudflare_hostname_id`, réconcilier le statut → `ACTIVE`.
- [ ] Le client crée un CNAME `son-domaine.com → {slug}.clenzy.site` (affiché dans l'admin).

## Invariants à NE PAS toucher
- Le service `pms-server` (Liquibase `ENABLED=true`, `ddl-auto=validate`) — cf. CLAUDE.md.
- Les blocs nginx clenzy.fr existants (le vhost sites est un `default_server` séparé).
