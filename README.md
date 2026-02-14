# Clenzy Infrastructure

Orchestration Docker de la plateforme Clenzy : site vitrine (landing page) + PMS (Property Management System) + services d'infrastructure.

## Architecture

```
                     ┌──────────────────────────┐
                     │   Nginx (reverse proxy)   │
                     │     ports 80 / 443        │
                     └────┬───────┬────────┬─────┘
                          │       │        │
             ┌────────────┘       │        └────────────┐
             ▼                    ▼                     ▼
    clenzy.fr            app.clenzy.fr           auth.clenzy.fr
    ┌───────────┐        ┌─────────────┐         ┌────────────┐
    │  Landing  │        │ PMS Client  │         │  Keycloak  │
    │  (Nginx)  │        │   (Nginx)   │         │            │
    └───────────┘        └──────┬──────┘         └────────────┘
                                │
                      ┌─────────▼─────────┐
                      │    PMS Server     │
                      │  (Spring Boot)    │
                      └─────────┬─────────┘
                                │
                    ┌───────────┼───────────┐
                    ▼                       ▼
              ┌───────────┐          ┌───────────┐
              │ PostgreSQL│          │   Redis   │
              └───────────┘          └───────────┘
```

## Prérequis

- **Docker** >= 24.0
- **Docker Compose** >= 2.20
- Les 2 repos clonés au meme niveau :

```
projets/
├── clenzy-landingpage/   ← Site vitrine (React + Tailwind)
├── clenzy/               ← PMS (Spring Boot + React + MUI)
└── clenzy-infra/         ← Ce repo (orchestration Docker)
```

## Demarrage rapide (dev)

```bash
# 1. Se placer dans le dossier infra
cd clenzy-infra

# 2. Lancer tous les services
./start-dev.sh

# Ou manuellement :
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build
```

## Services disponibles

### Developpement

| Service        | URL                          | Description                       |
|----------------|------------------------------|-----------------------------------|
| Landing Page   | http://localhost:8080         | Site vitrine Clenzy               |
| PMS Frontend   | http://localhost:3000         | Application PMS (React + MUI)     |
| PMS API        | http://localhost:8084         | Backend REST API (Spring Boot)    |
| Keycloak       | http://localhost:8086         | Console admin authentification    |
| PostgreSQL     | localhost:5433                | Base de donnees (via client SQL)  |
| Redis          | localhost:6379                | Cache (via redis-cli)             |
| Swagger UI     | http://localhost:8084/swagger-ui.html | Documentation API         |

### Production

| Service        | URL                          |
|----------------|------------------------------|
| Landing Page   | https://clenzy.fr            |
| PMS Frontend   | https://app.clenzy.fr        |
| PMS API        | https://app.clenzy.fr/api    |
| Keycloak       | https://auth.clenzy.fr       |

## Commandes utiles

### Demarrage et arret

```bash
# Demarrer en dev (avec logs)
./start-dev.sh

# Demarrer en dev (detache, sans logs)
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d

# Demarrer en production
./start-prod.sh

# Arreter (dev)
./stop.sh

# Arreter (prod)
./stop.sh prod

# Arreter et supprimer les volumes (reset complet)
docker compose -f docker-compose.dev.yml --env-file .env.dev down -v
```

### Logs

```bash
# Tous les services
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f

# Un service specifique
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f landing
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-server
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f pms-client
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f keycloak
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f postgres
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f redis

# Suivre les 50 dernieres lignes d'un service
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f --tail 50 pms-server
```

### Statut et monitoring

```bash
# Voir l'etat des conteneurs
docker compose -f docker-compose.dev.yml --env-file .env.dev ps

# Statistiques temps reel (CPU, memoire, reseau)
docker stats

# Verifier la sante d'un service
docker inspect --format='{{.State.Health.Status}}' clenzy-postgres-dev
```

### Base de donnees

```bash
# Se connecter a PostgreSQL (base PMS)
docker exec -it clenzy-postgres-dev psql -U clenzy -d clenzy_dev

# Se connecter a PostgreSQL (base Keycloak)
docker exec -it clenzy-postgres-dev psql -U clenzy -d keycloak_dev

# Lister les bases de donnees
docker exec -it clenzy-postgres-dev psql -U clenzy -c "\l"

# Lister les tables de la base PMS
docker exec -it clenzy-postgres-dev psql -U clenzy -d clenzy_dev -c "\dt"

# Exporter un dump de la base
docker exec clenzy-postgres-dev pg_dump -U clenzy clenzy_dev > backup_clenzy.sql

# Importer un dump
docker exec -i clenzy-postgres-dev psql -U clenzy -d clenzy_dev < backup_clenzy.sql
```

