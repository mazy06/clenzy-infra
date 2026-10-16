# CI/CD Baitly IoT

Le déploiement est en attente. Aucun VPS n'est commandé par ces fichiers. La CI
vérifie le code ; elle ne provisionne aucune machine et ne déclenche aucun déploiement.

## Séparation des workflows

- Application : `.github/workflows/ci-baitly-iot.yml` dans le dépôt `clenzy`.
  Tests PostgreSQL et MQTT/TLS réels, migrations Liquibase empaquetées exécutées deux
  fois, audit des dépendances bloquant. Un push sur `main` produit une archive liée
  au SHA, avec manifeste SHA-256. Aucun dispatch vers l'infrastructure.
- Infrastructure : `.github/workflows/ci-baitly-iot-infra.yml`.
  Tests des contrats de sécurité et du parcours simulé avec doublures, vérification
  systemd et test nftables dans un espace réseau Linux jetable. Aucun secret de staging.
- Déploiement futur : `.github/workflows/baitly-iot-staging.yml`.
  Lancement manuel uniquement depuis `main`, variable `IOT_STAGING_DEPLOY_ENABLED=true`,
  confirmation `DEPLOY IOT STAGING` et environnement GitHub `iot-staging`.
  Laisser la variable absente ou à `false` tant que le déploiement est en attente.
  Configurer une approbation obligatoire sur cet environnement avant son activation.

Le déploiement accepte seulement un run applicatif terminé avec succès, issu d'un
push sur `main` du dépôt attendu, avec le workflow, le numéro de run et le SHA
complet correspondants. Le succès du run inclut l'audit des dépendances. L'installateur
revérifie le manifeste entier et refuse les fichiers supplémentaires, manquants,
modifiés, les liens symboliques et les chemins sortant de l'archive.

## Cible et frontières réseau

Une **VM dédiée Ubuntu 24.04**, distincte du PMS et de sa base, est nécessaire.
L'installateur refuse l'identifiant machine du PMS et les hôtes avec socket Docker.
Il utilise des services natifs dédiés et ne manipule aucun conteneur existant.

| Accès | Règle |
| --- | --- |
| SSH | Port configuré ; clé et empreinte hôte épinglées |
| MQTT appareils | 8883, certificat client par appareil, ACL par empreinte |
| HTTPS mesures | 443, uniquement la route d'ingestion autorisée |
| API de gestion | 8444, source IPv4 du PMS seulement, TLS et secret de service |
| Récepteur et broker interne | Boucle locale, 8095 / 8096 / 8884 |
| PostgreSQL IoT | Boucle locale, base et rôles propres à l'IoT |
| IoT vers PMS / base métier | Connexions initiées bloquées par nftables |
| Utilisateurs runtime, broker, proxy | Toute nouvelle connexion hors hôte bloquée, IPv4 et IPv6 |

Le trafic de réponse et la boucle locale restent autorisés. La vérification réseau
exige un témoin positif local et l'incrément d'un compteur de rejet pour chacune des
neuf connexions interdites ; un simple délai d'attente ne suffit pas à valider l'isolation.
Le compte d'installation privilégié reste une identité d'administration distincte.

Liquibase s'exécute avec un rôle de migration via `IotMigrationMain`, sans démarrer
de serveur HTTP. Le fichier privé contenant ses identifiants est supprimé ensuite.
Le processus runtime reçoit seulement son rôle SQL restreint et ne lance pas Liquibase.
Les invariants Liquibase/Hibernate du PMS existant ne sont pas modifiés.

## Préparation future, après décision de reprendre

Variables de l'environnement `iot-staging` :

- `IOT_HOST`, `IOT_USER`, `IOT_SSH_PORT` (22 par défaut).
- `PMS_IP`, `PMS_DATABASE_IP` : IPv4 effectivement utilisées pour les connexions.
- `PMS_MACHINE_ID` : identifiant machine exact du PMS, 32 caractères hexadécimaux.
- `IOT_MQTT_HOST` : nom couvert par le certificat serveur.
- `IOT_TEST_PROPERTY_ID` : logement de staging dédié aux tests synthétiques.

