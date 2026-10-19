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

## Marqueurs déposés dans un dossier de document

Ces fichiers vides (ou contenant une seule ligne) se déposent avec
`git add .xxx && git commit && git push`, sans jamais modifier le `.tex`
du document. Vus par `scripts/build_pdfs.sh`, ils déclenchent la
publication conditionnelle décrite ci-dessous ; voir la docstring de
`scripts/gen_index.py` pour le détail du rendu.

- **`.active`** : la séquence correspondante s'affiche dépliée par défaut
  sur la page publique (au lieu de repliée).
- **`.corrige`** : publie la correction (compilation en `\ChoixDeVersion{P}`)
  et l'affiche publiquement à côté du document ("Corrigé").
- **`.corrige-prof`** : comme `.corrige`, mais publie la correction
  uniquement sur une page à part, non listée et non indexable
  (`_site/prof-preview/`, jamais liée depuis la page publique) -- pour
  relire une correction avant de la rendre publique. **Ce n'est pas un
  vrai contrôle d'accès** : n'importe qui connaissant/devinant l'URL peut
  la consulter. Ignoré si `.corrige` est déjà présent.
Les trois marqueurs suivants (`.squelette`, `.solution`,
`.solution-prof`) ne sont pris en compte que si le dépôt appelant a
activé l'input `enable-tp-downloads` (voir plus bas) : cette fonctionnalité
est spécifique aux dépôts dont les étudiants travaillent en IDE cs50
(ex. `supports-informatique`), pas à tous les dépôts partageant ce
workflow -- désactivée par défaut, présents ou non, ces fichiers sont
alors ignorés.