### Redis

```bash
# Se connecter a Redis
docker exec -it clenzy-redis-dev redis-cli

# Voir toutes les cles
docker exec -it clenzy-redis-dev redis-cli KEYS '*'

# Vider le cache Redis
docker exec -it clenzy-redis-dev redis-cli FLUSHALL

# Verifier les stats memoire
docker exec -it clenzy-redis-dev redis-cli INFO memory
```

### Keycloak

```bash
# Acceder a la console admin
# URL : http://localhost:8086
# Identifiants : voir .env.dev (KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD)

# Voir les logs de demarrage
docker compose -f docker-compose.dev.yml --env-file .env.dev logs keycloak

# Redemarrer Keycloak seul
docker compose -f docker-compose.dev.yml --env-file .env.dev restart keycloak
```

### Rebuild et mise a jour

```bash
# Rebuild un service specifique (ex: landing page apres modif)
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d landing

# Rebuild le backend PMS
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d pms-server

# Rebuild le frontend PMS
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d pms-client

# Rebuild TOUS les services
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d

# Forcer un rebuild sans cache
docker compose -f docker-compose.dev.yml --env-file .env.dev build --no-cache landing
```

### Nettoyage

```bash
# Supprimer les conteneurs arretes
docker container prune -f

# Supprimer les images inutilisees
docker image prune -f

# Supprimer les volumes orphelins
docker volume prune -f

# Nettoyage complet Docker (attention : supprime tout ce qui est inutilise)
docker system prune -af --volumes
```

### Entrer dans un conteneur

```bash
# Shell dans le backend Spring Boot
docker exec -it clenzy-server-dev sh

# Shell dans le frontend PMS
docker exec -it clenzy-frontend-dev sh

# Shell dans la landing page
docker exec -it clenzy-landing-dev sh
```

## Structure du projet

```
clenzy-infra/
├── docker-compose.dev.yml       # Orchestration dev (6 services, ports exposes)
├── docker-compose.prod.yml      # Orchestration prod (8 services + Nginx + Certbot)
├── nginx/
│   ├── nginx.conf.template      # Template reverse proxy prod (variables DOMAIN/APP_DOMAIN/AUTH_DOMAIN)
│   └── ssl/                     # Certificats SSL auto-signes (dev)
│       ├── clenzy.fr.crt
│       └── clenzy.fr.key
├── init-scripts/
│   └── 01-init-databases.sql    # Creation auto des bases (clenzy_dev + keycloak_dev)
├── .env.dev                     # Variables d'env + identifiants dev (pret a l'emploi)
├── .env.example                 # Template variables d'env prod (a copier en .env)
├── init-letsencrypt.sh          # Script premiere installation Let's Encrypt
├── start-dev.sh                 # Script demarrage dev
├── start-prod.sh                # Script demarrage prod
├── stop.sh                      # Script d'arret (dev ou prod)
├── .gitignore
└── README.md
```

## Configuration

### Environnement de developpement

Le fichier `.env.dev` est fourni pret a l'emploi avec des valeurs par defaut. Aucune configuration necessaire.

**Identifiants par defaut :**

Tous les identifiants de developpement (PostgreSQL, Keycloak, PMS) sont centralises dans le fichier `.env.dev`. Consultez ce fichier pour obtenir les utilisateurs et mots de passe :

```bash
cat .env.dev
```

### Environnement de production

```bash
# 1. Copier le template
cp .env.example .env

# 2. Editer et renseigner les valeurs de production
nano .env

# 3. Generer les certificats SSL (voir section SSL ci-dessous)
./init-letsencrypt.sh

# 4. Lancer
./start-prod.sh
```

**Variables a configurer obligatoirement en prod :**

| Variable               | Description                              |
|------------------------|------------------------------------------|
| `POSTGRES_PASSWORD`    | Mot de passe fort pour PostgreSQL        |
| `KEYCLOAK_ADMIN_PASSWORD` | Mot de passe admin Keycloak           |
| `KEYCLOAK_DB_PASSWORD` | Mot de passe BDD Keycloak                |
| `KEYCLOAK_CLIENT_SECRET` | Secret client OAuth2                   |
| `JWT_SECRET`           | Secret JWT (256 bits minimum)            |
| `DOMAIN`               | Domaine principal (ex: clenzy.fr)        |
| `APP_DOMAIN`           | Sous-domaine PMS (ex: app.clenzy.fr)     |
| `AUTH_DOMAIN`          | Sous-domaine auth (ex: auth.clenzy.fr)   |
| `CERTBOT_CERT_NAME`    | Nom du certificat dans `/etc/letsencrypt/live` (souvent identique a `DOMAIN`) |

