# HANDOFF — Déploiement prod du runtime CopilotKit (`copilot-runtime`)

> **Statut : DRAFT — rien n'est committé, poussé, déployé.** Ce document récapitule
> les fichiers préparés et l'ordre de déploiement pour atteindre la parité prod/local
> (mission #5). Aujourd'hui le runtime Node n'existe qu'en **dev** → la page
> `/agui-spike` casse en **prod** (l'appel `/api/copilotkit` n'a aucun upstream).

## 1. Topologie découverte

```
Front CopilotKit (app.clenzy.fr, /agui-spike)
   │  fetch /api/copilotkit  (MÊME ORIGINE → cookie HttpOnly clenzy_auth + Bearer)
   ▼
nginx (app.clenzy.fr)  ── location /api/copilotkit ──►  copilot-runtime:8080   [NOUVEAU service]
   │                                                          │ relaie SSE (factory per-requête,
   │  location /api/  ────────────────────────────►          │  Authorization + Cookie)
   ▼                                                          ▼
clenzy-server:8080  ◄──────────  POST /api/agui/run  ◄──────  copilot-runtime
(AgUiController, SSE TEXT_EVENT_STREAM, moteur multi-agent)
```

- **Runtime** : `clenzy/copilot-runtime/server.mjs` — Express + `@copilotkit/runtime/v2`,
  écoute `PORT` (8080), monte `COPILOT_BASE_PATH` (`/api/copilotkit`), relaie vers
  `AGUI_BACKEND_URL` (`http://clenzy-server:8080/api/agui/run`). Auth relayée par la
  factory `agents: ({ request }) => …` (pas de partage d'en-têtes entre users). Expose
  aussi `GET /health`.
- **Front** : `client/src/modules/supervision/agui/SupervisionAgUiSpike.tsx` —
  `RUNTIME_URL = import.meta.env.VITE_COPILOT_RUNTIME_URL || '/api/copilotkit'`. En prod
  la variable n'est PAS définie → repli relatif `/api/copilotkit` (même origine, nginx).
  **=> Aucun changement frontend / aucun nouveau build-arg requis.**
- **Dev (modèle)** : service `copilot-runtime` dans `clenzy-infra/docker-compose.dev.yml`
  (build `Dockerfile.dev`, port `8087:8080`, env `COPILOT_ALLOWED_ORIGIN`,
  `AGUI_BACKEND_URL`, alias réseau `copilot-runtime`, `depends_on: pms-server`). En dev
  le front passe par le proxy Vite (`vite.config.ts` → `/api/copilotkit` →
  `http://copilot-runtime:8080`).
- **Prod existant** : `pms-server` / `pms-client` = image GHCR `ghcr.io/mazy06/clenzy-*:latest`
  + bloc `build` (context `../clenzy/...`), `restart: unless-stopped`, réseau
  `clenzy-network` (alias `clenzy-server` / `clenzy-frontend`), `expose` (pas de port publié).
- **CI** : `clenzy/.github/workflows/ci-{frontend,backend}.yml` → job `docker-push`
  (GHCR `:latest` sur `production`) → job `deploy` = `repository_dispatch` vers
  `clenzy-infra` (`deploy-clenzy-frontend|backend`, `client-payload.service`).
- **CD** : `clenzy-infra/.github/workflows/cd-deploy.yml` reçoit le dispatch, SSH sur le
  VPS, `git reset --hard origin/production` (infra **et** `../clenzy`), puis
  `scripts/deploy.sh`. Le payload `service` → `DEPLOY_SERVICES` → la branche
  « per-service » fait `docker compose pull <svc> && up -d <svc>`. **nginx est
  force-recreate à CHAQUE deploy** (hors branche, étape 4) → la config nginx en vigueur
  est celle de `origin/production` au moment du deploy.

## 2. Fichiers préparés (drafts)

### Repo `clenzy`
| Fichier | Action | Clé |
|---|---|---|
| `copilot-runtime/Dockerfile` | **Modifié** | `npm ci --omit=dev` (déterministe, lockfile) + retries réseau + `HEALTHCHECK /health`. (Avant : `npm install --omit=dev`.) |
| `copilot-runtime/.dockerignore` | **Créé** | Exclut `node_modules` local (binaires Linux réinstallés), `.git`, Dockerfiles, logs. |
| `.github/workflows/ci-copilot-runtime.yml` | **Créé** | Miroir de `ci-frontend.yml` : `npm ci` + `node --check server.mjs` → build/push GHCR `clenzy-copilot-runtime` → `repository_dispatch` (`deploy-service`, `service: copilot-runtime`). |

> ⚠️ **`copilot-runtime/` n'est PAS encore suivi par git** (`git status` = `?? copilot-runtime/`).
> Il faut `git add copilot-runtime/` (le `.gitignore` exclut déjà `node_modules`). Sans
> ce commit, ni la CI ni le build VPS (full-rebuild) ne verront la source. **Vérifier
> que `package-lock.json` est bien committé** (présent sur disque) — requis par `npm ci`.

### Repo `clenzy-infra`
| Fichier | Action | Clé |
|---|---|---|
| `docker-compose.prod.yml` | **Modifié** | Nouveau service `copilot-runtime` (image GHCR `:latest` + `build`, env prod, `expose 8080`, `restart`, alias réseau `copilot-runtime`, `depends_on: pms-server`). MIRROR de `pms-server`. |
| `nginx/nginx.conf.template` | **Modifié** | Bloc `location /api/copilotkit` (avant `/api/`) → `http://copilot-runtime:8080`, **SSE** (`proxy_buffering off`, `proxy_read_timeout 600s`, `X-Accel-Buffering no`, HTTP/1.1). |
| `HANDOFF_COPILOT_RUNTIME_PROD.md` | **Créé** | Ce document. |

Extrait compose (clé) :
```yaml
copilot-runtime:
  image: ghcr.io/mazy06/clenzy-copilot-runtime:latest
  build: { context: ../clenzy/copilot-runtime, dockerfile: Dockerfile }
  environment:
    PORT: 8080
    COPILOT_ALLOWED_ORIGIN: https://${APP_DOMAIN}
    AGUI_BACKEND_URL: http://clenzy-server:8080/api/agui/run
  expose: ["8080"]
  depends_on: { pms-server: { condition: service_started } }
  networks: { clenzy-network: { aliases: [copilot-runtime] } }
```

Extrait nginx (clé) :
```nginx
location /api/copilotkit {
    set $copilot_runtime_upstream http://copilot-runtime:8080;
    proxy_pass $copilot_runtime_upstream;
    proxy_http_version 1.1;
    proxy_buffering off;            # SSE : sinon le front ne reçoit rien avant la fin
    proxy_read_timeout 600s;        # run multi-agent + HITL (SseEmitter Java borné 5 min)
    add_header X-Accel-Buffering no;
    # ... + X-Forwarded-*, Connection "", limit_req zone=api
}
```

## 3. Env / secrets requis

**Aucun nouveau secret applicatif.** Le runtime ne tient pas de clé : il relaie le
JWT/cookie entrant. Variables (déjà présentes en prod) :

| Variable | Où | Valeur prod | Déjà dispo ? |
|---|---|---|---|
| `APP_DOMAIN` | `.env` infra | `app.clenzy.fr` | ✅ (utilisée partout) |
| `PORT` | compose (hardcodé) | `8080` | n/a |
| `AGUI_BACKEND_URL` | compose (hardcodé) | `http://clenzy-server:8080/api/agui/run` | ✅ (alias réseau existant) |
| `INFRA_REPO_DISPATCH_TOKEN` | secret CI `clenzy` | (token dispatch) | ✅ (déjà utilisé par front/back) |
| `GHCR_TOKEN`, `VPS_*`, `PROD_ENV_FILE_B64` | secrets CI `clenzy-infra` | — | ✅ |

> **GHCR / package** : la première CI sur `production` créera le package
> `ghcr.io/mazy06/clenzy-copilot-runtime`. Vérifier ensuite sa **visibilité** : si le
> package est `private`, le VPS doit pouvoir le `docker pull` (il s'authentifie déjà via
> `GHCR_TOKEN` dans `cd-deploy.yml`, donc OK tant que le token a le scope `read:packages`
> sur l'org). Le mettre `public` ou confirmer le scope du token.

## 4. Ordre de déploiement recommandé

> Contrainte clé : **nginx est force-recreate à chaque deploy** depuis `origin/production`.
> Il ne faut PAS reloader une config nginx qui référence `copilot-runtime` avant que le
> service tourne — sinon nginx peut refuser de (re)charger (`host not found in upstream`).
> Le pattern `set $var ... resolver` du fichier **tolère** un upstream absent au reload
> (résolution paresseuse à la requête → 502 sur `/api/copilotkit` seulement, pas de crash
> nginx global). Malgré ça, on déploie le service AVANT/AVEC la route.

1. **Commit `clenzy`** : `git add copilot-runtime/ .github/workflows/ci-copilot-runtime.yml`
   sur `main` (le `copilot-runtime/` doit entrer dans git). Vérifier `package-lock.json` inclus.
2. **PR `clenzy` `main → production`** : au merge, `ci-copilot-runtime.yml` build+push
   `ghcr.io/mazy06/clenzy-copilot-runtime:latest` PUIS déclenche `deploy-service`
   (`service: copilot-runtime`). Le CD fait `pull copilot-runtime && up -d copilot-runtime`.
   → Le conteneur tourne. (À ce stade nginx n'a pas encore la route → `/api/copilotkit`
   répondrait 404 via le bloc `/api/` qui le route au backend Java ; sans gravité.)
3. **Commit + PR `clenzy-infra` `main → production`** (compose + nginx) : au merge, le CD
   se déclenche (paths `docker-compose.prod.yml` + `nginx/**`), recrée nginx avec la route
   et (re)démarre `copilot-runtime` via le compose mis à jour.
   - **Alternative en un temps** : merger d'abord `clenzy-infra` (compose+nginx) en prod,
     puis `clenzy` — mais alors nginx route vers un upstream pas encore up jusqu'au step
     suivant (502 transitoire sur `/agui-spike`). L'ordre 1→2→3 ci-dessus minimise la fenêtre.
4. **Vérif post-deploy** (voir §6).

> Les PR `main → production` sur `clenzy` ET `clenzy-infra` sont toutes deux requises
> (les triggers de deploy ne tirent que sur `production`).

## 5. Risques

- **`copilot-runtime/` non versionné** : RISQUE BLOQUANT si oublié — la CI checkout
  `production` ne trouverait pas le dossier (job `docker-push` échoue sur context vide).
  → Le `git add` du step 1 est obligatoire.
- **Visibilité du package GHCR** : un package privé non lisible par le token VPS ⇒
  `pull` échoue au CD. Mitigation : token scope `read:packages` (déjà le cas pour
  `clenzy-server`/`clenzy-client`) ou package public.
- **SSE bufferisé** : si `proxy_buffering off` est oublié, le front ne reçoit les events
  qu'à la fin du run (UX cassée mais pas d'erreur dure). Couvert par le draft nginx.
- **Cloudflare devant app.clenzy.fr** : CF peut bufferiser/timeouter le SSE. Le SSE
  `/api/agui` existant passe déjà par CF aujourd'hui via le bloc `/api/` (assistant chat),
  donc le chemin est validé en pratique. À surveiller si runs > timeout CF (100s par
  défaut sur le plan gratuit pour une réponse sans premier byte — or le SSE émet vite
  `RUN_STARTED`, ce qui ouvre le flux).
- **`depends_on: pms-server`** : `condition: service_started` (pas `healthy`) — le runtime
  peut démarrer avant que le backend soit prêt, mais comme il ne contacte le backend
  qu'à la 1re requête, c'est sans conséquence.
- **`event-type: deploy-service`** (choisi au lieu d'un type dédié `deploy-clenzy-copilot`) :
  déjà déclaré dans `cd-deploy.yml` (`repository_dispatch.types`). Pas besoin de modifier
  le CD infra. Le mapping `service → DEPLOY_SERVICES` route correctement vers la branche
  per-service de `deploy.sh`.

## 6. À valider avant un vrai déploiement

- [ ] `git add copilot-runtime/` effectué (dossier versionné, `package-lock.json` inclus).
- [ ] CI `ci-copilot-runtime.yml` verte sur une PR (job `install-and-check`).
- [ ] Package `ghcr.io/mazy06/clenzy-copilot-runtime` créé + lisible par le token VPS.
- [ ] Après deploy : `docker compose -f docker-compose.prod.yml ps copilot-runtime` = `running`.
- [ ] `docker exec clenzy-copilot-runtime-prod wget -qO- http://localhost:8080/health` → `{"status":"ok",...}`.
- [ ] Depuis le VPS : `curl -sN https://app.clenzy.fr/api/copilotkit/...` (ou via l'UI) →
      la page `/agui-spike` charge et stream les events (pas de 502 / pas de buffering).
- [ ] `nginx -t` OK au reload (logs `clenzy-nginx-prod`), pas de `host not found in upstream`.
- [ ] Confirmer que `COPILOT_BASE_PATH` par défaut (`/api/copilotkit`) correspond bien au
      `basePath` attendu par le client `@copilotkit/react-core/v2` (déjà le cas en dev).

## 7. Ce qui N'A PAS été touché (volontairement)

- Aucun build-arg frontend (le repli `/api/copilotkit` suffit en prod).
- `docker-compose.dev.yml` (le service dev existe déjà, c'est le modèle).
- `cd-deploy.yml` / `deploy.sh` infra (le type `deploy-service` et le mapping per-service
  existent déjà — réutilisés tels quels).
- CSP nginx : `connect-src 'self'` couvre déjà l'appel same-origin `/api/copilotkit`.
- Aucun secret applicatif ajouté.
