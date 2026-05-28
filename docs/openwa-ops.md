# OpenWA — Guide ops

Tout ce qu'il faut savoir pour maintenir l'instance OpenWA en dev (et plus tard en prod) :
setup, démarrage, troubleshooting, rotation des clés, gestion des sessions WhatsApp.

> ⚠️ **OpenWA est hors ToS Meta** (whatsapp-web.js = reverse-engineering du protocole Web).
> Réservé aux organisations en trial / MVP. Cf. `clenzy/docs/adr/0001-whatsapp-provider-strategy.md`.

---

## Setup initial

```bash
# 1. Auto-setup (clone OpenWA dans ./openwa/ + génère OPENWA_API_MASTER_KEY)
./scripts/setup-openwa.sh

# 2. Démarrer (start-dev.sh active le profile openwa automatiquement)
./start-dev.sh
```

C'est tout. Le container `clenzy-openwa-dev` tourne sur le port 2785 avec :
- Dashboard React + Swagger : http://localhost:2785/api/docs
- Sessions WhatsApp persistées dans le volume `openwa-data-dev`
- Auth interne via `OPENWA_API_MASTER_KEY` (généré aléatoirement, dans `.env.dev`)

---

## Vérifier que ça tourne

```bash
# Status container
docker ps --filter name=clenzy-openwa-dev

# Healthcheck
curl http://localhost:2785/api/health
# → {"status":"ok"}

# Logs en temps réel
docker logs -f clenzy-openwa-dev
```

---

## Workflow utilisateur (créer une session WhatsApp pour une org)

**Côté Clenzy** (recommandé) :
1. Settings > Messagerie > section "Provider WhatsApp"
2. Sélectionner "OpenWA" (cards radio à droite)
3. Cliquer "Scanner le QR code"
4. Scanner avec WhatsApp téléphone (Paramètres > Appareils connectés)
5. Une fois connecté : le toggle "Activer" devient utilisable

**Côté Swagger** (admin / debug uniquement) :
1. http://localhost:2785/api/docs
2. Auth : header `X-API-Key: <OPENWA_API_MASTER_KEY>` (récup depuis `.env.dev`)
3. POST `/api/sessions` avec `{sessionId, apiKey}` → crée la session
4. GET `/api/sessions/{id}/qr` → récupère le QR base64
5. GET `/api/sessions/{id}/status` → polling jusqu'à `CONNECTED`

---

## Troubleshooting

### Le container ne démarre pas

```bash
docker logs clenzy-openwa-dev | tail -50
```

**Cause #1 — OPENWA_API_MASTER_KEY manquante** :
```
Error: API_MASTER_KEY required
```
Fix : relancer `./scripts/setup-openwa.sh`

**Cause #2 — Port 2785 déjà utilisé** :
```
Error: bind: address already in use
```
Fix : `lsof -i :2785` puis kill le process, ou changer `OPENWA_PORT` dans `.env.dev` et docker-compose.

**Cause #3 — Chromium crash au boot** :
```
Failed to launch the browser process
```
Fix : `docker compose --profile openwa restart openwa`. Si récurrent : `docker compose --profile openwa down openwa && docker volume rm clenzy-infra_openwa-data-dev` (perte des sessions WhatsApp — re-scan QR obligatoire).

### Session WhatsApp déconnectée

**Symptômes** : status passe à `DISCONNECTED` / `FAILED`, les envois échouent.

**Causes possibles** :
- L'utilisateur a déconnecté WhatsApp Web depuis son téléphone (Paramètres > Appareils connectés > Déconnecter)
- Le téléphone est éteint depuis > 14 jours (WhatsApp invalide la session)
- Detection automation par Meta (ban temporaire ou définitif)

**Fix** : l'user retourne dans Clenzy > Settings > Messagerie > "Re-scanner le QR code". Le bouton DELETE l'ancienne session + en crée une nouvelle + affiche le nouveau QR.

### Pms-server n'arrive pas à joindre OpenWA

```
Echec creation session OpenWA pour org X: Connection refused
```

**Cause** : `OPENWA_BASE_URL` mal configurée OU container openwa pas démarré.

**Fix** :
1. Vérifier que `openwa` est dans le même réseau Docker : `docker network inspect clenzy-network | grep openwa`
2. Depuis pms-server : `docker exec clenzy-server-dev curl http://openwa:2785/api/health`
3. Si KO : `docker compose -f docker-compose.dev.yml --env-file .env.dev --profile openwa up -d openwa`

### Rate limit atteint (20 msg/min)

OpenWA bloque les envois au-delà de 20 msg/min ou 200/h **par session WhatsApp** pour éviter le ban.

**Symptômes** : retour HTTP 429 sur send-text, message dans guest_message_log avec status=FAILED.

**Fix** : c'est by design (safeguard anti-ban). Pour des envois en burst (ex: confirmations de 30 résas), patienter ou switcher la org sur Meta.

---

## Rotation OPENWA_API_MASTER_KEY

Si la master key est compromise (leak en git, log, etc.) :

```bash
# 1. Génère une nouvelle clé
NEW_KEY=$(openssl rand -hex 32)
echo "Nouvelle clé : $NEW_KEY"

# 2. Update .env.dev
sed -i '' "s|^OPENWA_API_MASTER_KEY=.*|OPENWA_API_MASTER_KEY=${NEW_KEY}|" .env.dev

# 3. Restart le container (la clé est lue au boot)
docker compose -f docker-compose.dev.yml --env-file .env.dev --profile openwa restart openwa

# 4. Restart le pms-server (il a aussi besoin de la clé pour les calls admin)
docker compose -f docker-compose.dev.yml --env-file .env.dev restart pms-server
```

⚠️ **Les API keys per-session existantes restent valides** — seule la master key (utilisée pour créer/supprimer des sessions) change. Pas besoin de re-scanner les QR des orgs déjà connectées.

---

## Reset complet (dev only)

Pour repartir d'un état propre (toutes sessions perdues) :

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev --profile openwa down -v openwa
# `-v` supprime aussi le volume openwa-data-dev (sessions WhatsApp + DB SQLite)
```

---

## Activation en production

Pas encore fait — Phase 5b (en attente avenant CGV + validation staging).

Checklist avant activation prod :
- [ ] Avenant CGV signé par les orgs sur OPENWA (reconnaissance hors ToS Meta)
- [ ] Service `openwa` ajouté dans `docker-compose.prod.yml` (PR séparée)
- [ ] Volume persistant configuré (sinon perte des sessions au moindre restart)
- [ ] Monitoring : alerte Prometheus si > 5 sessions FAILED en 1h
- [ ] Backup hebdomadaire du volume `openwa-data-prod` (sessions WhatsApp = critiques)
- [ ] Test charge : envoi de 200 messages sur 1h sans ban WhatsApp

---

## Références

- ADR : `clenzy/docs/adr/0001-whatsapp-provider-strategy.md`
- Repo OpenWA : https://github.com/rmyndharis/OpenWA
- Doc whatsapp-web.js : https://docs.wwebjs.dev/
- Risk management OpenWA : `./openwa/docs/16-risk-management.md` (après clone)
