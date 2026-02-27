# 🚀 TODO — Configuration déploiement CD vers VPS OVH

> Pipeline CI/CD en place. Il reste ces étapes pour activer le déploiement automatique.

---

## 1. Préparer le VPS OVH

- [ ] Installer Docker sur le VPS
  ```bash
  ssh root@<IP_VPS>
  curl -fsSL https://get.docker.com | sh
  ```

- [ ] Cloner le repo infra sur le VPS
  ```bash
  git clone https://github.com/mazy06/clenzy-infra.git /opt/clenzy-infra
  cd /opt/clenzy-infra
  git checkout production
  ```

- [ ] Configurer le fichier `.env` de production
  ```bash
  cp .env.example .env
  nano .env   # Remplir toutes les valeurs (BDD, Keycloak, Stripe, Redis, etc.)
  ```

- [ ] Générer une clé SSH pour GitHub Actions
  ```bash
  ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_actions -N ""
  cat ~/.ssh/github_actions.pub >> ~/.ssh/authorized_keys
  cat ~/.ssh/github_actions   # Copier cette clé privée pour le secret VPS_SSH_KEY
  ```

---

## 2. Créer un token GitHub (PAT) pour le VPS

- [ ] Aller sur : https://github.com/settings/tokens
- [ ] Créer un token classic :
  - Nom : `clenzy-vps-ghcr`
  - Scope : `read:packages` uniquement
  - Copier le token `ghp_xxxx...`

---

## 3. Configurer les GitHub Secrets (3 repos)

- [ ] Aller dans **Settings > Secrets and variables > Actions** de chaque repo :
  - `mazy06/clenzy`
  - `mazy06/clenzy-landingpage`
  - `mazy06/clenzy-infra`

- [ ] Ajouter ces 4 secrets dans chacun :

  | Secret | Valeur |
  |--------|--------|
  | `VPS_HOST` | IP du VPS OVH |
  | `VPS_USER` | `root` (ou user SSH) |
  | `VPS_SSH_KEY` | Contenu de `~/.ssh/github_actions` (clé privée) |
  | `GHCR_TOKEN` | Token PAT `ghp_xxxx...` |

---

## 4. Créer l'environnement "production" sur GitHub

- [ ] Dans chaque repo : **Settings > Environments > New environment**
  - Nom : `production`
  - (Optionnel) Activer "Required reviewers" pour approbation manuelle

---

## 5. Premier test de déploiement

- [ ] Merger `main` vers `production` dans les 3 repos :
  ```bash
  # clenzy
  cd ~/Desktop/env/projets/sinatech/clenzy
  git checkout production && git merge main && git push origin production

  # clenzy-landingpage
  cd ~/Desktop/env/projets/sinatech/clenzy-landingpage
  git checkout production && git merge main && git push origin production

  # clenzy-infra
  cd ~/Desktop/env/projets/sinatech/clenzy-infra
  git checkout production && git merge main && git push origin production
  ```

- [ ] Vérifier sur GitHub > Actions que les pipelines passent au vert
