# Checklist de mise en production

Deux sujets independants. Le premier est un deploiement classique, le second
ajoute un vhost et demande une sequence precise a cause du certificat.

---

## 1. Deploiement applicatif (35 commits, 7 migrations)

### Contenu

`main` porte 35 commits non deployes. Les 7 migrations Liquibase en attente
vont de `0371` a `0377`.

| Changeset | Nature | Reversible |
|---|---|---|
| `0371` deduplicate_review_reply_drafts | DML | oui |
| `0372` create_action_items | CREATE TABLE | oui |
| `0373` online_checkin_identity_fields | ADD COLUMN | oui |
| `0374` ota_fee_bearer_and_payout_ota_fees | ADD COLUMN | oui |
| `0375` drop_activity_commission_config | DROP COLUMN x2 | **non** (archive) |
| `0376` add_affiliate_platform_commission | ADD COLUMN | oui |
| `0377` drop_contract_activity_commission_rate | DROP COLUMN | **non** (archive) |

`0375` et `0377` suppriment des colonnes. Les valeurs non nulles sont copiees
dans `archived_activity_commission_rates` avant le `DROP` : aucune perte, mais
la colonne elle-meme ne revient pas sans nouveau changeset.

### Avant

- [ ] `mvn package` vert (13 265 tests au dernier passage)
- [ ] `npm run build` vert cote client
- [ ] PR `main -> production` sur `clenzy`, checks requis verts :
      Security, immutable-changesets, validate-structure
- [ ] PR `main -> production` sur `clenzy-infra` (1 commit : config Channex dev)

### Deploiement

- [ ] Merger la PR `clenzy` (`gh pr merge <n> --merge`) — declenche CD Deploy
- [ ] Les migrations s'appliquent **automatiquement au boot** de `pms-server`
      (`SPRING_LIQUIBASE_ENABLED=true` est un invariant prod). Aucun
      `workflow_dispatch` ni Liquibase Bootstrap requis.

### Apres

- [ ] `pms-server-prod` healthy
- [ ] Verifier `archived_activity_commission_rates` : si elle contient des
      lignes, des organisations avaient saisi des taux d'activites. Ils
      n'etaient appliques par aucun code, mais la table dit lesquels.
- [ ] Ecran Parametres > Paiement : l'onglet « Repartition des revenus »
      charge ses deux onglets sans erreur (endpoints `commissions/overview` et
      `activities/configs`).
- [ ] Import CSV : tester avec un export reel d'un programme d'affiliation.
      Le parseur echoue bruyamment si les colonnes de reference et de montant
      manquent — c'est voulu.

### Non couvert par ce deploiement

- Les deux clients de catalogue (Viator, GetYourGuide) n'ont jamais appele
  l'API reelle. Premier appel avec une vraie cle = premiere validation.
- `Reservation.otaFeeAmount` n'est toujours alimente par aucun import : les
  marges affichees restent surevaluees d'environ 15,5 % sur les reservations
  Airbnb.

---

## 2. Site marketing Baitly (nouveau vhost)

### Ce qui est pret dans le repo

- `clenzy/client/Dockerfile.site` — build `npm run build:site` (sortie
  `dist-site`), servi par nginx. Build valide localement.
- `docker-compose.prod.yml` — service `baitly-site`, image
  `ghcr.io/mazy06/clenzy-baitly-site:latest`, variable `SITE_DOMAIN`
  (defaut `baitly.ma`) et `SITE_DOMAIN` ajoute a `NGINX_ENVSUBST_FILTER`.
- `nginx/nginx.conf.template` — vhost `${SITE_DOMAIN}` + `www`, et le domaine
  ajoute au bloc ACME pour que le challenge HTTP-01 reponde. Syntaxe validee
  par `nginx -t`.

### Sequence — l'ordre compte

1. [ ] **Fixer le domaine** dans le `.env` du VPS : `SITE_DOMAIN=baitly.io`
       (choisi le 2026-08-29 ; le domaine reste a acquerir aupres d'un
       registrar). Le defaut du compose — volontairement `baitly.ma`, une
       valeur fausse — ne doit pas servir de decision.
2. [ ] **DNS** : `SITE_DOMAIN` et `www.SITE_DOMAIN` vers l'IP du VPS.
       A faire **avant** certbot, sinon le challenge echoue.
3. [ ] **Deployer** le service et la config nginx. A ce stade le site repond
       en HTTPS mais avec un certificat qui ne couvre pas le domaine : les
       navigateurs affichent un avertissement. nginx demarre normalement —
       le certificat SAN existe, il est juste incomplet.
4. [ ] **Etendre le certificat** au nouveau domaine (`certbot --expand`, meme
       `CERTBOT_CERT_NAME` que les autres vhosts), puis recharger nginx.
5. [ ] Verifier `https://SITE_DOMAIN/health` -> `healthy`, et le site en racine.

### Points a decider

- **Image GHCR** : `clenzy-baitly-site` n'existe pas encore. Le premier
  deploiement doit la construire et la pousser — verifier que le pipeline de
  build d'images la prend en compte, sinon `docker compose pull` echouera.
- **Redirection HTTP -> HTTPS** : le bloc port 80 existant redirige les
  domaines qu'il connait. `SITE_DOMAIN` y a ete ajoute pour l'ACME ; verifier
  au deploiement que la redirection s'applique bien au nouveau domaine.
- **Contenu** : le site est une app Vite dans `client/site`. Rien ne dit ici
  s'il est pret a etre publie — c'est une decision produit, pas technique.
