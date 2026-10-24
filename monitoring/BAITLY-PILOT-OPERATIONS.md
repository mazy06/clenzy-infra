# Baitly : alertes opérationnelles du pilote France

## État des préparations au 24 octobre 2026

Les quatre alertes historiques sont conservées et douze règles pilote sont ajoutées.
Une extension de neuf règles de reprise est préparée, soit vingt-cinq règles après
intégration. Elle dépend de la candidate backend cumulative [#505](https://github.com/mazy06/clenzy/pull/505),
incluant #504/#503/#502/#501/#500/#495 ; utiliser son SHA de tete qualifie
avec CI applicable verte, puis rattacher ce SHA au CD et a la campagne finale.
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
   Pour l’extension de reprise : livrer la candidate cumulative #505 incluant #504/#503/#502/#500/#501, avec les treize jauges
   `baitly_recovery_*`. Chaque réplique doit les exposer ; un seul backend à jour
   ne suffit pas à valider un déploiement partiel. L’échantillon de reprise doit
   être sain et âgé de moins de 180 secondes, les onze agrégats présents et positifs ou nuls. Les cinq jauges privées
   baitly_noise_warning_* doivent aussi être présentes, saines et fraîches sur
   chaque réplique avant activation des trois nouvelles règles.
2. Intégrer et déployer ensuite ces règles infra via PR/CI/CD en staging. Sinon,
   l’absence des nouvelles métriques déclenchera légitimement une alerte.
3. Vérifier la présence des 25 règles après intégration et l’état des cibles dans Prometheus.
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
| BaitlyMinutRecoveryStalled | READY > 15 min, condition 5 min | attention | Worker et progression ; aucune étape confirmée à rejouer |
| BaitlyMinutRecoveryUncertain | STARTED/UNKNOWN > 5 min, condition 5 min | attention | Rapprocher la preuve ; ne pas réarmer ni effacer l’intention |

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
rtk proxy promtool test rules baitly-pilot.test.yml baitly-recovery.test.yml baitly-minut.test.yml baitly-noise-warning.test.yml baitly-automation.test.yml baitly-external-effects.test.yml
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

## Extension Minut : activation différée à la campagne finale

Cette branche prolonge l’extension #135. Elle exige d’abord le journal backend #500 et le collecteur Minut #501 et le correctif de décodage Kafka [#502](https://github.com/mazy06/clenzy/pull/502). Les treize jauges baitly_recovery_* doivent être présentes sur CHAQUE réplique joignable avant activation. L’absence d’une jauge Minut, un collecteur malsain ou une fraîcheur dépassée bloque le précontrôle. Ne pas promouvoir ces règles avant ce backend. Aucune modification de serveur n’est réalisée par cette préparation.

Les cinq nouvelles jauges sont minut_ready, minut_uncertain, minut_review, minut_oldest_ready_seconds et minut_oldest_uncertain_seconds. STARTED et UNKNOWN appartiennent à l’incertitude ; REVIEW est le stock historique/retardé à examiner, pas une panne à réarmer. DONE et SUPERSEDED sont exclus. Les répliques lisent la même base : maximum des compteurs, jamais addition de copies du même journal. Aucun identifiant ni label client n’est publié.

BaitlyMinutRecoveryStalled : étape READY de plus de quinze minutes, condition maintenue cinq minutes. BaitlyMinutRecoveryUncertain : tentative STARTED/UNKNOWN de plus de cinq minutes, condition maintenue cinq minutes. Seuils initiaux à calibrer pour le pilote ; aucune règle ne rejoue une notification ou automatisation. Les deux alertes sont suspendues si backend indisponible, santé fausse ou échantillon vieux. REVIEW seul ne déclenche pas ces alertes.

Recette finale : vérifier 22 règles saines, 13 jauges par réplique, la fraîcheur et les deux noms acceptés par le récepteur OPS. Simuler uniquement sur données/destinataires de recette explicitement autorisés, sans panne publique ni notification implicite. Le contrôle des règles, du routage et des scénarios locaux ne vaut ni envoi réel ni validation staging. Les STARTED/UNKNOWN exigent rapprochement de preuve ; aucun SQL de réarmement ni replay générique d’automatisation.

Le passage HTTP vers admission doit aussi être qualifié : le listener Minut de #502 lit la chaîne produite par JsonSerializer ; le défaut Map commun ne doit pas la rejeter avant le journal. Le consumer conserve groupe et retry/DLT. Les tests de codecs réels sont locaux/CI, pas une preuve de connectivité du broker staging.

## Extension avertissements voyageurs : journal avant provider

Cette candidate prolonge #136. Le nouveau backend cumulatif sur #503 doit
etre revu et livre AVANT ces regles, avec la migration 0600 et les cinq jauges
baitly_noise_warning_*. Le precontrole exige toutes les 13 jauges recovery et
cinq nouvelles jauges sur CHAQUE replique joignable, ainsi que leur sante et
fraicheur. Total apres integration : 25 regles.

BaitlyNoiseWarningMetricsUnavailable : jauge manquante, sante fausse ou succes
de collecte vieux de plus de 180 s, condition trois minutes.
BaitlyNoiseWarningUncertain : STARTED/UNKNOWN de plus de cinq minutes, condition
cinq minutes. BaitlyNoiseWarningRepairStalled : file de preuves acceptees a
reparer reste non vide pendant quinze minutes. Les deux alertes metier exigent
une collecte saine/fraiche et un backend disponible. Seuils initiaux a calibrer.

Les journaux partages sont comptes une seule fois via max, jamais sum entre
repliques. Aucun destinataire, contenu, recu ou identifiant client dans les
metriques. Une alerte ne rearme pas l'envoi et ne libere pas une tentative.
Le worker backend repare seulement les marqueurs locaux depuis ACCEPTED,
jamais les tentatives inconnues ; aucun envoi provider dans ce worker.

Les scenarios locaux utilisent promtool/amtool et des fixtures synthetiques.
Aucun Docker, SIGHUP, appel Alertmanager, notification reelle ou test staging
n'est execute par cette preparation. Campagne finale seulement apres livraison
de la candidate applicative ; une autorisation explicite reste requise pour
les notifications synthetiques aux destinataires du staging.

Validation locale du lot au 24 octobre 2026 : 25 règles valides, 35 scénarios
Prometheus, 20 tests Python et trois routes Alertmanager synthétiques vérifiés.
Les outils promtool 2.51.0 et amtool 0.27.0 sont vérifiés par leurs SHA-256 officiels.
Aucun rechargement réel, envoi de notification, conteneur ou staging exécuté.

## Extension proprietaire et premiere delegation : candidate #505

Les cinq jauges baitly_noise_warning_* gardent leurs noms et seuils. Le backend
#505 inclut dans uncertain/oldest_uncertain_seconds les tentatives SMTP
proprietaire STARTED/UNKNOWN, sans compter deux fois la file voyageur. Son
repair_pending inclut les canaux proprietaire completement acceptes dont le
marqueur local manque, sans presenter un fan-out partiel comme reparable.
Les libelles parlent donc de notifications bruit, proprietaire ou voyageur.

La collecte exige les migrations 0601/0602 de la candidate cumulative #505
avant activation. Les treize autres jauges de reprise sont toujours requises
sur chaque replique. Backend #505 puis cette candidate infra, par PR/CI/CD ;
aucune activation, notification reelle ni qualification staging dans ce lot.
La file des travaux jamais tentes expire apres quinze minutes ; ce statut SKIPPED
ne prouve pas une livraison. Les compteurs presentes ici surveillent les effets
incertains et reparations, pas toutes les causes d'expiration de travaux PENDING.
Le moteur d'automatisation global conserve son cycle distinct.

## Extension moteur d’automatisation : activation différée

Cette candidate prolonge #138 et exige d’abord la candidate applicative cumulative
sur #506 : migration 0603 et collecteur BaitlyAutomationMetrics. Aucun nouveau
port public ni endpoint n’est ajouté. Les neuf jauges baitly_automation_* sont
ready, oldest_ready_seconds, uncertain, oldest_uncertain_seconds, expired, review,
legacy_review, snapshot_healthy et snapshot_last_success_timestamp_seconds.
Aucun nom de règle, contenu, destinataire, diagnostic ou identifiant métier
n’est lu/exporté. Les métriques plateforme restent sur le monitoring privé.

ready exclut les travaux futurs et expirés ; uncertain conserve STARTED/UNKNOWN
sans expiration. review et legacy_review ne sont pas des files à réarmer.
Une lecture SQL manquante ou incohérente conserve les derniers chiffres et
leur date, santé fausse. Les âges suivent l’heure locale TIMESTAMP du moteur,
indépendamment du fuseau DB. Le coût SQL réel reste à mesurer lors du pilote.

Le précontrôle exige les neuf valeurs finies/non négatives sur CHAQUE réplique,
santé égale à un, succès âgé d’au plus 180 s et pas plus de 60 s dans le futur.
Il utilise exactement le prédicat PromQL des alertes. Une seule réplique
invalide interdit le rechargement. Affichage des journaux partagés via max,
jamais somme entre répliques. Total : 29 règles d’alerte.

- BaitlyAutomationMetricsUnavailable : collecte absente, invalide, périmée ou
  horloge incohérente sur backend joignable, pendant trois minutes.
- BaitlyAutomationStalled : ready positif et âge >120 s, pendant trois minutes.
- BaitlyAutomationUncertain : tentative âgée de plus de cinq minutes, pendant
  cinq minutes supplémentaires ; aucun rejeu.
- BaitlyAutomationReviewRequired : stock expired/review/legacy_review non vide
  pendant quinze minutes, y compris historique. Examen requis sans renvoi aveugle.

Les trois alertes métier sont suspendues quand le snapshot de leur réplique
est invalide ou le backend indisponible. Les messages statiques orientent vers
worker/journal/preuve ; aucune action automatique, aucun libellé client.
Le routage existant clenzy-inapp est contrôlé sans envoi via amtool.

Ordre de campagne finale : revue/bascule sans anciens producteurs, livraison
app cumulative, observation de toutes les répliques puis activation infra
cumulative. #134 (sauvegardes en attente) reste exclue. Les 24 scénarios
promtool d’automatisation couvrent déclenchement/rétablissement, valeurs
manquantes (chacune des neuf), négatives/NaN/infinies, santé/fraîcheur/horloge,
répliques partielles et backend arrêté. Les tests Python mockent tout réseau
et Docker. Aucune exécution de précontrôle réel, SIGHUP, notification ou
recette staging par ce lot. Les seuils et la livraison réelle des alertes
restent à qualifier avec la campagne finale ; FR11 ne se clôture pas ici.

## Effets incertains des serrures et des rapports

La candidate applicative cumulative doit exposer les neuf jauges `baitly_external_effect_*` sur toutes les répliques avant activation infra. Elle comprend la migration 0605 ; aucune migration supplémentaire pour ces métriques. Le collecteur lit le journal privé, jamais les PIN, contacts, documents ou réponses fournisseur. STARTED et UNKNOWN restent bloqués, même anciens. Les tentatives manuelles sont incluses ; aucun historique non journalisé ne devient une preuve.

Jauges : `lock_uncertain`, `lock_oldest_uncertain_seconds`, `lock_unknown`, `report_uncertain`, `report_oldest_uncertain_seconds`, `report_unknown`, `report_partial`, `snapshot_healthy`, `snapshot_last_success_timestamp_seconds`. Un rapport partiel signifie au moins une acceptation SMTP enregistrée sans résultat terminal commité ; cela ne prouve pas une absence de livraison au reste du lot. Les agrégats de base partagée utilisent max et non sum. Ne pas regrouper des bases indépendantes.

| Alerte | Condition et temporisation | Conduite |
| --- | --- | --- |
| BaitlyExternalEffectMetricsUnavailable | Neuf valeurs manquantes, non finies, négatives, santé invalide ou timestamp hors fenêtre [-60 s, 180 s], pendant 3 min | Vérifier version, migration, horloge et collecte avant toute conclusion. |
| BaitlyLockEffectUncertain | STARTED/UNKNOWN âgé de plus de 5 min, condition maintenue 5 min | Rapprocher preuves cloud et matérielles sans relancer la commande. |
| BaitlyReportEffectUncertain | STARTED/UNKNOWN âgé de plus de 5 min, condition maintenue 5 min | Examiner preuves SMTP et commit, sans renvoi. |
| BaitlyReportEffectPartial | Au moins une acceptation dans une tentative non terminée, pendant 3 min | Examiner le lot sans renvoyer les acceptés ni les restants automatiquement. |

Les alertes métier sont suspendues si collecte invalide/périmée ou backend indisponible. L'alerte partielle inhibe son alerte rapport générique sur la même réplique. Le récepteur interne et ses identifiants fonctionnels sont conservés. Les notifications backend ne reprennent jamais les annotations ou labels libres. Le précontrôle refuse la relecture si une seule réplique est invalide.

Validation préparée : 36 nouveaux scénarios promtool couvrant déclenchement/rétablissement, neuf métriques manquantes, NaN/Inf/négatif, timestamp périmé/futur, backend arrêté et réplique incomplète ; précontrôles et routes testés sans réseau métier ni notification réelle. La recette staging finale vérifiera les vrais incidents synthétiques, leur réception autorisée, la fraîcheur de chaque réplique, le coût SQL et la conservation des blocages après redémarrage. Ne pas activer les règles avant la candidate applicative cumulative ; aucun déploiement dans cette vague. FR09 en attente et FR10/FR11 restent ouverts.


## Délégations bruit expirées avant tentative

Déployer la candidate backend cumulative incluant la migration 0606 avant cette candidate infra. Deux jauges privées complètent les cinq noms existants : `baitly_noise_warning_expired_unattempted` (stock conservé observé) et `baitly_noise_warning_expired_unattempted_recent` (échéances dans les quinze dernières minutes). Unité : item destinataire/canal ; pas un nombre d'alertes, de personnes uniques ou de livraisons. Le worker enregistre les nouveaux SKIPPED expirés sans tentative ; les anciens SKIPPED ne sont pas requalifiés. Les intentions incertaines et les preuves voyageurs ne deviennent jamais des expirations sans effet.

Le précontrôle et les règles bruit exigent désormais les sept valeurs finies/non négatives sur chaque réplique, santé à un, snapshot de 180 secondes maximum, horloge future limitée à 60 secondes, récent inférieur ou égal au total et backend disponible. Une seule réplique incomplète interdit la relecture. Les répliques partageant une base utilisent max, jamais sum.

`BaitlyNoiseWarningExpiredBeforeAttempt` : fenêtre récente non vide pendant trois minutes. Vérifier la version, le worker, ses verrous et sa latence ; conserver les journaux, ne jamais renvoyer automatiquement ni libérer une incertitude. L'alerte s'éteint lorsque les échéances sortent de la fenêtre de quinze minutes ; ce rétablissement ne prouve ni réparation ni livraison. Une panne de collecte prolongée peut manquer cette fenêtre : le total conservé reste à examiner après rétablissement, sans fabriquer une chronologie manquante.

Les annotations restent fixes, les labels/annotations libres ne sont pas transmis aux notifications OPS. Les simulations locales/CI ne notifient personne. Activation, coût SQL sur volume pilote, réception et rétablissement réels seront vérifiés dans la campagne staging finale. La rétention reste à définir séparément.

## Logs proxy et broker sans données métier

Le template Nginx et sa configuration statique utilisent `baitly/proxy-logging.conf`. L'accès n'écrit que code de schéma, horodatage, méthode dans une liste fermée (sinon OTHER), chemin catégorisé, statut, statut upstream et durée. Aucune IP, hôte, ray, query, cookie, Authorization, referer, agent, chemin privé ou valeur métier. Le routage, l'IP utilisée par le rate limiting, les headers de sécurité et les contrôles d'origine sont conservés.

Les erreurs natives Nginx vont vers `/dev/null` : leur format n'est pas personnalisable et peut recopier une requête complète. C'est une perte volontaire de détail de diagnostic, pas une modification des réponses HTTP. Diagnostiquer 4xx/5xx et latence depuis les accès techniques, métriques et sondes ; ne pas réactiver temporairement les erreurs brutes en situation réelle. Les rejets TLS sans requête HTTP et les erreurs internes sans accès n'ont donc pas de détail individuel ; les sondes de disponibilité restent nécessaires.

Kafka 7.6 utilise le layout reload4j EnhancedPatternLayout avec `%throwable{none}`, jamais PatternLayout seul (qui peut rajouter les exceptions). Les fichiers montés en lecture seule dans les trois compositions n'affectent ni les listeners, ni les données du broker, ni sa rétention métier. Les lignes ne contiennent que code, niveau et horodatage. Le backend nécessite également la candidate applicative cumulative contenant `BaitlyBrokerDiagnosticsAppender` pour ses clients Spring/Kafka.

Promtail n'accepte vers Loki que les schémas complets fermés proxy/broker. Ancien format, texte natif stderr, JSON supplémentaire et continuation de stack sont rejetés ; les compteurs de rejet portent uniquement des raisons fixes. L'ordre de bascule peut entraîner des diagnostics perdus tant qu'une source garde l'ancien format, jamais leur transfert brut. Les anciens fichiers Docker/Loki, la sortie de bootstrap hors Log4j, Kafka UI, les autres services et la rétention demeurent des périmètres séparés. Ne pas annoncer une purge des données historiques.

La CI vérifie le layout avec les bibliothèques de l'image réellement configurée, extraite via docker create/cp/rm, sans démarrage. La recette HTTP utilise un Nginx éphémère hors Docker ; elle vérifie les 502, catégories, absence de données, headers, limites et contrôles d'origine. Promtail est exécuté en dry-run avec canaris et sentinelle de vidage, sans Loki. La revue de la modification du template porte uniquement sur ses directives de journalisation et leur include ; aucune règle de sécurité ou de proxy n'est modifiée.

Candidate applicative cumulative en premier, puis cette candidate infra (incluant les règles métriques précédentes). Pas de déploiement ou redémarrage dans cette vague. La campagne staging finale vérifiera les sorties de toutes les répliques, l'activation des fichiers montés et du layout exact, les pertes/rejets attendus au cutover, l'absence de détails privés dans Docker/Loki/Sentry et la disponibilité des codes techniques. FR09 reste en attente ; FR10/FR11 et conservation restent ouverts.
