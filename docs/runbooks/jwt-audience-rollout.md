# Runbook — Rollout JWT Audience Validation

> **Objectif** : activer la validation `aud` sur le decodeur JWT du backend Clenzy
> (`ProdJwtDecoderConfig`).

## Contexte

Le pentest Shannon (fevrier 2026) a recommande de valider la claim `aud` des access
tokens en plus de l'`iss` deja active. Cela protege contre le **cross-client
intra-realm** : un token legitime du realm `clenzy` mais emis pour un autre client
(ex. `clenzy-web`, `clenzy-mobile`) ne pourra plus etre reutilise pour appeler l'API
`clenzy-api`.

### Pourquoi le mapper Keycloak en prerequis

Keycloak met par defaut `aud: "account"` dans les access tokens, **pas**
`clenzy-api`. Sans le mapper Audience configure cote Keycloak, le decodeur prod
rejetterait tous les tokens.

> **Note contexte prod** : actuellement la prod n'a qu'un seul compte utilisateur
> (le compte admin). Pas de risque de lock-out massif — un rollback rapide est
> toujours possible si quelque chose foire.

---

## Etape 1 — Keycloak : ajouter le mapper Audience

> A faire **avant** le deploy du code.

### Via la console admin Keycloak

1. Se connecter sur `https://${AUTH_DOMAIN}/admin/master/console/`
   (compte `${KEYCLOAK_ADMIN}`).
2. Selectionner le realm **`clenzy`** (en haut a gauche).
3. **Clients** → **`clenzy-api`** → onglet **Client scopes** →
   ligne **`clenzy-api-dedicated`** → **Add mapper** → **By configuration** →
   **Audience**.
4. Configurer :
   - **Name** : `clenzy-api-audience`
   - **Included Client Audience** : `clenzy-api`
   - **Add to access token** : `ON`
   - **Add to ID token** : `OFF`
   - **Add to lightweight access token** : `ON` (si l'option existe)
5. **Save**.

### Verification immediate

Sur n'importe quel poste authentifie, recuperer un nouveau token et inspecter `aud` :

```bash
# Recuperer un token frais (login + capture du Bearer dans le DevTools du navigateur)
TOKEN="eyJ..."

# Decoder la partie payload (base64url, segment du milieu) :
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.aud, .iss'
# Doit afficher :
#   "clenzy-api"   (ou ["clenzy-api", "account"] selon la config)
#   "https://${AUTH_DOMAIN}/realms/clenzy"
```

Si `aud` ne contient PAS `clenzy-api` → le mapper n'est pas pris en compte,
re-verifier la config et le client scope assignment.

---

## Etape 2 — Deployer le code

> Une fois l'etape 1 validee.

1. Se deconnecter / reconnecter pour avoir un token frais avec `clenzy-api` dans `aud`
   (sinon le token actuel serait rejete apres le deploy).
2. Merger la PR sur `production` → le workflow CD Deploy se charge du deploy
   automatiquement.
3. **Verification dans les 60 secondes apres restart** :
   - Logs `pms-server` : chercher
     `"Validation JWT durcie ACTIVE : issuer + audience attendue 'clenzy-api'"`
     → confirme que `ProdJwtDecoderConfig` est bien instancie.
   - Smoke test : navigation rapide sur `https://app.clenzy.fr/`.

### Si tout va bien

Rien a faire — la validation reste active en permanence (`@Profile("prod")`).

### Si lock-out (token rejete avec 401)

Cause typique : le mapper Keycloak n'est pas en place ou tu utilises un token
emis **avant** le mapper.

Options de remediation (de la plus rapide a la moins) :
1. **Refresh du token** : se deconnecter / reconnecter pour generer un nouveau token
   avec `clenzy-api` dans `aud`. C'est suffisant 99 % du temps.
2. **Verifier le mapper** : retourner sur la console Keycloak et confirmer que le
   mapper est bien actif (cf. Etape 1).
3. **Rollback git** : `git revert <commit-sha>` du commit qui a ajoute
   `ProdJwtDecoderConfig`, push, redeploy. ~5 min total.

---

## Staging — meme procedure

Tester d'abord en staging (meme sequence Keycloak → deploy). Si OK pendant
quelques heures sans 401 anormal → declencher prod.

---

## Dev — pas concerne

En local, la chaine de securite est differente (`SecurityConfig` avec
`@Profile("!prod")`). Le bean `ProdJwtDecoderConfig` (avec son `@Profile("prod")`)
**n'est pas charge en dev**, donc rien a faire.

---

## Annexes

### Code & config

- Backend Java :
  - `server/src/main/java/com/clenzy/config/JwtAudienceValidator.java`
  - `server/src/main/java/com/clenzy/config/ProdJwtDecoderConfig.java`
  - `server/src/main/resources/application-prod.yml`
    (property `clenzy.security.jwt.expected-audience`)
- Tests :
  - `server/src/test/java/com/clenzy/config/JwtAudienceValidatorTest.java` (5 tests)
  - `server/src/test/java/com/clenzy/config/ProdJwtDecoderConfigTest.java` (3 tests)
- Infra :
  - `clenzy-infra/docker-compose.prod.yml`
    (env var `CLENZY_JWT_EXPECTED_AUDIENCE`)

### Decisions architecturales

- **Pourquoi un nouveau fichier `ProdJwtDecoderConfig` et pas une modif de
  `SecurityConfigProd` ?** Le fichier `SecurityConfigProd.java` est marque
  *review-gated* dans `CLAUDE.md` (regle de securite #8). Isoler le bean dans
  une classe dediee permet de l'ajouter sans toucher au file sensible.
- **Pourquoi pas de feature flag ?** La prod actuelle n'a qu'un seul utilisateur
  (compte admin). Le scenario "lock-out de 1000 users" qui justifierait un flag
  runtime n'existe pas. Un rollback git (~5 min) suffit pour rollback si besoin.
  YAGNI : pas de complexite inutile.
- **Pourquoi NimbusJwtDecoder et pas une nouvelle lib ?** Reste sur l'API standard
  Spring Security ; tout le reste de la chaine (Keycloak,
  BearerTokenAuthenticationFilter) fonctionne sans changement.
