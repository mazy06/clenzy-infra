# DNS-AID — découverte d'agents par le DNS (clenzy.fr)

Statut : **non publié**. Cette page décrit ce qu'il reste à faire, et pourquoi ce
n'est pas dans un dépôt.

DNS for AI Discovery ([draft-mozleywilliams-dnsop-dnsaid][draft]) laisse un agent
trouver les points d'entrée d'un domaine avant même de faire une requête HTTP,
via des enregistrements SVCB/HTTPS ([RFC 9460][9460]) sous `_agents`.

La zone `clenzy.fr` est chez **Cloudflare** : ces enregistrements ne peuvent pas
être versionnés ici, ils s'ajoutent dans le tableau de bord (ou via l'API
Cloudflare). D'où cette page plutôt qu'un fichier de conf.

## Enregistrements à publier

Un seul point d'entrée est pertinent aujourd'hui : `_index`, qui pointe vers le
domaine servant les documents de découverte (`/.well-known/agent-skills/index.json`,
`/.well-known/api-catalog`, `/.well-known/oauth-protected-resource`).

```zone
_index._agents.clenzy.fr. 3600 IN SVCB 1 clenzy.fr. alpn="h2,http/1.1" port=443 mandatory=alpn,port
```

**Ne pas publier `_a2a._agents.clenzy.fr`** tant qu'aucun endpoint Agent2Agent
n'existe : annoncer un service absent envoie les agents dans le mur. Même
raisonnement pour `_mcp` — il n'y a pas de serveur MCP aujourd'hui (voir la note
dans le README de `clenzy-landingpage`).

## Marche à suivre sous Cloudflare

1. **DNS → Records → Add record**, type `SVCB`.
   - Name : `_index._agents`
   - Priority : `1`
   - Target : `clenzy.fr`
   - Params : `alpn="h2,http/1.1" port=443 mandatory=alpn,port`
   - TTL : `1h`
   - Proxy status : **DNS only** (un enregistrement SVCB ne se proxifie pas).
2. **DNS → Settings → DNSSEC → Enable.** Cloudflare affiche alors un
   enregistrement DS à recopier chez le registrar du domaine. Sans cette étape
   côté registrar, DNSSEC reste inactif et un résolveur validant ne renverra pas
   de données authentifiées — c'est exactement ce que demande le draft.
3. Vérifier :

```bash
dig +short _index._agents.clenzy.fr SVCB
dig +dnssec _index._agents.clenzy.fr SVCB | grep -c RRSIG   # doit être > 0
```

## Pourquoi c'est le dernier point restant

Tout le reste de la découverte agent (sitemap, en-têtes `Link`, négociation
Markdown, catalogue d'API, métadonnées OAuth, `auth.md`, compétences agent,
WebMCP) est servi par le conteneur de la landing et versionné dans
`clenzy-landingpage`. DNS-AID est le seul élément qui vit hors des dépôts.

[draft]: https://datatracker.ietf.org/doc/draft-mozleywilliams-dnsop-dnsaid/
[9460]: https://www.rfc-editor.org/rfc/rfc9460
