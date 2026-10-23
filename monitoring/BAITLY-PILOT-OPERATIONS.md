# Baitly : alertes opérationnelles du pilote France

## État des préparations au 23 octobre 2026

Les quatre alertes historiques sont conservées et douze règles pilote sont ajoutées.
Une extension de quatre règles de reprise est préparée, soit vingt règles après
intégration. Elle dépend du backend [#495](https://github.com/mazy06/clenzy/pull/495)
et n’est pas déclarée livrée ni qualifiée en staging. Les seuils proposés doivent
être calibrés sur le pilote ; aucune notification réelle n’est envoyée par la CI.
Les validations locales figurent ci-dessous ; les preuves de livraison et de recette
distante doivent être rattachées aux runs CI/CD et aux SHA livrés. Aucun secret,
cookie, identifiant client ou contenu métier ne figure dans les fixtures.

Le moniteur Sentry staging est actif :
[disponibilité API](https://baitly-ye.sentry.io/monitors/2492391/?project=4512297107914832).
GET public `/api/health`, chaque minute, timeout 5 s, incident après trois échecs,
rétablissement après un succès. Sentry affiche 100 % et 150 ms lors de la
vérification initiale. L’alerte email projet 1402836 couvre toute nouvelle issue
de staging, sans filtre de type. Aucun incident de disponibilité n’a été provoqué
et aucun nouvel email de panne n’a donc été qualifié.

Cette sonde prouve la disponibilité HTTP du processus ; elle ne prouve pas la
disponibilité de la base ni le bon déroulement d’un paiement. Les données de
sonde peuvent être hébergées hors de la région EU, conformément à l’accord
explicite obtenu pour ce moniteur. Aucune sonde de production n’est ajoutée ici.

## Dépendances de livraison

1. Livrer d’abord le backend qui expose `baitly_ops_*` et accepte les nouveaux noms
   de règles. Son collecteur doit atteindre `baitly_ops_snapshot_healthy = 1` et
   un timestamp de succès récent sur l’Actuator interne.
   Pour l’extension de reprise : livrer aussi #495, avec les huit jauges
   `baitly_recovery_*`. Chaque réplique doit les exposer ; un seul backend à jour
   ne suffit pas à valider un déploiement partiel. L’échantillon de reprise doit
   être sain et âgé de moins de 180 secondes, les six agrégats présents et positifs ou nuls.
2. Intégrer et déployer ensuite ces règles infra via PR/CI/CD en staging. Sinon,
   l’absence des nouvelles métriques déclenchera légitimement une alerte.
3. Vérifier la présence des 20 règles après intégration et l’état des cibles dans Prometheus.
   L’absence de trafic ne valide ni les 5xx ni la latence.
4. Qualifier une notification synthétique `firing` puis `resolved`, avec seulement
   un nom de règle autorisé et sa sévérité : vérifier la notification staff et
   les deux compteurs `baitly_ops_alerts_received_total`. Ne pas provoquer de
   panne publique ni désactiver une intégration métier.
5. Promouvoir par le circuit PR/CI/CD après validation staging. Aucun changement
   manuel d’état, SQL ou redémarrage de conteneur n’est prescrit par ce guide.

Avant de charger les nouvelles règles, le CD exige que les jauges backend soient
présentes, valides et fraîches. Il valide les configurations, envoie seulement SIGHUP aux deux processus de
monitoring puis vérifie les timestamps de relecture et les heures de démarrage
inchangées. Cette opération est une relecture à chaud, sans stop/restart/recreate.
Références officielles : [Prometheus](https://prometheus.io/docs/prometheus/latest/management_api/)
et [Alertmanager](https://prometheus.io/docs/alerting/latest/configuration/).

Après le CD, lancer `Baitly pilot staging qualification` sur `main` avec le SHA
backend livré. Par défaut, le workflow ne fait que vérifier versions, agrégats et
règles. `send_canary=true` exige l’autorisation explicite d’envoyer deux
notifications internes aux SUPER_ADMIN/SUPER_MANAGER actifs du staging, dont les
préférences OPS sont actives. Cette option teste firing/resolved ; elle refuse d’envoyer
un canari si `APP_DOMAIN` n’est pas `app.clenzy.fr`. L’alerte de recette est
`BaitlyPilotCanary_<identifiant éphémère>` : le récepteur la ramène volontairement
au nom générique `MonitoringAlert`, avec sévérité info. Aucun identifiant client
ni secret n’est envoyé. Le rétablissement est envoyé même en cas d’échec de test ;
le canari expire automatiquement après 10 minutes comme filet de sécurité.
La recette exige également une augmentation du nombre de notifications OPS_ALERT
correspondantes enregistrées en base, via un SELECT agrégé sans destinataire ni
contenu retourné. Elle ne prouve pas la lecture par le destinataire. Le rétablissement
peut prendre cinq minutes avant le resolved.

## Seuils de départ à calibrer pendant le pilote

| Règle | Condition et maintien | Priorité | Première vérification |
| --- | --- | --- | --- |
| ClenzyBackendDown | Cible absente ou indisponible, 5 min | critique | Déploiement, réseau et backend ; Sentry assure la détection indépendante |
| BaitlyBackendHigh5xx | > 5 % et au moins 5 erreurs/10 min, 2 min | critique | Sentry, version et dépendances |
| BaitlyBackendSlow | p95 > 2 s et au moins 20 requêtes/10 min, 10 min | attention | Pool DB, transactions, dépendances |
| BaitlyDatabasePoolSaturated | Connexions en attente, 5 min | critique | État DB et transactions longues |
| BaitlyJvmHeapPressure | Heap > 90 %, 10 min | attention | GC et croissance mémoire |
| BaitlyBackendDiskLow | Libre < 10 %, 10 min | critique | Stockage et rétention, sans effacement métier |
| BaitlyOperationalMetricsUnavailable | Snapshot invalide ou absent, 2 min | attention | Version backend et collecte SQL |
| BaitlyOperationalMetricsStale | Dernier succès > 120 s, 2 min | attention | Collecteur et DB ; ne pas interpréter les anciens zéros comme sains |
| BaitlyOutboxExhausted | Au moins un événement sans tentative restante, 2 min | critique | Relais et reprise idempotente |
| BaitlyOutboxStalled | Plus ancien non envoyé > 5 min, 5 min | critique | Kafka, relais et historique interne |
| BaitlyWebhookDeliveryStalled | Plus ancienne échéance passée > 10 min, 5 min | attention | Livraisons et scheduler ; les backoffs futurs sont exclus |
| BaitlyWebhookDisabled | Configuration FAILED, 5 min | attention | Cause des échecs avant toute réactivation |
| BaitlyChannelSyncFailures | > 20 % et au moins 3 erreurs/10 min, 5 min | attention | Canal concerné et rapprochement des disponibilités |
| BaitlyRecoveryMetricsUnavailable | Collecte invalide, santé ou fraîcheur absente sur cible joignable, 3 min | attention | Version backend, migrations et collecte SQL |
| BaitlyRecoveryMetricsStale | Collecte annoncée saine mais dernier succès > 180 s, 3 min | attention | Collecteur bloqué ; ne pas traiter les anciens compteurs comme actuels |
| BaitlyAccountingExportStalled | Intention en cours > 15 min, 5 min, échantillon sain et frais | attention | Journal et preuve distante, sans réarmer l’envoi |
| BaitlyAccountingExportUncertain | Au moins un UNKNOWN non historique, 5 min, échantillon sain et frais | attention | Rapprochement du bon compte/document, sans seconde création |

Les trois autres règles historiques couvrent échec de déploiement, ancienneté
du dernier déploiement et génération documentaire. Une absence de déploiement
pendant 72 h peut être volontaire : traiter cette alerte comme une vérification,
pas comme une preuve de panne du CD.

## Routage et confidentialité

Alertmanager conserve le récepteur staff interne existant, authentifié par un
token lu depuis un fichier ignoré par Git. Ce token ne doit jamais être copié dans
les tests ni le guide. Les annotations distantes et labels libres sont retirés
des notifications par le backend ; seul un nom de règle connu, un état et une
sévérité contrôlée sont transmis. Un nom inconnu apparaît comme `MonitoringAlert`.
Consulter alors le monitoring interne pour identifier la règle.

`baitly_ops_alerts_received_total` compte les lots acceptés pour notification,
pas les emails livrés ni la lecture par un opérateur. Alertmanager regroupe les
alertes et répète au plus toutes les 4 h. Pendant une indisponibilité du backend,
les alertes de snapshot périmé/indisponible sont inhibées au profit de la cause
racine ; la notification interne dépend du backend et peut être retardée. La
sonde Sentry et l’email projet ne dépendent pas de cette chaîne.

Les métriques de files sont globales et sans labels client : aucun payload,
email, URL de destination ou identifiant d’organisation. Une erreur SQL conserve
le dernier échantillon en le marquant invalide. Les retries illimités des jobs
d’affectation restent distingués des événements réellement épuisés. Une livraison
sans prochaine échéance utilise sa date de création pour rester détectable.

Les nouvelles jauges de reprise ne contiennent ni identifiant, empreinte, montant,
URL ni secret. Les deux SELECT sont hors du scrape, chacun borné à cinq secondes.
Un échec conserve l’échantillon précédent mais invalide sa santé et ne renouvelle
pas son timestamp. Les alertes comptables sont suspendues lorsque cette collecte
est invalide/périmée ou le backend indisponible ; la cause de collecte est signalée.
Le stock historique à revoir est compté séparément, sans alerte d’incident automatique.
Le nombre de blocages OAuth inclut les déconnexions volontaires : il ne constitue
pas un compteur d’erreurs et ne déclenche pas d’alerte. Aucun de ces signaux ne
réarme un journal, ne purge une preuve ou ne relance une opération fournisseur.
Les agrégats de journaux partagés sont affichés avec `max`, jamais additionnés
entre répliques d’une même base. Ne pas regrouper plusieurs bases indépendantes
sous ce contrat de qualification.

## Vérifications reproductibles, sans notification réelle

Versions identiques aux services : Prometheus 2.51.0 et Alertmanager 0.27.0.

```sh
rtk proxy promtool check rules monitoring/prometheus/rules/clenzy-alerts.yml monitoring/prometheus/rules/baitly-recovery.yml
# Depuis monitoring/prometheus/tests :
rtk proxy promtool test rules baitly-pilot.test.yml baitly-recovery.test.yml
rtk proxy amtool check-config monitoring/alertmanager/alertmanager.yml
rtk proxy amtool config routes test --config.file=monitoring/alertmanager/alertmanager.yml --verify.receivers=clenzy-inapp alertname=BaitlyOutboxExhausted severity=critical job=clenzy-backend
```

La CI exécute les mêmes validations dans des conteneurs éphémères, sans accéder
aux serveurs. Dix scénarios couvrent déclenchement, retour à la normale, métriques
absentes/périmées, files retardées, ressources saturées et silence à faible trafic.
Dix tests Python vérifient relecture, absence de restart, erreurs sans données
privées, refus des IP externes, refus du canari en production et rétablissement
même après un échec de recette.
Une absence de métriques backend interdit le chargement des nouvelles règles.
Les fixtures restent hors du répertoire `rules/`, chargé par wildcard en production.

L’extension ajoute neuf scénarios Prometheus (déclenchement, rétablissement,
collecte absente/périmée, panne backend, absence de bruit sur l’historique et les
déconnexions, couverture de toutes les répliques) et cinq tests Python de
précontrôle, soit dix-neuf scénarios et quinze tests Python au total. Le contrôle
d’exposition du backend utilise le registre Prometheus réel. Ces tests ne prouvent
pas une livraison, une réception staff ni une qualification de l’API partenaire.

Ne pas clôturer FR11 sur la seule base de ces tests : la validation exige une
livraison et une notification réelle de la chaîne Prometheus/Alertmanager,
la calibration pilote et les volets gouvernance, accès support et parcours métier. Les alertes
ne couvrent pas à elles seules sauvegardes/restauration, IoT, paiement bancaire,
ni tous les traitements spécifiques Channex.
