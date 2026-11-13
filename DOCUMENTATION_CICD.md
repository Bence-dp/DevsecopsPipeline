# Documentation du pipeline CI/CD

Pipeline **CircleCI** (`.circleci/config.yml`) d'une application PHP. Il contrôle la qualité et la sécurité du code, construit une image Docker publiée sur GHCR, puis déploie sur AWS EC2.

## Vue d'ensemble

Deux workflows sont lancés en parallèle à chaque push :

```
main_workflow                                   container_workflow
─────────────                                   ──────────────────
debug-info                                      build-docker-image
build-setup                                            │ (main/master)
   ├── lint-phpcs                                      ▼
   ├── lint-phpmd                               deploy-ssh-production
   ├── lint-php-doc-check
   ├── security-check-dependencies
   ├── test-phpunit
   ├── metrics-phpmetrics
   └── metrics-phploc

hold (approbation manuelle : main, master, release/*)
   └── deploy-ssh-staging (release/*)
```

| Workflow | Rôle | Branches |
|---|---|---|
| `main_workflow` | Qualité, sécurité, tests, métriques, déploiement staging | Toutes (filtres par job) |
| `container_workflow` | Image Docker + déploiement production | `main`, `master`, `develop`, `feature/*`, `release/*`, `hotfix/*`, `bugfix/*` |

## `main_workflow`

### `debug-info`
Affiche l'utilisateur, le shell, l'OS, le `PATH`, la date et toutes les variables d'environnement. Diagnostic uniquement, aucune dépendance.

### `build-setup`
1. `checkout`
2. Restauration du cache Composer
3. `composer install --no-interaction --no-ansi --prefer-dist`
4. Sauvegarde du cache `./vendor`
5. Persistance du workspace

Tous les jobs suivants (sauf `debug-info` et `hold`) en dépendent.

### `lint-phpcs` : Vérifie le style de code
- Installe `squizlabs/php_codesniffer` et `phpcompatibility/php-compatibility`.
- Analyse selon `phpcs.xml`
- Les codes de sortie 1 et 2 (violations détectées) sont convertis en succès : le job n'échoue pas sur des erreurs de style.
- Génère les artifact : `phpcs-report` (format checkstyle).

### `lint-phpmd` : Détecte les mauvaises pratiques
- PHPMD sur `src` et `public`.
- Règles : `cleancode`, `codesize`, `controversial`, `design`, `naming`, `unusedcode`.
- Est non bloquant (`--ignore-violations-on-exit`).
- Génère les artifact : `phpmd-report.html`, `phpmd-report.txt`.

### `lint-php-doc-check` : Vérifie la documentation du code
- Installe `php-doc-check` dans `/tmp/tools`.
- Signale les fonctions complexes non documentées dans `src` et `public`.
- Est non bloquant.
- Génère les artifact : `php-doc-check.txt`.

### `security-check-dependencies` : Détecte les vulnérabilités des dépendances
- `local-php-security-checker` analyse `composer.lock` avec la base PHP Security Advisories.
- Seules les dépendances de production sont vérifiées (`--no-dev`).
- Bloquant si une vulnérabilité est trouvée.
- Génère les artifact : `security-report.json`.


### `test-phpunit` : Vérifie les tests unitaires
- Si `phpunit.xml` est absent, le job s'arrête proprement (`circleci step halt`).
- Exécute `./vendor/bin/phpunit --testsuite=Unit`.
- Bloquant en cas d'échec.

### `metrics-phpmetrics` : Vérifie les métriques de qualité
- PhpMetrics sur `src` et `public` : complexité, maintenabilité, couplage.
- Génère les artifact : `phpmetrics-report` (HTML), `phpmetrics.json`.

### `metrics-phploc` : Vérifie la taille du code
- `phploc.phar` sur `src` et `public` : lignes de code, classes, méthodes, complexité.
- Génère les artifact : `phploc.txt`, `phploc.json`.

### `hold` : Approbation manuelle
- Job de type `approval` sur `main`, `master` et `release/*`.
- Le pipeline attend un clic *Approve* dans l'interface CircleCI.
- N'attend pas la fin des jobs d'analyse ci-dessus(aucun `requires`).

### `deploy-ssh-staging` : Déploiement staging
Uniquement sur `release/*`, après approbation de `hold`.

1. Ajoute la clé SSH de fingerprint `SHA256:OH0eEFGU…` (enregistrée dans CircleCI).
2. Vérifie que les variables `STAGING_SSH_*`, `GHCR_*` et `INFISICAL_*` sont bien définies (sinon échec).
3. Se connecte en SSH à l'instance EC2 de staging (`$STAGING_SSH_USER@$STAGING_SSH_HOST`) et exécute :
   ```bash
   sudo docker login ghcr.io -u $GHCR_USERNAME --password-stdin   # GHCR_PAT passé via stdin
   sudo docker pull ghcr.io/bence-dp/devsecopspipeline:<SHA>
   sudo docker rm -f devsecops-staging || true
   sudo systemctl stop apache2 || true                             # libère le port 80
   sudo docker run -d --name devsecops-staging --restart unless-stopped -p 80:80 \
     -e INFISICAL_TOKEN -e INFISICAL_PROJECT_ID \
     -e INFISICAL_ENVIRONMENT -e INFISICAL_DOMAIN \
     ghcr.io/bence-dp/devsecopspipeline:<SHA>
   ```

