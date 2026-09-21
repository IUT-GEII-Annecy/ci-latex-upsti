# ci-latex-upsti

Workflow GitHub Actions **réutilisable** (`workflow_call`) pour compiler les
documents LaTeX/UPSTI d'un dépôt de supports pédagogiques et publier le
résultat sur GitHub Pages.

Factorise la partie strictement identique entre tous les dépôts de ce type :
checkout, installation d'UPSTI (dépôt privé), génération des métadonnées
`gitinfo2`, compilation, publication Pages. Chaque dépôt appelant garde son
propre `scripts/build_pdfs.sh` (+ `scripts/gen_index.py`), car la logique de
sélection et de classement des documents y est spécifique (arborescence,
règles d'exclusion des documents nominatifs/évaluations, etc.).

## Utiliser ce workflow dans un dépôt de supports

Créer `.github/workflows/build-pdfs.yml` dans le dépôt appelant :

```yaml
name: Compile et publie les PDF

on:
  push:
    branches: [main, master]
  workflow_dispatch: {}

jobs:
  publish:
    uses: IUT-GEII-Annecy/ci-latex-upsti/.github/workflows/build-pdfs.yml@main
    secrets: inherit
```

C'est tout : pas besoin de recopier le checkout d'UPSTI, texhash, la
génération gitinfo2, ni les étapes de publication Pages.

### Prérequis côté dépôt appelant

1. **Un script de compilation** à `scripts/build_pdfs.sh` (paramétrable via
   l'input `build-script`, voir ci-dessous) qui reçoit en argument `$1` le
   dossier de sortie et y dépose les PDF + `index.html` à publier.
2. **Le secret `UPSTI_DEPLOY_KEY`** (Settings → Secrets and variables →
   Actions) : clé de déploiement en lecture vers le dépôt privé
   `GeoffreyV/UPSTI`. `secrets: inherit` le transmet automatiquement au
   workflow réutilisable.
3. **GitHub Pages activé** : Settings → Pages → Source = *GitHub Actions*
   (à faire une fois, uniquement via l'interface web).
4. **Accès au package Docker** `ghcr.io/iut-geii-annecy/texlive-upsti` :
   sur la page du package → *Manage Actions access* → ajouter ce dépôt en
   lecture (ou rendre le package public une bonne fois pour ne plus avoir
   à le faire dépôt par dépôt).

### Personnalisation (inputs optionnels)

```yaml
jobs:
  publish:
    uses: IUT-GEII-Annecy/ci-latex-upsti/.github/workflows/build-pdfs.yml@main
    with:
      build-script: scripts/build_pdfs.sh   # défaut
      site-dir: _site                        # défaut
      texlive-image: ghcr.io/iut-geii-annecy/texlive-upsti:latest  # défaut
      fetch-depth: 100                        # défaut
    secrets: inherit
```

## Versionnement

Référencer `@main` suit la dernière version du workflow (pratique, mais un
changement ici peut impacter tous les dépôts appelants sans préavis).
Pour figer un dépôt sur une version stable, référencer un tag à la place,
ex. `@v1`, une fois qu'un premier tag aura été créé sur ce dépôt.

## Pourquoi gitinfo2 a besoin d'une étape dédiée en CI

`gitinfo2` lit normalement `.git/gitHeadInfo.gin`, généré par un hook git
local (`post-commit`/`post-checkout`/`post-merge`). Ces hooks vivent dans
`.git/hooks/`, un dossier **non versionné par git** : ils sont donc absents
après tout clone frais, y compris celui d'`actions/checkout` en CI. Ce
workflow reproduit directement la commande du hook (au lieu d'installer et
déclencher un hook) pour générer ce fichier une fois par run.
