# Baitly : durcissement de production

Ce changement prépare des protections compatibles avec Cloudflare Free. Il ne les déploie pas. Les fichiers nginx sont critiques : revue de la PR requise avant fusion vers `production`. Aucun conteneur n'a été redémarré pendant la préparation.

## Protections livrées

- Refus des fichiers cachés avant la sélection des locations nginx : les extensions `.js`/`.css` ne contournent plus le refus. Exceptions limitées à ACME et à la découverte publique utilisée par Baitly/Keycloak.
- En-têtes de sécurité présents sur HTML, configuration d'exécution, assets et erreurs. La CSP autorise Turnstile ; les politiques de framing nécessaires à Keycloak sont conservées.
- IP Cloudflare IPv4 et IPv6 reconnues. Le proxy transmet une IP visiteur canonique au backend ; les en-têtes reçus du client ne servent pas de preuve d'identité.
- Limite nginx dédiée : 30 requêtes/minute par IP, burst de 10, sur les POST de login/récupération et les actions Keycloak correspondantes. Le refresh de session n'utilise pas ce quota.
- Access logs JSON avec statut, durée, pair TCP, IP visiteur et Ray ID. Les chemins libres et query strings sont retirés. Le dashboard Grafana `Baitly · Sécurité HTTP` suit les 403, 429 et 5xx via Loki. Les error logs nginx restent un canal distinct à accès restreint : nginx peut y inclure une URI lors d'erreurs upstream.
- Promtail monte son répertoire de configuration versionné. Le changement de volume et de commande sera appliqué par Compose lors du CD Deploy, ce qui charge le nouveau pipeline `http_status` ; le montage d'un fichier isolé pouvait conserver un ancien inode après le checkout Git.
- Workflow `Baitly Cloudflare Security` : une règle de fichiers sensibles, une règle de login 10 requêtes/10 secondes, blocage 10 secondes. Aucune règle existante n'est supprimée. Les quotas sont contrôlés et l'état précédent conservé 7 jours dans un artifact privé. La commande `disable` ne désactive que les deux règles Baitly.
- Protection Keycloak temporaire après 10 échecs, attente croissante jusqu'à 15 minutes, sans verrouillage permanent. Le realm d'import ne modifie pas un realm existant : utiliser le workflow dédié après revue. Les direct grants restent disponibles car l'application les utilise.

## Ordre de livraison