Même procédure que la production : on déploie l'image Docker du commit (tag SHA) construite par `build-docker-image`. Seuls le serveur cible et le nom du conteneur (`devsecops-staging`) changent.

Le job ne dépend pas de `build-docker-image`, qui tourne dans l'autre workflow. Si `hold` est approuvé avant la fin du build, l'image `:<SHA>` n'existe pas encore sur GHCR et le `docker pull` échoue.

## `container_workflow`

### `build-docker-image` : Build et publie l'image
1. `checkout` + `setup_remote_docker`.
2. Sortie immédiate si `SKIP_BUILD` est défini.
3. Calcul des noms :
   - dépôt : `ghcr.io/<user>/<repo>`
   - tag de branche : nom de branche nettoyé
4. Connexion à GHCR avec `GHCR_USERNAME` / `GHCR_PAT`.
5. `docker build -f Docker/Dockerfile` avec deux tags :
   - `:<branche>` (mobile)
   - `:<SHA du commit>` (immuable, utilisé pour le staging et la production)
6. `docker push --all-tags`.


### `deploy-ssh-production` : Déploiement production
Uniquement sur `main`/`master`, après `build-docker-image`, sans approbation manuelle.

1. Vérifie que les variables `EC2_*`, `GHCR_*` et `INFISICAL_*` sont bien définies (sinon échec).
2. Écrit `EC2_PRIVATE_KEY` dans `~/.ssh/ec2_deploy_key` (mode `600`), supprimée en fin de job (`trap ... EXIT`).
3. Se connecte en SSH à l'instance EC2 (`$EC2_USER@$EC2_HOST`) et exécute :
   ```bash
   sudo docker login ghcr.io -u $GHCR_USERNAME --password-stdin   # GHCR_PAT passé via stdin
   sudo docker pull ghcr.io/bence-dp/devsecopspipeline:<SHA>
   sudo docker rm -f devsecops-app || true
   sudo systemctl stop apache2 || true                             # libère le port 80
   sudo docker run -d --name devsecops-app --restart unless-stopped -p 80:80 \
     -e INFISICAL_TOKEN -e INFISICAL_PROJECT_ID \
     -e INFISICAL_ENVIRONMENT -e INFISICAL_DOMAIN \
     ghcr.io/bence-dp/devsecopspipeline:<SHA>
   ```

L'image déployée est exactement celle construite pour ce commit (tag SHA). Au démarrage, le conteneur récupère ses secrets auprès d'Infisical grâce aux variables `INFISICAL_*` transmises par CircleCI (voir l'entrypoint ci-dessous).

### Gestion des secrets à l'exécution (`Docker/scripts/entrypoint.sh`)
Au démarrage du conteneur :
1. Exige `INFISICAL_TOKEN`, `INFISICAL_PROJECT_ID`, `INFISICAL_ENVIRONMENT` (et `INFISICAL_DOMAIN` en option).
2. Exporte les secrets depuis Infisical au format dotenv dans un fichier temporaire.
3. L'installe en `/var/www/html/.env` (propriétaire `www-data`, mode `0640`).
4. Supprime `INFISICAL_TOKEN` de l'environnement puis lance Apache.

Aucun secret applicatif n'est donc inclus dans l'image ni dans le dépôt (`.env*` exclu par `.gitignore` et `.dockerignore`, seul `.env.example` est versionné). En staging et en production, ces variables sont transmises au conteneur par les jobs `deploy-ssh-staging` et `deploy-ssh-production`.

## Variables d'environnement CircleCI

| Variable | Utilisée par | Rôle |
|---|---|---|
| `GHCR_USERNAME` | `build-docker-image`, `deploy-ssh-*` | Utilisateur GHCR |
| `GHCR_PAT` | `build-docker-image`, `deploy-ssh-*` | Token GitHub (`write:packages` pour le push, `read:packages` pour le pull) |
| `SKIP_BUILD` | `build-docker-image` | Optionnelle : désactive le build |
| `STAGING_SSH_USER` | `deploy-ssh-staging` | Utilisateur SSH staging |
| `STAGING_SSH_HOST` | `deploy-ssh-staging` | Hôte EC2 staging |
| `EC2_USER` | `deploy-ssh-production` | Utilisateur SSH production |
| `EC2_HOST` | `deploy-ssh-production` | Hôte EC2 production |
| `EC2_PRIVATE_KEY` | `deploy-ssh-production` | Clé privée SSH de l'instance EC2 |
| `INFISICAL_TOKEN` | `deploy-ssh-*` | Token d'accès Infisical |
| `INFISICAL_PROJECT_ID` | `deploy-ssh-*` | Projet Infisical |
| `INFISICAL_ENVIRONMENT` | `deploy-ssh-*` | Environnement Infisical, **le même pour le staging et la production** |
| `INFISICAL_DOMAIN` | `deploy-ssh-*` | URL de l'instance Infisical |

La clé SSH du staging est enregistrée dans *Project Settings -> SSH Keys* de CircleCI. Celle de la production est stockée dans la variable `EC2_PRIVATE_KEY`.