## SSL / Let's Encrypt

### Certificats auto-signes (dev)

Les certificats auto-signes dans `nginx/ssl/` sont utilises pour le developpement local uniquement. Les navigateurs afficheront un avertissement de securite — c'est normal.

### Certificats Let's Encrypt (prod)

En production, le projet utilise **Certbot** pour generer des certificats SSL gratuits et reconnus par tous les navigateurs via [Let's Encrypt](https://letsencrypt.org/).

**Prerequis :**
- Un serveur avec une IP publique
- Les enregistrements DNS (A records) pointant vers cette IP pour les 3 domaines :
  - `clenzy.fr` + `www.clenzy.fr`
  - `app.clenzy.fr`
  - `auth.clenzy.fr`
- Le port 80 ouvert et accessible depuis Internet

**Premiere installation :**

```bash
# 1. Configurer le fichier .env avec les domaines et l'email
cp .env.example .env
nano .env
# Renseigner DOMAIN, APP_DOMAIN, AUTH_DOMAIN, LETSENCRYPT_EMAIL
# Optionnel: CERTBOT_CERT_NAME (par defaut = DOMAIN)

# 2. Lancer le script d'initialisation
./init-letsencrypt.sh
```

Le script effectue automatiquement :
1. Cree un certificat temporaire pour permettre a Nginx de demarrer
2. Demarre Nginx en mode HTTP (port 80)
3. Lance le challenge ACME Let's Encrypt (verification de propriete du domaine)
4. Installe les vrais certificats et recharge Nginx

**Renouvellement automatique :**

Le service `certbot` dans le docker-compose prod tourne en continu et tente un renouvellement toutes les 12 heures. Les certificats Let's Encrypt expirent apres 90 jours mais sont renouveles automatiquement bien avant.

Pour forcer un renouvellement manuel :

```bash
docker compose -f docker-compose.prod.yml --env-file .env run --rm certbot \
  certbot renew --webroot -w /var/www/certbot --force-renewal

# Recharger Nginx apres renouvellement
docker compose -f docker-compose.prod.yml --env-file .env exec nginx nginx -s reload
```

**Verifier l'etat des certificats :**

```bash
docker compose -f docker-compose.prod.yml --env-file .env run --rm certbot \
  certbot certificates
```

## Reseau Docker

Tous les services communiquent via le reseau interne `clenzy-network`. Les alias reseau permettent aux services de se trouver par nom :

| Alias             | Service             |
|-------------------|---------------------|
| `clenzy-landing`  | Landing Page        |
| `clenzy-frontend` | PMS Frontend        |
| `clenzy-server`   | PMS Backend API     |
| `clenzy-keycloak` | Keycloak            |
| `clenzy-redis`    | Redis               |
| `postgres`        | PostgreSQL          |

## Depannage

### Keycloak ne demarre pas

```bash
# Verifier les logs
docker compose -f docker-compose.dev.yml --env-file .env.dev logs keycloak

# Cause frequente : base keycloak_dev manquante
# Solution : supprimer les volumes et relancer
docker compose -f docker-compose.dev.yml --env-file .env.dev down -v
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d
```

### Port deja utilise

```bash
# Identifier le processus qui occupe le port (ex: 8086)
lsof -i :8086

# Ou verifier les conteneurs Docker
docker ps --format "table {{.Names}}\t{{.Ports}}"

# Arreter le conteneur en conflit
docker stop <nom-du-conteneur>
```

### Le backend PMS ne se connecte pas a Keycloak

Keycloak met environ 15-30 secondes a demarrer. Le backend retente automatiquement la connexion. Verifier avec :

```bash
# Attendre que Keycloak soit pret
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f keycloak | grep "started in"

# Puis redemarrer le backend si besoin
docker compose -f docker-compose.dev.yml --env-file .env.dev restart pms-server
```

### Reset complet

```bash
# Tout arreter, supprimer volumes et images
docker compose -f docker-compose.dev.yml --env-file .env.dev down -v --rmi local

# Relancer de zero
docker compose -f docker-compose.dev.yml --env-file .env.dev up --build -d
```