Secrets du même environnement :

- `IOT_APP_READ_TOKEN` : lecture des runs et artefacts du dépôt applicatif seulement.
- `IOT_SSH_KEY`, `IOT_KNOWN_HOSTS` : identité d'installation dédiée et empreinte vérifiée.
- `IOT_SERVICE_TOKEN`, `IOT_STORE_PASSWORD` : 32 à 128 caractères alphanumériques, `_` ou `-`.
- `IOT_RUNTIME_TLS_B64` : archive tar.gz encodée en base64, contenant exactement
  `server.crt`, `server.key`, `server-ca.crt`, `devices-ca.crt`, `ingestion-ca.crt`,
  `ingestor.p12`. Certificat serveur avec SAN du domaine et de `localhost` ;
  identité récepteur signée par la CA d'ingestion ; mot de passe correspondant au secret.
- `IOT_STAGING_PMS_TOKEN` : compte de test autorisé sur le logement choisi.
- `IOT_DEVICE_CA_CERT`, `IOT_DEVICE_CA_KEY`, `IOT_SERVER_CA_CERT` : signature temporaire
  du seul simulateur dans le runner. La clé de signature n'est jamais livrée à la VM,
  ni transmise au processus du simulateur.

Les CA appareils et ingestion doivent être distinctes. Les certificats de démonstration
produits par `init-test` ne sont pas destinés à une exposition publique. Le certificat
HTTPS doit être reconnu par le PMS ; sa chaîne de confiance et son renouvellement
doivent être préparés avant l'activation.

Le PMS staging doit déjà contenir l'intégration applicative et sa migration 0561.
Configurer ultérieurement, via son propre CI/CD, `BAITLY_IOT_BASE_URL` vers
`https://<domaine-iot>:8444` et le secret `BAITLY_IOT_SERVICE_TOKEN` correspondant.
Ce workflow ne modifie ni le PMS ni sa base. La qualification cible exclusivement
`https://app.clenzy.fr/api`, le staging historique, et refuse les redirections.

Le premier lancement nécessitera `bootstrap=true`. Les suivants utilisent la même
VM avec `bootstrap=false`. Les scripts ne créent aucun VPS ni enregistrement DNS.

## Qualification et reprise

Après un futur déploiement, le workflow créera un simulateur explicitement identifié,
enverra une mesure MQTT, rejouera le même événement, vérifiera l'historique dans le
PMS, puis la révocation et le nettoyage. Les mesures synthétiques restent exclues
des alertes métier. Un appareil physique n'est jamais utilisé pour cette qualification.

Les rapports `network-qualification.json` et `mqtt-staging-qualification.json`
sont conservés comme artefacts, sans secrets. Leur absence ou l'échec d'une étape
ne constitue pas une qualification réussie. Il n'y a pas de rollback automatique
du schéma ni des services : une reprise passe par un nouveau run approuvé avec un
artefact compatible. Sauvegardes, restauration, rétention et renouvellement des
certificats restent à qualifier avant une exploitation avec appareils réels.

## Vérifications locales sans déploiement

```sh
rtk proxy python3 -m pip install -r iot/test-requirements.txt
rtk proxy python3 -m unittest discover -s iot/tests -v
rtk proxy actionlint -shellcheck= -pyflakes= .github/workflows/baitly-iot-staging.yml .github/workflows/ci-baitly-iot-infra.yml
```

Ces commandes ne contactent ni SSH ni le PMS. Les tests d'orchestration remplacent
ces accès par des doublures. Les tests réels Java/MQTT utilisent un cluster PostgreSQL
et un broker jetables, comme décrit dans `baitly-iot/README.md` du dépôt applicatif.

Sur le Mac de préparation : tests Python, tests réels MQTT/TLS, compilation Java,
double exécution du job Liquibase et validation actionlint vérifiés. Les contrôles
systemd/nftables sont réservés au job Linux ; aucun run GitHub, déploiement ou test
staging n'a été lancé. L'audit NVD reste exécuté et bloquant dans la CI applicative.