- **`.squelette`** : une ligne contenant l'URL complète du squelette de
  code à télécharger (ex. une release GitHub du dépôt `squelettes`).
  Affiche un bouton "copier la commande" à côté de "Sujet", toujours
  public (c'est le point de départ de l'exercice, pas une correction). La
  commande télécharge un **script de démarrage générique** (un seul
  exemplaire pour tous les TP, `assets/script_demarrage.sh` dans ce
  dépôt, publié une fois à la racine du site) puis le `source` (pas un
  simple `bash script` : un script lancé en sous-shell ne peut pas
  changer le répertoire courant du terminal de l'étudiant, `source` si)
  avec cette URL en paramètre. Le script télécharge l'archive, la
  décompresse, s'y déplace, puis **se supprime lui-même** -- rien à
  écrire ni maintenir par TP.
- **`.solution`** : une ligne contenant le sous-dossier (dans le dépôt
  externe configuré via l'input `solutions-repo`, voir plus bas) à
  compresser en `.zip` et publier à côté du document, sous un bouton
  "copier la commande" (pas un lien de téléchargement direct, pensé pour
  un terminal cs50). **Indépendant** de `.corrige`/`.corrige-prof` :
  beaucoup de TP n'ont pas de corrigé PDF du tout, seulement une solution
  de code.
- **`.solution-prof`** : comme `.solution`, mais publiée uniquement sur
  `_site/prof-preview/` (même principe que `.corrige-prof` -- pas un vrai
  contrôle d'accès). Ignoré si `.solution` est déjà présent.
- **`.submit50`** : une ligne contenant la commande `submit50` complète à
  exécuter en fin d'exercice (ex. `submit50 org/exercices/2026/tp1`).
  Affiche un bouton "copier la commande" à côté de "Sujet", toujours
  public. Contrairement à `.squelette`, pas de templating ni de script
  générique : la ligne du marqueur EST la commande affichée telle quelle.
- **`.exam`** : simple drapeau (fichier vide, son contenu n'est pas lu) à
  déposer À CÔTÉ d'un `.squelette` existant pour basculer son bouton
  "wget" en mode évaluation : au lieu du `script_demarrage.sh` générique,
  la commande générée télécharge et exécute `script_demarrage_exam.sh`,
  qui met D'ABORD tout le contenu déjà présent dans le dossier courant à
  l'abri dans un sous-dossier caché `.archive/` avant de déployer les
  fichiers de l'évaluation -- pour qu'aucun autre TP/correction ne reste
  visible pendant l'épreuve. Sans effet si `.squelette` est absent.
- **`.fin_exam`** : une ligne contenant le slug `submit50` (sans le mot
  `submit50` lui-même, ex. `org/exercices/2026/tp1`) de l'évaluation.
  Affiche un bouton "copier la commande" distinct qui télécharge et
  exécute `fin_exam.sh` : celui-ci fait le `submit50`, met à l'abri (dans
  un dossier caché horodaté si besoin) les fichiers de l'évaluation tels
  que laissés par l'étudiant, puis restaure le contenu archivé par
  `script_demarrage_exam.sh`. Indépendant de `.exam` : rien n'empêche de
  ne déclarer que celui-ci (ex. une évaluation sans téléchargement de
  squelette particulier).
- **`.no-pdf`** : simple drapeau (fichier vide) -- le document apparaît
  normalement sur la page (titre, date) avec ses boutons habituels
  (`.squelette`/`.exam`, `.submit50`, `.fin_exam`), mais **sans lien
  "Sujet"** : son PDF n'est pas publié du tout (ni copié dans `_site`, ni
  lien -- pas seulement masqué). Pensé pour une évaluation sur `_site/exam/`
  où seules les commandes de soumission doivent rester visibles, jamais
  l'énoncé en PDF téléchargeable.

### Page /exam (optionnelle) : publier des évaluations à part, jamais sur la page publique

Même principe que `prof-preview` (page non listée, non indexable, lien à
ne pas partager -- voir `meta robots`/`robots.txt`) mais pour les
évaluations plutôt que les aperçus de correction. Configurer l'input
`exam-dir-pattern` (motif `grep -E`, ex. `/Evaluations/`) : tout document
dont le chemin matche ce motif n'est compilé QUE s'il porte un marqueur
`.active` dans son propre dossier -- sans ce marqueur, il n'est même pas
transformé en PDF (opt-in explicite, pas une simple exclusion d'affichage :
aucun risque qu'un sujet sensible, ex. un examen AMC avec données
d'étudiants réels, se retrouve accessible par URL directe sur le site
publié sans lien). Les documents ainsi compilés n'apparaissent jamais sur
la page publique ni sur `prof-preview` : uniquement sur `_site/exam/`,
avec tous leurs boutons habituels (`.squelette`/`.exam`, `.submit50`,
`.fin_exam`, corrigé, solution...).

```yaml
jobs:
  publish:
    uses: IUT-GEII-Annecy/ci-latex-upsti/.github/workflows/build-pdfs.yml@main
    with:
      exam-dir-pattern: /Evaluations/
    secrets: inherit
```

Vide par défaut (fonctionnalité désactivée, comportement inchangé). Pour
publier une évaluation : déposer `.active` dans son dossier (en plus des
marqueurs `.squelette`/`.exam`/`.submit50`/`.fin_exam` souhaités) ; pour
la dépublier en fin d'épreuve, retirer `.active` (le document redevient
non compilé au prochain build, son PDF précédent n'est pas republié).

### Scripts de démarrage et solutions de TP en commande à copier (optionnel, spécifique cs50)

Les étudiants travaillent en terminal (IDE cs50) : le squelette et la
solution de TP se récupèrent via une commande à copier-coller (téléchargement
+ décompression + déplacement dans le dossier), pas un lien de
téléchargement classique.

```yaml
jobs:
  publish:
    uses: IUT-GEII-Annecy/ci-latex-upsti/.github/workflows/build-pdfs.yml@main
    with:
      enable-tp-downloads: true    # false par défaut -- à activer explicitement
      solutions-repo: IUT-GEII-Annecy/solutions   # vide = solutions désactivées (défaut)
      site-base-url: ""    # vide = calculé automatiquement (https://<owner>.github.io/<repo>) ;
                            # à renseigner seulement avec un domaine personnalisé (CNAME)
    secrets:
      SOLUTIONS_DEPLOY_KEY: ${{ secrets.SOLUTIONS_DEPLOY_KEY }}  # seulement si solutions-repo est privé
      UPSTI_DEPLOY_KEY: ${{ secrets.UPSTI_DEPLOY_KEY }}
```

## Compilation incrémentale

Activée par défaut (input `incremental-build`, `true`) : un document n'est
recompilé que si un commit a touché son dossier depuis la dernière
compilation réussie mise en cache. La comparaison se fait **exclusivement
sur le hash du dernier commit** touchant ce dossier
(`git log -1 --format=%H -- <dossier>`), **jamais sur une date** : un
commit rejoué/importé peut porter une date ancienne, un rebase peut
changer des dates sans changer le contenu.

Le cache (persisté entre runs via `actions/cache`) est invalidé **en
bloc** (tout est recompilé) si une dépendance partagée change : le paquet
UPSTI, les scripts `ci-latex-upsti` eux-mêmes, ou tout fichier
`preamble*.tex`/`*.cls`/`*.sty` du dépôt -- ces fichiers sont inclus par
plusieurs documents via `\input`, donc invisibles à un `git log` scopé au
dossier d'un seul document.

En cas de doute (comportement inattendu, dépendance partagée non
détectée), deux échappatoires :
- `incremental-build: false` désactive complètement la fonctionnalité.
- `force-full-rebuild: true` ignore le cache pour CE run sans l'invalider
  pour les suivants (pratique relié à un `workflow_dispatch` côté dépôt
  appelant pour forcer un rebuild ponctuel à la demande).

## Aperçu des modifications à venir (branche `next-release`)

Quand une branche `next-release` existe sur le dépôt appelant (même dépôt,
aucun secret supplémentaire requis) et qu'elle modifie le dossier d'un
document par rapport à la version publiée (`HEAD`), ce workflow compile
en plus la version à venir de ce document et l'ajoute **uniquement** sur
la page prof-preview (`_site/prof-preview/`) : un badge **EDIT** apparaît à
côté du titre du document, avec un lien "Sujet (modifiée pour l'an
prochain)". La version actuelle reste affichée normalement, sans aucun
changement, sur la page publique comme sur la page prof-preview. Sans
effet si la branche `next-release` n'existe pas.

Activé par défaut (input `preview-next-release`, `true`) ; le désactiver
avec `preview-next-release: false` si cette fonctionnalité n'est pas
souhaitée dans un dépôt donné.

```yaml
jobs:
  publish:
    uses: IUT-GEII-Annecy/ci-latex-upsti/.github/workflows/build-pdfs.yml@main
    with:
      preview-next-release: false   # défaut: true
    secrets: inherit
```

Créer/mettre à jour la branche `next-release` (et y pousser les
modifications à venir) est une décision de contenu propre à chaque dépôt
appelant, indépendante de ce workflow.

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
