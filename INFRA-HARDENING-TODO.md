# Infra Hardening TODO — Production OVH

> **Contexte.** On reste sur OVH (la migration AWS n'est pas requise par Airbnb : Airbnb exige une **revue de sécurité des données + qualité d'API**, pas un cloud provider précis — voir l'analyse du 2026-06-26).
> **But.** Corriger les fragilités structurelles de la prod (1 VPS, ~20 services, **aucune limite de ressources**, pas de heap JVM, SPOF DB) **et** satisfaire l'audit sécurité Airbnb — sans migrer.
>
> Cible : `clenzy-infra/docker-compose.prod.yml` + config app (`pms-server`) + sécurité applicative (repo `clenzy`).
> Convention : `[ ]` à faire · `[~]` en cours · `[x]` fait. Priorités **P0** (stabilité immédiate) → **P3** (résilience long terme).

---

## P0 — Stabilité immédiate (éviter l'OOM en cascade)

> Aujourd'hui seuls `libreoffice` (512M) et `go2rtc` (256M) ont une limite. Tous les autres se partagent la RAM du VPS librement → un pic mémoire peut OOM-killer Postgres/backend.

- [ ] **Limites + réservations mémoire sur CHAQUE service** (`deploy.resources.limits` + `reservations`). Grille de départ (à ajuster selon les specs réelles du VPS) :
  - [ ] `postgres` : limit **2–4 Go** + `reservation` ≥ limit·0.5 ; `shared_buffers` ≈ 25% de sa RAM, `effective_cache_size` ≈ 50%
  - [ ] `pms-server` : limit **1.5–2 Go**
  - [ ] `kafka` : limit **1–2 Go** + `KAFKA_HEAP_OPTS=-Xmx1g -Xms1g`
  - [ ] `keycloak` : limit **768 Mo–1 Go**
  - [ ] `redis` : limit **512 Mo** + `--maxmemory 384mb --maxmemory-policy allkeys-lru`
  - [ ] `prometheus`/`grafana`/`loki`/`promtail` : ~1.5 Go cumulé
  - [ ] `nginx`/`landing`/`certbot`/`pms-client`/`copilot-runtime` : 128–256 Mo chacun
- [ ] **Heap JVM explicite `pms-server`** : `JAVA_OPTS=-XX:MaxRAMPercentage=70 -XX:+UseG1GC` (avec `mem_limit`) **ou** `-Xmx1300m`. Sans ça la JVM voit toute la RAM de l'hôte.
- [ ] **Vérifier que somme(limits) ≤ RAM VPS − ~1 Go** (marge OS + cache). Si ça déborde → arbitrer (cf. P2 : sortir la DB) ou monter le VPS.
- [ ] `restart: unless-stopped` sur tous les services critiques (vérifier qu'aucun n'est en `no`).
- [ ] **Critère d'acceptation** : `docker stats` montre chaque conteneur sous sa limite en charge normale ; un stress mémoire d'un service n'en tue aucun autre.

## P1 — Sécurité / Audit Airbnb (le VRAI prérequis Airbnb)

> Beaucoup déjà couvert par le pentest Shannon + les règles sécu du repo. À vérifier/compléter et **documenter** (Airbnb demande des preuves).

- [ ] **Chiffrement en transit** : TLS partout côté edge (certbot/nginx OK) ; vérifier que les flux internes sensibles ne sortent pas en clair.
- [ ] **Chiffrement au repos** : confirmer le chiffrement applicatif des PII (`EncryptedFieldConverter` déjà en place) + envisager le chiffrement du volume disque OVH.
- [ ] **Gestion des secrets** : aucun secret en clair dans le compose/`.env` versionné ; rotation documentée ; `EnvironmentValidator` fail-fast en prod (déjà en place).
- [ ] **Isolation des données guests** : multi-tenant `@Filter` Hibernate + ownership (`requireSameOrganization`) — vérifier la couverture sur tout endpoint à ID.
- [ ] **Headers de sécurité** prod (`nginx.conf.template`) : HSTS, CSP, `Cache-Control: no-store` sur l'API (déjà via SecurityConfigProd).
- [ ] **Logs d'audit** des actions sensibles (audit-logging agent déjà ajouté ; vérifier la couverture paiement/résa).
- [ ] **Sauvegarde testée + restaurable** (cf. P2) — Airbnb apprécie la résilience des données.
- [ ] **Rédiger un dossier « sécurité »** (1 page) listant ces mesures → à fournir lors de la revue Airbnb.
- [ ] **Critère d'acceptation** : checklist sécurité auto-évaluée OK + dossier prêt à envoyer.

## P2 — Résilience structurelle (réduire le SPOF)

- [ ] **Sortir PostgreSQL du même hôte** (priorité n°1 de résilience) :
  - [ ] Option économique : **OVH Managed Database for PostgreSQL** (backups + HA managés, reste chez OVH)
  - [ ] Option intermédiaire : un **2ᵉ VPS/dédié OVH** uniquement pour la DB
- [ ] **Sauvegardes automatisées + testées** : le volume `backups-prod` existe — vérifier qu'un **dump quotidien** tourne (cron `pg_dump`), est **copié hors VPS** (S3-compatible OVH / autre datacenter), et **qu'une restauration a été testée** au moins une fois.
- [ ] **Snapshots VPS OVH** programmés (rollback machine entière).
- [ ] **Healthchecks** sur tous les services (plusieurs en ont déjà) + politique de redémarrage.
- [ ] **Plan de reprise (DR) écrit** : que faire si le VPS meurt (restaurer depuis backup + snapshot, RTO/RPO cibles).
- [ ] **Critère d'acceptation** : perte simulée du VPS → restauration < RTO cible depuis backups hors-site.

## P3 — Observabilité & exploitation

- [ ] **Alerting** Prometheus/Grafana : RAM/CPU par conteneur, disque < 15% libre, Postgres connections, JVM heap, erreurs 5xx, latence API, lag Kafka.
- [ ] **Alerte disque** (le risque silencieux n°1 d'un mono-VPS : disque plein → tout tombe).
- [ ] **Rétention des logs Loki** bornée (éviter de saturer le disque).
- [ ] **Dashboards** : un dashboard « santé VPS » (ressources par service) + un « santé app » (latence, erreurs, tokens IA/coûts — métriques `assistant.*` déjà exposées).
- [ ] **Limiter les outils non-prod** : `kafka-ui` et `k6` ne devraient pas tourner en continu en prod (consommation + surface d'attaque) → profil `tools` activable à la demande.
- [ ] **Critère d'acceptation** : une alerte arrive AVANT l'incident (disque/RAM/latence), pas après.

---

## Dimensionnement — specs RÉELLES (relevé SSH 2026-06-26)

**VPS : 4 vCPU (Intel Haswell @2.0GHz) · 7,6 GiB RAM · 0 swap · disque 72 G à 73% (20 G libres) · load ~1.3/4.**

### Constat (usage live `docker stats`)
- RAM utilisée ≈ **5,6 / 7,6 GiB (~74%)**, dispo réelle ~2 GiB. **La box est tendue.**
- **Les 3 gros consommateurs n'ont AUCUNE limite** : `pms-server` (JVM) **1,39 G**, `keycloak` **1,43 G**, `kafka` **1,15 G** → à eux 3 = **~4 GiB (> 50% de la RAM)**. Un pic = OOM, **et il n'y a pas de swap** (kill instantané).
- `kafka-ui` consomme **300 M en prod pour rien** (outil de debug).
- `postgres` n'utilise que **118 M** (peu de cache → `shared_buffers` par défaut ; pas le goulot aujourd'hui mais cohabite avec tout).
- Disque **73%** = risque silencieux n°1.

### Grille de `limits` calibrée (CAPS uniquement — pas de `reservations` sur box tendue)
| Service | `limits.memory` | Tuning |
|---|---|---|
| pms-server | **1800M** | `JAVA_OPTS=-XX:MaxRAMPercentage=70 -XX:+UseG1GC` |
| keycloak | **1600M** | (Java) |
| kafka | **1400M** | `KAFKA_HEAP_OPTS=-Xmx1g -Xms1g` |
| postgres | **1024M** | `shared_buffers=256MB`, `effective_cache_size=512MB` |
| redis | **256M** | `--maxmemory 192mb --maxmemory-policy allkeys-lru` |
| prometheus | **400M** | rétention bornée |
| loki | **300M** | rétention bornée |
| grafana | **256M** | |
| promtail | **200M** | |
| libreoffice / go2rtc | 512M / 256M | déjà bornés ✓ |
| nginx, client, landing, certbot, pgbouncer, *-exporter, alertmanager, pushgateway | **64–128M** chacun | |
| **kafka-ui** | **retirer du prod** (profil `tools`) | gain ~300M + surface d'attaque |

> ⚠️ La somme des caps (~8,8 G) **dépasse** la RAM (7,6 G) : normal pour des *caps* (ils plafonnent le runaway, ils ne réservent pas). Mais ça **confirme l'absence de marge** → voir « décisions » ci-dessous.

### Décisions de capacité (la box est à ~85-90%)
- [ ] **Ajouter un swap 2–4 GiB** (filet anti-OOM, la box n'en a AUCUN) : `fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` + `/etc/fstab`. **Le gain de sécurité le moins cher.**
- [ ] **Retirer kafka-ui** du run permanent (−300 M).
- [ ] **Surveiller/nettoyer le disque** (73%) : `docker image prune`, rétention Loki, logs.
- [ ] **Pour de la marge réelle** : soit **upgrader la RAM** (VPS OVH plus gros), soit **sortir Postgres** (OVH Managed DB / 2ᵉ VPS) — les limites évitent le runaway mais ne créent pas de marge.

### ⚠️ Déploiement des limites = délicat sur box tendue
`docker compose up -d` **recrée** les conteneurs (ancien + nouveau coexistent brièvement) → sur une box à 74% de RAM, **recréer tout d'un coup peut OOM**. → **ajouter le swap D'ABORD**, puis recréer **service par service** (`docker compose up -d <service>`), en commençant par les petits.

## Stockage objet & archivage — alléger PostgreSQL (P2)

> **Diagnostic** : la base gonfle à cause des **binaires stockés en BYTEA dans Postgres** (`PropertyPhoto`, `InterventionPhoto`, `ContactAttachmentFile`, `BinaryAsset`) + des **documents générés sur le disque du VPS** (volumes, déjà à 73%). Les données relationnelles, elles, sont légères (Postgres n'utilise que ~118 Mo). **Sortir les binaires de la base = le vrai allègement.**
> Le code est déjà prêt : `PhotoStorageService` est une interface dont l'impl actuelle est `LocalPhotoStorageService` (BYTEA) et qui prévoit explicitement un `S3PhotoStorageService` (« Future », swap par `@Profile`/config).

### Mapping donnée → service OVH
| Donnée | Aujourd'hui | Service OVH | Prix | Côté code |
|---|---|---|---|---|
| Images (photos biens/interventions, pièces jointes) | Postgres BYTEA | **Object Storage (S3)** | ~**0,012 €/Go/mois**, egress **gratuit** | implémenter `S3PhotoStorageService` |
| Documents générés (PDF, factures, reçus, contrats) | disque VPS (volumes) | **Object Storage (S3)** | idem | rediriger `DocumentStorageService`/`InvoicePdfService`/`ReceiptStorageService` vers S3 |
| Archives conformité OTA/fiscal (vieilles résas, factures NF, 6–10 ans) | tables Postgres | **OVH Cold Archive** | **1,3 €/To/mois** (restitution 5,12 €/To) | partition + export/dump vers Cold Archive |
| Base elle-même (une fois allégée) | VPS | *(option)* **Managed Database PostgreSQL** | ~dès quelques dizaines €/mois | pointer la datasource |

### Conformité OTA / fiscal
- [ ] **Object Lock / versioning (WORM)** sur le bucket d'archives → données **immuables** (ni altération ni suppression avant échéance) = preuve de conformité.
- [ ] **Cold Archive** pour la rétention longue (années/décennies) des archives rarement consultées (factures NF, vieilles résas).
- [ ] Documenter la **politique de rétention** par type de document (durée légale) dans le dossier sécurité (cf. P1).

### Tâches
- [ ] **Créer un bucket Object Storage OVH (S3)** + credentials (région EU).
- [ ] **Implémenter `S3PhotoStorageService`** (le seam existe) + bascule via `@Profile`/config.
- [ ] **Migration one-shot** : images BYTEA existantes → S3 ; documents disque → S3.
- [ ] **Rediriger** les services de documents générés (`DocumentStorageService`, `InvoicePdfService`, `ReceiptStorageService`, `ContactFileStorageService`) vers Object Storage.
- [ ] **Archivage froid** : partitionner les vieilles données + job d'export vers Cold Archive + rétention/lock.
- [ ] **Priorité** : Images (plus gros volume, code prévu) → Documents → Archives. (Managed DB = plus tard.)

> **Gain** : DB de nouveau petite (backups rapides, moins de RAM/disque), egress gratuit (téléchargements clients sans surprise de facture), archives à coût quasi nul (~1,3 €/To/mois).

## Ordre conseillé
**P0** (cette semaine, gain de stabilité immédiat, sans rien migrer) → **P1** (avant la revue Airbnb) → **P2** (sortir la DB + backups testés) → **P3** (alerting). La migration cloud (AWS/autre) reste une **option future** justifiée par le *scale*, **pas** par Airbnb.
