# Baitly : qualification des sauvegardes et de la reprise

Objectifs du pilote France, choisis le 22 octobre 2026 : **RPO 1 heure, RTO 4 heures**.
Ce sont des critères à démontrer. Ce lot ne les déclare pas atteints.

## Corrections et couverture réelle

`backup.sh` exige un dump custom non vide de la base métier et de la base
d’authentification complète, avec le nom configuré `KEYCLOAK_DB_NAME`. Il ne
masque plus un échec Keycloak et ne remplace plus cette base par un export
incomplet de métadonnées du realm. Aucun login kcadm ni fichier de session admin
n’est créé dans le conteneur.

Le manifeste `baitly-manifest.json` inventorie tailles, SHA-256, rôle des fichiers
et début du snapshot en UTC. Le lecteur limite les tailles et le nombre de
membres, refuse chemins sortants, doublons, liens et fichiers spéciaux, et vérifie
les empreintes avant extraction. Les contrôles de table des matières pg_restore
et SHA-256 ne remplacent pas une restauration effective et ne prouvent pas
l’authenticité de la source.

Les fichiers privés sont créés sous umask 077, les archives en 0600. Une archive
n’est publiée qu’après vérification, atomiquement, sans remplacer une archive
existante. La rétention historique annoncée est enfin appliquée par catégorie :
7 jours ordinaires, 28 jours pour les dimanches, 180 jours pour les premiers du
mois ; les autres fichiers et liens ne sont pas supprimés. Ces durées restent
à confirmer dans la politique de conservation du pilote.

**Limites explicites :** ce format est une sauvegarde locale de bases, pas une
sauvegarde complète du produit. Documents, secrets de déploiement, chiffrement
et copie hors site ne sont pas prouvés et sont marqués faux dans le manifeste.
Les anciens fichiers ne reçoivent pas rétroactivement une preuve d’intégrité.
Ils doivent faire l’objet d’un inventaire et d’une qualification séparée.

## Recette isolée sur archives de confiance

`restore.sh --archive <archive-de-confiance> --isolated` appelle exclusivement
`baitly_restore_rehearsal.py`. Sans `--isolated`, l’ancienne restauration en place
est refusée ; `--yes` ne peut pas désactiver cette protection. La restauration
réelle d’un environnement exigera un workflow CI/CD dédié et revu.

La recette alloue son propre répertoire privé, initialise un nouveau cluster
PostgreSQL sans écoute TCP, puis utilise seulement son socket Unix privé.
Les paramètres PGHOST/PGDATABASE/PGSERVICE/PGOPTIONS et mots de passe de
l’environnement appelant ne sont pas réutilisés. Aucun choix de DSN ou de cible
existante n’est exposé. Aucun conteneur n’est démarré, arrêté ou redémarré par
l’outil ; seuls ses processus temporaires PostgreSQL sont nettoyés. Un échec
de nettoyage conserve le répertoire privé plutôt que de supprimer les données
sous un processus encore actif.

Le restore utilise les binaires d’une même installation PostgreSQL
(`BAITLY_PG_BINDIR`), `--exit-on-error`, une transaction unique et des bases neuves
créées depuis template0. Toute erreur fait échouer la recette. Les deux realms
`clenzy` et `clenzy-guests` doivent être présents dans la base d’authentification.
Le rapport ne contient que des agrégats et indique que le RTO complet, les
documents et la copie hors site ne sont pas prouvés.

Les archives doivent provenir d’une source interne de confiance : une empreinte
ne rend pas un dump SQL non fiable sûr à exécuter. Le serveur temporaire n’écoute
pas sur TCP, mais cela ne constitue pas un bac à sable système contre du SQL
malveillant. PostgreSQL documente cette limite dans sa
[référence pg_restore](https://www.postgresql.org/docs/15/app-pgrestore.html).

Redis n’est pas restauré : sessions, verrous et états OAuth périmés ne sont pas
réinjectés. Les rôles et tablespaces globaux ne font pas partie d’un pg_dump ;
le bootstrap des rôles applicatifs (`postgres/ensure-app-role.sh`), les droits
réels et l’accès métier restent à qualifier avant toute reprise réelle.
Voir [la portée des dumps PostgreSQL](https://www.postgresql.org/docs/15/backup-dump.html).

## Validation automatisée

`python3 -m unittest discover -s backup -p 'test_baitly_recovery.py' -v`

Les tests couvrent corruption, archives dangereuses, absence du dump auth,
échec fournisseur de dump, permissions privées, rétention par catégorie et
refus de restauration en place. Une recette PostgreSQL réelle crée deux bases
synthétiques, sauvegarde, restaure dans un second cluster temporaire et contrôle
les lignes ainsi que les deux realms. Des valeurs PGHOST/PGDATABASE/PGOPTIONS
externes factices ne doivent pas détourner la destination.

La CI exécute ces tests dans `pgvector/pgvector:pg15`, avec restauration obligatoire
de l’extension vector et de ses données synthétiques. Aucun secret, dump réel ou
environnement de déploiement n’est utilisé. Les temps sur petites fixtures ne
valident pas les 4 heures sur le volume réel.

## Critères restant à satisfaire avant clôture FR09

1. Inventorier l’exécution et le dernier succès réels, les volumes, versions,
   rôles, certificats, secrets et objets référencés par la base. Ne pas confondre
   une sauvegarde opportuniste avant déploiement avec une sauvegarde planifiée.
2. Choisir une clé de déchiffrement détenue hors du VPS et un stockage hors site
   approuvé. Chiffrer et vérifier une copie complète avec des accès distincts
   du compte de service principal. Ne pas stocker la clé privée dans le même
   serveur ou la même sauvegarde ; ne pas la transmettre dans le chat.
3. Couvrir les documents privés et leur cohérence avec la base, ainsi que le
   matériel nécessaire au redémarrage de l’authentification et du stockage.
   Tester la récupération hors site et le déchiffrement, sans exporter les
   données métier dans une CI générale ni dans les outils de télémétrie.
4. Préparer une cadence de 30 minutes puis mesurer sa durée réelle, y compris
   chiffrement et transfert. Calculer l’âge du **début du dernier snapshot
   complet et vérifié hors site**, pas celui de la fin du job local. Le seuil
   d’acceptation RPO est 3600 secondes ; une simple archive locale ne le satisfait pas.
5. Préparer alerte d’échec et d’ancienneté, preuve de réception et procédure de
   reprise. Ne pas envoyer de nouvelles notifications de recette au staff sans
   l’autorisation correspondant à cette recette.
6. Chronométrer le parcours complet : récupération, déchiffrement, bases,
   authentification, secrets, documents, services et vérification des droits et
   parcours métier. Le total doit être inférieur à 4 heures sur volume réel,
   en environnement isolé sans automatisations de paiement, OTA ou messages réels.
7. Attacher la preuve à la version, à l’environnement et à l’opérateur ; livrer
   les changements de production uniquement par PR et CI/CD.