1. Fusionner et déployer la PR PMS associée, puis cette PR d'infrastructure, via le circuit habituel `main` → PR `production` → CD Deploy. Laisser `BAITLY_CAPTCHA_ENABLED=false` et `BAITLY_ORIGIN_LOCKDOWN=0` pendant ce premier déploiement.
2. Vérifier les parcours connexion, récupération, refresh, candidature, réservation, paiement, webhooks signés, CORS, découverte OIDC et temps réel. Les tests locaux ne remplacent pas ces smoke tests de production.
3. Fournir un widget Turnstile dont les hôtes sont exactement ceux des deux interfaces. Dans le secret CI `PROD_ENV_FILE_B64`, préparer `TURNSTILE_SECRET_KEY`, `VITE_TURNSTILE_SITE_KEY`, `TURNSTILE_ALLOWED_HOSTNAMES=app.baitly.fr,baitly.fr,www.baitly.fr` (ajouter le domaine marketing secondaire s'il est réellement utilisé), puis `BAITLY_CAPTCHA_ENABLED=true`. Ne jamais utiliser le préfixe `VITE_` pour le secret privé. Reprovisionner le fichier par le CD Deploy avec `force_env_sync`, après revue ; sans ce flag un `.env` existant n'est pas réécrit. Services concernés : `pms-server`, `pms-client`, `baitly-site` et `nginx` pour sa CSP.
4. Le préflight refuse une activation CAPTCHA partielle avant toute mutation des conteneurs. Le backend refuse aussi de démarrer avec CAPTCHA actif sans secret/hôtes. Une validation explicite refuse les tokens absents, trop longs, non validés par Cloudflare, provenant d'un hôte non autorisé ou d'une autre action. Les tokens expirés/consommés sont invalidés côté formulaire. Supprimer/faire tourner tout ancien secret Turnstile réellement utilisé qui aurait été versionné dans `application-dev.yml`.
5. Dans l'environnement GitHub `production-baitly`, ajouter le secret `CLOUDFLARE_API_TOKEN` limité à la zone Baitly (Zone Read et Zone WAF Edit) et la variable `CLOUDFLARE_ZONE_ID`. Lancer `Baitly Cloudflare Security` en `check`, examiner la configuration et les règles existantes, puis `apply`. Le workflow n'autorise les mutations que depuis `production`. Si le quota Free est occupé, il s'arrête et conserve les règles existantes. Une erreur réseau après une écriture peut laisser une activation partielle : examiner Cloudflare et l'artifact avant de relancer ; les références stables rendent la relance idempotente.
6. Lancer `Baitly Keycloak Security` d'abord en lecture, puis avec `apply` après revue. Il met à jour les seuls champs de protection brute force sur le realm `clenzy` par le workflow, sans redémarrage de conteneur.

## Origine et administration : activation conditionnelle

Avant de passer `BAITLY_ORIGIN_LOCKDOWN=1`, vérifier **tous** les DNS utilisés par les vhosts : proxy Cloudflare actif, certificat origine valide et mode TLS Full (strict). Vérifier également les sondes externes et les clients directs. Une fois cette vérification faite, ajouter `BAITLY_ORIGIN_PROXY_VERIFIED=true` à la configuration CI puis déployer nginx. L'exception HTTP ACME est limitée au chemin du challenge. L'accès direct HTTP(S) doit alors être refusé même avec de faux `CF-Connecting-IP`/`X-Forwarded-For` ; le trafic passant par Cloudflare doit continuer à fonctionner.

Cette restriction nginx vérifie le réseau source Cloudflare, **pas l'appartenance à notre compte**. Elle ne remplace ni un pare-feu réseau ni une liaison authentifiée propre au compte. Pour Access, prévoir un Tunnel, un certificat AOP dédié ou la validation des JWT Access à l'origine ; ne pas se contenter du certificat AOP global. Ne pas filtrer aveuglément les ports médias/SSH utilisés par la stack.

`baitly-access-plan.json` prépare le périmètre : Grafana, Prometheus, Kafka UI et `/admin` de Keycloak seulement. La liste d'administrateurs est volontairement vide tant que leurs emails n'ont pas été fournis. Il reste à vérifier les domaines, l'IdP/MFA et les automatisations, puis à livrer le provisioning Access par PR/CI. Un OTP email seul n'est pas la preuve MFA attendue. Ne pas protéger tous les endpoints OIDC ou tout `/api` avec un challenge interactif.

Le compte Cloudflare n'a pas été accessible pour cet audit : règles gérées Free, état TLS, DNS, événements, réglages de cache et MFA du compte restent à vérifier. Aucune activation de Bot Fight Mode ni blocage géographique n'est effectuée. Un achat de forfait n'est pas nécessaire pour les règles préparées.

## Vérification et retour arrière

`Baitly Security Regression` compile un nginx isolé depuis une archive à SHA-256 fixé et teste le template réel, sans Docker. La suite couvre les sondes encodées, les chemins de découverte, les headers, les logs, les quotas Free, la préservation des règles tierces et l'origine. Les tests Java et les builds des deux frontends sont portés par la PR PMS.

La suite résout aussi le Compose de production avec des valeurs factices via `docker compose config`, sans contacter le daemon ni démarrer de conteneur. Elle vérifie la propagation du flag CAPTCHA et de la clé publique aux deux interfaces, la présence de la clé privée uniquement côté serveur et le chemin de configuration monté de Promtail.

Retour arrière par PR/revert et CD Deploy. Pour une difficulté d'activation CAPTCHA, remettre le flag commun à `false` via la configuration CI et redéployer les trois services applicatifs ensemble. Pour le verrouillage origine, remettre le flag à `0` via CI. Le workflow Cloudflare `disable` est disponible pour ses deux règles. Les ajustements Keycloak doivent repasser par une modification revue du workflow/script. Ne pas opérer directement sur le VPS.

Après déploiement, consulter Security Events et le dashboard Grafana. Un 403 sur `.env` indique un refus ; un 200 nécessite de comparer le contenu avec le fallback SPA, sans afficher de secret. Une exposition réelle implique une rotation ciblée des secrets et une revue des accès. Aucun export de données ni compromission n'a été démontré par la capture initiale.

## Références

- [Règles personnalisées et quotas Free](https://developers.cloudflare.com/waf/custom-rules/)
- [Rate limiting et restrictions du forfait](https://developers.cloudflare.com/waf/rate-limiting-rules/)
- [Validation serveur Turnstile](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/)
- [CSP Turnstile](https://developers.cloudflare.com/turnstile/reference/content-security-policy/)
- [Chemins Access](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/)
- [MFA Access](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/)
- [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/)
- [Protection brute force Keycloak](https://www.keycloak.org/docs/latest/server_admin/index.html#password-guess-brute-force-attacks)
