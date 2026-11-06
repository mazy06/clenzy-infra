# Vérification SIG-1CB997CAAF6AD6A8E91E3EA6

Le correctif est déjà livré dans `3ca9150` : une requête authentifiée
`SELECT 1` via PgBouncer bloque la poursuite du déploiement, avec un budget
de 30 tentatives. Les tests verrouillés simulent les refus réseau,
les erreurs d'authentification, une réponse incorrecte et la récupération.

La dernière preuve disponible comporte 17 tests réussis et un test
d'intégration ignoré : daemon Docker indisponible. Cette preuve ne valide
donc pas le trajet réseau réel. Relancer le contrôle dans un environnement
où Docker est accessible est nécessaire ; aucune modification des tests
ou du contrôle ne peut remplacer cette vérification.

L'attribution de l'incident aux recréations reste probable. La sonde ne
protège pas les connexions de l'API déjà active pendant les arrêts. Ses
risques sont un budget de reprise trop court et une image cliente indisponible.
Une maintenance avec drainage constitue une alternative ; supprimer les
recréations risque de laisser les fichiers montés non relus.

Après déploiement staging, corréler les horaires des recréations et du succès
SQL avec Sentry, les refus et expirations Loki et les mesures HikariCP.
Confirmer également les destinations et SQLSTATE des erreurs originales.
