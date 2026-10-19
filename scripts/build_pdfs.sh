#!/bin/bash
# Compile tous les documents "publiables" du repo en PDF et prépare le
# contenu du site (_site/) pour publication sur GitHub Pages.
#
# Script COMMUN à tous les dépôts de supports UPSTI (voir README.md de ce
# dépôt) : les exclusions spécifiques à un dépôt se déclarent via la
# variable d'environnement CI_EXCLUDE_PATTERNS (voir plus bas), pas par
# une copie modifiée de ce script.
#
# Exclusions toujours actives (convention commune à tous les dépôts) :
#   - tout fichier/dossier dont un composant de chemin contient ".eval"
#     (ex: ctrl1.eval/, xxx.eval.tex) : évaluation, jamais publiée.
#   - tout chemin contenant un composant ".hide" ou ".old".
#
# CI_EXCLUDE_PATTERNS (optionnelle) : motifs grep -E supplémentaires,
# un par ligne, chacun retirant les chemins qui le matchent (ex. dossiers
# d'évaluations spécifiques à un dépôt, travaux d'étudiants nominatifs).
#
# Usage: ./scripts/build_pdfs.sh [dossier_de_sortie]
# Doit être lancé depuis la racine du repo à publier.

set -u

OUT_DIR="${1:-_site}"
FAILED=()
BUILT=()
CORRIGES=()
PROF_CORRIGES=()
SOLUTIONS=()
PROF_SOLUTIONS=()
SQUELETTE_URLS=()
SUBMIT50_CMDS=()
EXAM_DOCS=()
FIN_EXAM_CMDS=()
NEXT_RELEASE_DOCS=()
NO_PDF_DOCS=()

# Dossier où le dépôt "solutions" (archives de code pour les solutions de
# TP) a été checkouté par le workflow appelant, s'il l'a été -- voir
# marqueur .solution plus bas. Absent (dossier inexistant) = fonctionnalité
# simplement ignorée, aucune erreur.
SOLUTIONS_SRC="${SOLUTIONS_SRC:-_solutions-src}"

# La fonctionnalité "script de démarrage / solution de TP en commande à
# copier" est spécifique à certains dépôts (ex. supports-informatique,
# étudiants en IDE cs50) : ce script étant commun à tous les dépôts de
# supports UPSTI, elle reste désactivée par défaut et n'agit que si le
# dépôt appelant l'active explicitement (input enable-tp-downloads du
# workflow réutilisable). Désactivée : les marqueurs .squelette/.solution/
# .solution-prof sont ignorés même s'ils sont présents.
ENABLE_TP_DOWNLOADS="${ENABLE_TP_DOWNLOADS:-false}"

# Script de démarrage générique (télécharge un squelette, le décompresse,
# s'y place, se supprime) : un seul exemplaire pour tous les TP, publié
# une fois à la racine du site -- voir assets/script_demarrage.sh dans ce
# même dépôt. $0 est le chemin de CE script (scripts/build_pdfs.sh), donc
# son dossier parent contient toujours assets/ à côté de scripts/, que ce
# dépôt soit checkouté comme _ci-common (voir build-pdfs.yml) ou appelé
# directement en local.
SCRIPT_DEMARRAGE_SRC="$(dirname "$0")/../assets/script_demarrage.sh"
# Variante "évaluation" (archive le contenu existant avant de déployer
# les fichiers de l'épreuve, voir marqueur .exam ci-dessous) et script
# de fin d'évaluation (submit50 + cache les fichiers + désarchive, voir
# marqueur .fin_exam) -- publiés uniquement si au moins une évaluation
# les utilise, comme SCRIPT_DEMARRAGE_SRC.
SCRIPT_DEMARRAGE_EXAM_SRC="$(dirname "$0")/../assets/script_demarrage_exam.sh"
FIN_EXAM_SRC="$(dirname "$0")/../assets/fin_exam.sh"

# --- Aperçu next-release (prof-preview uniquement) ----------------------
# Quand une branche next-release existe et modifie le dossier d'un
# document, sa version à venir est compilée et ajoutée SEULEMENT sur
# prof-preview, à côté de la version actuelle (publique) qui reste
# affichée telle quelle -- jamais publiée aux étudiants. Purement
# opportuniste : sans cette branche (ou désactivé), aucun effet.
PREVIEW_NEXT_RELEASE="${PREVIEW_NEXT_RELEASE:-true}"
NEXT_RELEASE_SRC=""
if [ "$PREVIEW_NEXT_RELEASE" = "true" ]; then
  if git fetch origin next-release >/tmp/next_release_fetch.log 2>&1 \
     && git show-ref --verify --quiet refs/remotes/origin/next-release; then
    if git worktree add --detach _next-release-src origin/next-release \
         >/tmp/next_release_worktree.log 2>&1; then
      NEXT_RELEASE_SRC="_next-release-src"
      echo "→ Branche next-release trouvée : aperçu enseignant activé pour les dossiers modifiés"
    else
      echo "⚠ Branche next-release trouvée mais worktree impossible à préparer (voir /tmp/next_release_worktree.log)"
    fi
  fi
fi

# --- Compilation incrémentale ------------------------------------------
# Évite de recompiler un document si aucun commit ne l'a touché depuis la
# dernière fois qu'il a été compilé avec succès. La comparaison se fait
# EXCLUSIVEMENT sur le hash du dernier commit ayant touché son dossier
# (git log -1 --format=%H -- <dossier>), jamais sur une date : un commit
# rejoué/importé peut porter une date ancienne, un rebase peut changer des
# dates sans changer le contenu -- seul le hash du commit qui a réellement
# touché ce chemin en dernier fait foi.
#
# Persisté entre les runs via un cache GitHub Actions (voir build-pdfs.yml)
# monté sur $CACHE_DIR ; absent au premier run ou si non restauré, tout est
# simplement recompilé (fail-open vers la correction, jamais vers la
# vitesse). Invalidé EN BLOC (tous les documents recompilés) si une
# dépendance partagée a changé : le paquet UPSTI, les scripts
# ci-latex-upsti eux-mêmes, ou tout fichier preamble*.tex/*.cls/*.sty du
# dépôt -- inclus par plusieurs documents via \input, donc jamais détecté
# par un "git log" scopé au dossier d'UN SEUL document.
CACHE_DIR="${BUILD_CACHE_DIR:-.build-cache}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-true}"
FORCE_FULL_REBUILD="${FORCE_FULL_REBUILD:-false}"
mkdir -p "$CACHE_DIR/by-dir"
CACHE_HITS=0

global_deps_hash() {
  {
    echo "upsti:${UPSTI_SHA:-}"
    echo "ci-common:${CI_COMMON_SHA:-}"
    find . -type f \( -name 'preamble*.tex' -o -name '*.cls' -o -name '*.sty' \) \
      -not -path "./$CACHE_DIR/*" -print0 2>/dev/null \
      | sort -z \
      | xargs -0 -I{} git log -1 --format='%H {}' -- {}
  } | sha256sum | cut -d' ' -f1
}

GLOBAL_DEPS_HASH=$(global_deps_hash)
CACHE_USABLE=false
if [ "$INCREMENTAL_BUILD" = "true" ] && [ "$FORCE_FULL_REBUILD" != "true" ]; then
  PREV_GLOBAL_DEPS_HASH=$(cat "$CACHE_DIR/global-deps.sha256" 2>/dev/null || true)
  if [ -n "$PREV_GLOBAL_DEPS_HASH" ] && [ "$GLOBAL_DEPS_HASH" = "$PREV_GLOBAL_DEPS_HASH" ]; then
    CACHE_USABLE=true
    echo "→ Cache de compilation incrémentale utilisable (dépendances partagées inchangées)"
  else
    echo "→ Cache de compilation incrémentale ignoré (absent ou dépendances partagées changées) : recompilation complète"
  fi
else
  echo "→ Compilation incrémentale désactivée (INCREMENTAL_BUILD/FORCE_FULL_REBUILD) : recompilation complète"
fi

# Métadonnées des documents compilés avec succès, une ligne TSV par
# document : type \t seqnum \t numnum \t doc \t dir \t base
# (voir "Numérotation des fichiers publiés" plus bas pour le format final).
COMPILED_META=()

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Liste des documents racine (contiennent \documentclass), hors exclusions.
# grep -v '^\./_' : exclut nos propres dossiers de travail internes
# (_upsti-src, _ci-common, _solutions-src, _next-release-src -- ce dernier
# est un worktree git, déjà en place à ce stade, dont les .tex seraient
# sinon compilés en double comme de faux documents racine).
mapfile -t DOCS < <(
  grep -rl '^\\documentclass' --include='*.tex' . 2>/dev/null \
    | grep -v '\.eval' \
    | grep -v '\.hide' \
    | grep -v '\.old' \
    | grep -v -E '^\./_' \
    | {
        # Applique les motifs d'exclusion additionnels du dépôt appelant,
        # un grep -v par ligne non vide de CI_EXCLUDE_PATTERNS.
        result=$(cat)
        while IFS= read -r pattern; do
          [ -z "$pattern" ] && continue
          result=$(printf '%s\n' "$result" | grep -v -E "$pattern")
        done <<< "${CI_EXCLUDE_PATTERNS:-}"
        printf '%s\n' "$result"
      } \
    | sort
)

# Documents d'évaluation (marqueur EXAM_DIR_PATTERN, ex. "/Evaluations/") :
# jamais publiés sur la page publique ni prof-preview, UNIQUEMENT sur une
# page /exam dédiée (voir gen_index.py), et SEULEMENT s'ils portent un
# marqueur .active dans leur propre dossier -- opt-in explicite, pas juste
# une exclusion d'affichage : un document qui ne matche pas ce motif est
# traité normalement, un document qui le matche mais n'a pas .active est
# RETIRÉ DE LA COMPILATION (jamais même transformé en PDF), pour qu'aucun
# contenu sensible (ex. un sujet AMC avec données d'étudiants réels) ne se
# retrouve jamais accessible par URL directe sur le site publié, même sans
# lien depuis une page. Désactivé par défaut (motif vide = tout passe
# inchangé, comportement strictement identique à avant).
EXAM_DIR_PATTERN="${EXAM_DIR_PATTERN:-}"
EXAM_PAGE_DOCS=()
if [ -n "$EXAM_DIR_PATTERN" ]; then
  FILTERED_DOCS=()
  for doc in "${DOCS[@]}"; do
    if printf '%s' "$doc" | grep -q -E "$EXAM_DIR_PATTERN"; then
      if [ -f "$(dirname "$doc")/.active" ]; then
        FILTERED_DOCS+=("$doc")
        EXAM_PAGE_DOCS+=("$doc")
      else
        echo "→ $doc : correspond à EXAM_DIR_PATTERN mais sans .active -- exclu de la compilation"
      fi
    else
      FILTERED_DOCS+=("$doc")
    fi
  done
  DOCS=("${FILTERED_DOCS[@]}")
fi

echo "→ ${#DOCS[@]} document(s) à compiler"
echo "→ dont ${#EXAM_PAGE_DOCS[@]} document(s) d'évaluation (page /exam uniquement)"

for doc in "${DOCS[@]}"; do
  [ -z "$doc" ] && continue
  dir=$(dirname "$doc")
  base=$(basename "$doc" .tex)
  echo "----------------------------------------"
  echo "Compilation: $doc"

  pdf_path="$dir/$base.pdf"
  cache_dir="$CACHE_DIR/by-dir/$dir"
  # Fingerprint de ce document : hash du dernier commit ayant touché son
  # dossier (jamais une date, voir commentaire en tête de script).
  doc_commit=$(git log -1 --format=%H -- "$dir" 2>/dev/null || true)

  if [ "$CACHE_USABLE" = "true" ] && [ -n "$doc_commit" ] \
     && [ -f "$cache_dir/commit.txt" ] \
     && [ "$(cat "$cache_dir/commit.txt")" = "$doc_commit" ] \
     && [ -f "$cache_dir/$base.pdf" ]; then
    echo "↻ Inchangé depuis $doc_commit -- réutilisation du cache (pas de recompilation)"
    mkdir -p "$dir"
    cp "$cache_dir/$base.pdf" "$pdf_path"
    CACHE_HITS=$((CACHE_HITS + 1))
  else
    # Pas de -halt-on-error : on force latexmk à aller jusqu'au bout même en
    # cas d'erreur récupérable (ex: commande non définie mais non bloquante),
    # comme le ferait un \scrollmode. Un document publié avec un défaut mineur
    # vaut mieux qu'un document absent.
    # NB: latexmk -f pousse jusqu'au bout malgré des erreurs récupérables
    # (macro non définie, référence non résolue...) et son code de sortie
    # reste souvent 1 même quand un PDF complet a bien été produit. On juge
    # donc le succès sur la présence du PDF, pas sur le code de sortie.
    ( cd "$dir" && latexmk -pdf -interaction=nonstopmode -f -g "$base.tex" ) \
      > /tmp/build_${base}.log 2>&1
  fi

  if [ -f "$pdf_path" ]; then
    mkdir -p "$cache_dir"
    cp "$pdf_path" "$cache_dir/$base.pdf"
    echo "$doc_commit" > "$cache_dir/commit.txt"
    # \sequence est défini dans le preamble.tex le plus proche du document
    # (celui-ci, sinon on remonte les dossiers parents).
    seqnum=""
    search_dir="$dir"
    for _ in 1 2 3 4; do
      match=$(grep -horE '\\newcommand\{\\sequence\}\{[0-9]+\}' "$search_dir"/*.tex 2>/dev/null \
        | head -n1 | grep -oE '[0-9]+')
      if [ -n "$match" ]; then
        seqnum="$match"
        break
      fi
      [ "$search_dir" = "." ] && break
      search_dir=$(dirname "$search_dir")
    done

    # Le numéro d'ordre au sein de la séquence est le suffixe numérique de
    # \UPSTInumero, ex : \newcommand{\UPSTInumero}{\sequence.2} -> 2.
    # Sert uniquement, plus bas, à départager l'ordre des lettres a/b/c
    # quand plusieurs documents du même type partagent la même séquence.
    numnum=$(grep -horE '\\newcommand\{\\UPSTInumero\}\{[^}]*\}' "$doc" 2>/dev/null \
      | head -n1 | grep -oE '[0-9]+' | tail -n1)

    # Type de document d'après \documentclass[TYPE, ...]{UPSTI_Document}
    type=""
    case "$(grep -oE '^\\documentclass\[[a-zA-Z]+' "$doc" 2>/dev/null | head -n1)" in
      *TP|*Tutorial) type="TP" ;;
      *td|*TD) type="TD" ;;
      *cours) type="C" ;;
      *QCM) type="QCM" ;;
    esac

    # Séparateur \x1f (Unit Separator) plutôt que tab : seqnum/numnum
    # peuvent être vides (document sans \sequence ou \UPSTInumero), et
    # `IFS=$'\t' read` collapse silencieusement les champs vides
    # consécutifs (tab reste une "IFS white space" pour bash même seul
    # dans IFS) -- \x1f n'a pas ce problème.
    COMPILED_META+=("$type"$'\x1f'"$seqnum"$'\x1f'"$numnum"$'\x1f'"$doc"$'\x1f'"$dir"$'\x1f'"$base")
    echo "OK"
  else
    FAILED+=("$doc")
    echo "ÉCHEC (voir /tmp/build_${base}.log)"
    tail -n 30 "/tmp/build_${base}.log"
  fi
done

# Numérotation des fichiers publiés
# ----------------------------------
# Le nom de fichier suit le numéro de séquence, pas un compteur global
# indépendant : {TYPE}_{séquence sur 2 chiffres}, ex. TD_02, C_03.
# Quand plusieurs documents du même type partagent la même séquence (ex.
# deux TD en séquence 2), on distingue avec une lettre a/b/c... collée au
# numéro (TD_02a, TD_02b), dans l'ordre de \UPSTInumero. Un seul document
# de ce type dans la séquence (cas courant pour les cours) : pas de lettre.
SUFFIXES=()
if [ "${#COMPILED_META[@]}" -gt 0 ]; then
  # Le code Python est passé via -c (et non via un heredoc sur stdin) car
  # stdin doit rester libre pour recevoir le flux TSV à traiter : un
  # heredoc sur "python3 -" occuperait stdin avec le script lui-même et
  # empêcherait le pipe d'y faire parvenir les données.
  PY_ASSIGN_SUFFIXES=$(cat <<'PYEOF'
import sys
from collections import defaultdict

rows = [line.rstrip("\n").split("\x1f") for line in sys.stdin]
groups = defaultdict(list)
for i, row in enumerate(rows):
    type_, seqnum = row[0], row[1]
    if type_ and seqnum:
        groups[(type_, seqnum)].append(i)

suffix = [""] * len(rows)
for idxs in groups.values():
    if len(idxs) <= 1:
        continue

    def sort_key(i):
        numnum = rows[i][2]
        try:
            return (int(numnum), i)
        except ValueError:
            return (10**9, i)

    for rank, i in enumerate(sorted(idxs, key=sort_key)):
        suffix[i] = chr(ord('a') + rank) if rank < 26 else f"_{rank + 1}"

for s in suffix:
    print(s)
PYEOF
  )
  mapfile -t SUFFIXES < <(
    printf '%s\n' "${COMPILED_META[@]}" | cut -d $'\x1f' -f1-3 | python3 -c "$PY_ASSIGN_SUFFIXES"
  )
fi

for i in "${!COMPILED_META[@]}"; do
  IFS=$'\x1f' read -r type seqnum numnum doc dir base <<< "${COMPILED_META[$i]}"
  suffix="${SUFFIXES[$i]:-}"
  pdf_path="$dir/$base.pdf"
  dest="$OUT_DIR/$dir"
  mkdir -p "$dest"

  # Nom de sortie basé sur les variables LaTeX du document (\sequence et
  # le type), et non sur le nom des dossiers : le nom de fichier reste
  # correct même si l'arborescence est réorganisée.
  out_base="$base"
  if [ -n "$seqnum" ] && [ -n "$type" ]; then
    out_base="${type}_$(printf "%02d" "$seqnum")${suffix}_${base}"
  fi
  out_name="$out_base.pdf"

  # Marqueur .no-pdf : le document apparaît sur la page (titre, bouton(s)
  # wget squelette/submit50/fin_exam) mais son PDF n'est PAS publié -- ni
  # copié dans $dest, ni lié. Cas d'usage : une évaluation (page /exam) où
  # seules les commandes de soumission doivent être visibles, pas l'énoncé
  # en PDF téléchargeable. "doc" reste dans BUILT (nécessaire : c'est le
  # seul moyen pour gen_index.py de connaître le titre/la date du
  # document), mais gen_index.py n'affiche pas le lien "Sujet" pour les
  # chemins listés dans --no-pdf-docs -- voir sa docstring. rm -f au cas où
  # un ancien PDF publié traînerait encore d'avant l'ajout du marqueur.
  if [ -f "$dir/.no-pdf" ]; then
    rm -f "$dest/$out_name"
    NO_PDF_DOCS+=("$doc")
    echo "Publié (sans PDF, .no-pdf) : $doc -> $dir/$out_name"
  else
    cp "$pdf_path" "$dest/$out_name"
    echo "Publié : $doc -> $dir/$out_name"
  fi
  BUILT+=("$doc"$'\t'"$dir/$out_name")

  # Recalculés (loop séparée de la compilation : ni cache_dir ni doc_commit
  # ne survivent d'une itération à l'autre entre les deux boucles).
  cache_dir="$CACHE_DIR/by-dir/$dir"
  doc_commit=$(git log -1 --format=%H -- "$dir" 2>/dev/null || true)
  doc_cache_fresh=false
  [ "$CACHE_USABLE" = "true" ] && [ -n "$doc_commit" ] \
    && [ -f "$cache_dir/commit.txt" ] && [ "$(cat "$cache_dir/commit.txt")" = "$doc_commit" ] \
    && doc_cache_fresh=true

  # Correction publique : publiée si un marqueur .corrige a été déposé dans
  # le dossier du document (git add .corrige && git commit && git push).
  # Utilise le mécanisme UPSTI \ChoixDeVersion{P} (voir docs UPSTI), injecté
  # sans modifier le document original.
  if [ -f "$dir/.corrige" ]; then
    wrapper="$dir/${base}__corrige.tex"
    corrige_pdf="$dir/${base}__corrige.pdf"
    corrige_cache="$cache_dir/${base}__corrige.pdf"

    if [ "$doc_cache_fresh" = "true" ] && [ -f "$corrige_cache" ]; then
      echo "  → .corrige inchangé depuis $doc_commit -- réutilisation du cache"
      cp "$corrige_cache" "$corrige_pdf"
    else
      echo "  → marqueur .corrige trouvé, compilation de la version corrigée"
      printf '\\def\\ChoixDeVersion{P}\n\\input{%s.tex}\n' "$base" > "$wrapper"
      ( cd "$dir" && latexmk -pdf -interaction=nonstopmode -f -g "${base}__corrige.tex" ) \
        > "/tmp/build_${base}__corrige.log" 2>&1
    fi

    if [ -f "$corrige_pdf" ]; then
      corrige_out_name="${out_base}__corrige.pdf"
      cp "$corrige_pdf" "$dest/$corrige_out_name"
      CORRIGES+=("$doc"$'\t'"$dir/$corrige_out_name")
      cp "$corrige_pdf" "$corrige_cache"
      echo "  → corrigé OK"
    else
      echo "  → ÉCHEC corrigé (voir /tmp/build_${base}__corrige.log)"
      tail -n 30 "/tmp/build_${base}__corrige.log"
    fi

    # Nettoyage : le wrapper est un artefact de build, jamais commité.
    rm -f "$wrapper" "$dir/${base}__corrige."{aux,log,out,fdb_latexmk,fls,synctex.gz,pdf}

  # Aperçu enseignant : marqueur .corrige-prof, ignoré si .corrige est déjà
  # présent (le document est alors déjà public, l'aperçu n'a plus lieu
  # d'être). Compile et publie la correction comme ci-dessus, mais
  # gen_index.py ne la lie JAMAIS depuis la page publique : elle n'apparaît
  # que sur _site/prof-preview/index.html, une page à part non référencée
  # (voir docstring de gen_index.py -- ce n'est pas un vrai contrôle
  # d'accès, seulement un lien non répertorié).
  elif [ -f "$dir/.corrige-prof" ]; then
    wrapper="$dir/${base}__corrige.tex"
    corrige_pdf="$dir/${base}__corrige.pdf"
    corrige_prof_cache="$cache_dir/${base}__corrige_prof.pdf"

    if [ "$doc_cache_fresh" = "true" ] && [ -f "$corrige_prof_cache" ]; then
      echo "  → .corrige-prof inchangé depuis $doc_commit -- réutilisation du cache"
      cp "$corrige_prof_cache" "$corrige_pdf"
    else
      echo "  → marqueur .corrige-prof trouvé (aperçu enseignant), compilation"
      printf '\\def\\ChoixDeVersion{P}\n\\input{%s.tex}\n' "$base" > "$wrapper"
      ( cd "$dir" && latexmk -pdf -interaction=nonstopmode -f -g "${base}__corrige.tex" ) \
        > "/tmp/build_${base}__corrige_prof.log" 2>&1
    fi

    if [ -f "$corrige_pdf" ]; then
      corrige_prof_out_name="${out_base}__corrige_prof.pdf"
      cp "$corrige_pdf" "$dest/$corrige_prof_out_name"
      PROF_CORRIGES+=("$doc"$'\t'"$dir/$corrige_prof_out_name")
      cp "$corrige_pdf" "$corrige_prof_cache"
      echo "  → corrigé (aperçu enseignant) OK"
    else
      echo "  → ÉCHEC corrigé aperçu (voir /tmp/build_${base}__corrige_prof.log)"
      tail -n 30 "/tmp/build_${base}__corrige_prof.log"
    fi

    rm -f "$wrapper" "$dir/${base}__corrige."{aux,log,out,fdb_latexmk,fls,synctex.gz,pdf}
  fi

  # Aperçu next-release (prof-preview uniquement, voir NEXT_RELEASE_SRC
  # plus haut) : si next-release modifie ce dossier par rapport à la
  # version actuellement publiée (HEAD), compile la version à venir et la
  # publie à côté -- sans jamais remplacer ni cacher la version actuelle,
  # qui reste BUILT/publiée normalement ci-dessus.
  if [ -n "$NEXT_RELEASE_SRC" ] && ! git diff --quiet HEAD origin/next-release -- "$dir" 2>/dev/null; then
    if [ -f "$NEXT_RELEASE_SRC/$doc" ]; then
      echo "  → next-release modifie ce dossier, compilation de l'aperçu"
      ( cd "$NEXT_RELEASE_SRC/$dir" && latexmk -pdf -interaction=nonstopmode -f -g "$base.tex" ) \
        > "/tmp/build_${base}__next_release.log" 2>&1

      next_pdf="$NEXT_RELEASE_SRC/$dir/$base.pdf"
      if [ -f "$next_pdf" ]; then
        next_out_name="${out_base}__next_release.pdf"
        cp "$next_pdf" "$dest/$next_out_name"
        NEXT_RELEASE_DOCS+=("$doc"$'\t'"$dir/$next_out_name")
        echo "  → aperçu next-release OK"
      else
        echo "  → ÉCHEC aperçu next-release (voir /tmp/build_${base}__next_release.log)"
        tail -n 30 "/tmp/build_${base}__next_release.log"
      fi
    else
      echo "  → next-release modifie ce dossier mais $doc n'y existe plus/pas (ignoré)"
    fi
  fi

  if [ "$ENABLE_TP_DOWNLOADS" = "true" ]; then
    # Solution en code (TP) : marqueurs .solution / .solution-prof
    # contenant le sous-dossier à zipper dans le dépôt externe "solutions"
    # (ex: "tp3"). Indépendants de .corrige/.corrige-prof : beaucoup de TP
    # n'ont pas de corrigé PDF du tout, seulement du code à récupérer.
    # .solution-prof est ignoré si .solution est déjà présent (même
    # logique que .corrige-prof).
    if [ -f "$dir/.solution" ] && [ -d "$SOLUTIONS_SRC" ]; then
      sol_subpath=$(tr -d '[:space:]' < "$dir/.solution")
      sol_dir="$SOLUTIONS_SRC/$sol_subpath"
      if [ -z "$sol_subpath" ] || [ ! -d "$sol_dir" ]; then
        echo "  → .solution pointe vers '$sol_subpath', introuvable dans $SOLUTIONS_SRC (ignoré)"
      else
        zip_out_name="${out_base}_solution.zip"
        python3 -c "
import shutil, sys
base = sys.argv[1].removesuffix('.zip')
shutil.make_archive(base, 'zip', sys.argv[2])
" "$dest/$zip_out_name" "$sol_dir"
        SOLUTIONS+=("$doc"$'\t'"$dir/$zip_out_name")
        echo "  → archive solution (publique) : $sol_subpath -> $dir/$zip_out_name"
      fi
    elif [ -f "$dir/.solution-prof" ] && [ -d "$SOLUTIONS_SRC" ]; then
      sol_subpath=$(tr -d '[:space:]' < "$dir/.solution-prof")
      sol_dir="$SOLUTIONS_SRC/$sol_subpath"
      if [ -z "$sol_subpath" ] || [ ! -d "$sol_dir" ]; then
        echo "  → .solution-prof pointe vers '$sol_subpath', introuvable dans $SOLUTIONS_SRC (ignoré)"
      else
        zip_out_name="${out_base}_solution_prof.zip"
        python3 -c "
import shutil, sys
base = sys.argv[1].removesuffix('.zip')
shutil.make_archive(base, 'zip', sys.argv[2])
" "$dest/$zip_out_name" "$sol_dir"
        PROF_SOLUTIONS+=("$doc"$'\t'"$dir/$zip_out_name")
        echo "  → archive solution (aperçu enseignant) : $sol_subpath -> $dir/$zip_out_name"
      fi
    fi

    # Squelette (TP) : marqueur .squelette contenant l'URL complète de
    # l'archive à télécharger (ex. release GitHub du dépôt "squelettes").
    # Le script qui télécharge/décompresse/s'y place est générique et
    # partagé par tous les TP (voir SCRIPT_DEMARRAGE_SRC plus haut,
    # publié une seule fois après cette boucle) : rien à écrire ni à
    # maintenir par TP, juste déclarer son URL. Toujours public : c'est
    # le point de départ de l'exercice, pas une correction.
    if [ -f "$dir/.squelette" ]; then
      squelette_url=$(tr -d '[:space:]' < "$dir/.squelette")
      if [ -n "$squelette_url" ]; then
        SQUELETTE_URLS+=("$doc"$'\t'"$squelette_url")
        echo "  → squelette déclaré : $squelette_url"
      fi
    fi

    # Soumission (TP) : marqueur .submit50 contenant la commande complète
    # à exécuter en fin d'exercice (ex. "submit50 org/exercices/2026/tp1").
    # Pas de templating ni de script générique ici (contrairement à
    # .squelette) : la ligne du marqueur EST la commande affichée telle
    # quelle. Toujours public, comme .squelette.
    if [ -f "$dir/.submit50" ]; then
      submit50_cmd=$(tr -d '\n' < "$dir/.submit50")
      submit50_cmd=$(echo "$submit50_cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ -n "$submit50_cmd" ]; then
        SUBMIT50_CMDS+=("$doc"$'\t'"$submit50_cmd")
        echo "  → submit50 déclaré : $submit50_cmd"
      fi
    fi

    # Mode évaluation (marqueur .exam, simple drapeau -- fichier vide ou
    # non, son contenu n'est pas lu) : le bouton "wget" de .squelette
    # utilise alors script_demarrage_exam.sh (archive le contenu existant
    # avant de déployer les fichiers de l'épreuve) au lieu du générique
    # script_demarrage.sh. Sans effet si .squelette est absent.
    if [ -f "$dir/.exam" ] && [ -f "$dir/.squelette" ]; then
      EXAM_DOCS+=("$doc")
      echo "  → mode évaluation (.exam) activé pour ce squelette"
    fi

    # Fin d'évaluation : marqueur .fin_exam contenant le slug submit50 à
    # transmettre à fin_exam.sh (soumet, cache les fichiers de l'épreuve,
    # restaure ce qui avait été archivé par script_demarrage_exam.sh).
    # Indépendant de .exam : rien n'empêche de ne déclarer que celui-ci.
    if [ -f "$dir/.fin_exam" ]; then
      fin_exam_cmd=$(tr -d '\n' < "$dir/.fin_exam")
      fin_exam_cmd=$(echo "$fin_exam_cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ -n "$fin_exam_cmd" ]; then
        FIN_EXAM_CMDS+=("$doc"$'\t'"$fin_exam_cmd")
        echo "  → fin_exam déclaré : $fin_exam_cmd"
      fi
    fi
  fi
done

# Script de démarrage générique : publié UNE SEULE FOIS à la racine du
# site (pas par TP, voir SCRIPT_DEMARRAGE_SRC plus haut) dès qu'au moins
# un TP en a besoin.
if [ "${#SQUELETTE_URLS[@]}" -gt 0 ]; then
  if [ -f "$SCRIPT_DEMARRAGE_SRC" ]; then
    cp "$SCRIPT_DEMARRAGE_SRC" "$OUT_DIR/script_demarrage.sh"
    echo "Script de démarrage générique publié : $OUT_DIR/script_demarrage.sh"
  else
    echo "⚠ Script de démarrage générique introuvable ($SCRIPT_DEMARRAGE_SRC) -- squelettes déclarés mais aucune commande ne pourra être générée."
  fi
fi

if [ "${#EXAM_DOCS[@]}" -gt 0 ]; then
  if [ -f "$SCRIPT_DEMARRAGE_EXAM_SRC" ]; then
    cp "$SCRIPT_DEMARRAGE_EXAM_SRC" "$OUT_DIR/script_demarrage_exam.sh"
    echo "Script de démarrage (évaluation) publié : $OUT_DIR/script_demarrage_exam.sh"
  else
    echo "⚠ Script de démarrage (évaluation) introuvable ($SCRIPT_DEMARRAGE_EXAM_SRC) -- .exam déclaré mais aucune commande ne pourra être générée."
  fi
fi

if [ "${#FIN_EXAM_CMDS[@]}" -gt 0 ]; then
  if [ -f "$FIN_EXAM_SRC" ]; then
    cp "$FIN_EXAM_SRC" "$OUT_DIR/fin_exam.sh"
    echo "Script de fin d'évaluation publié : $OUT_DIR/fin_exam.sh"
  else
    echo "⚠ Script de fin d'évaluation introuvable ($FIN_EXAM_SRC) -- .fin_exam déclaré mais aucune commande ne pourra être générée."
  fi
fi

# Nettoyage du worktree next-release (l'exécuteur est de toute façon
# éphémère, mais évite un avertissement "already exists" si le job
# réutilisait le même espace de travail).
if [ -n "$NEXT_RELEASE_SRC" ]; then
  git worktree remove --force "$NEXT_RELEASE_SRC" 2>/dev/null || true
fi

# Persiste l'empreinte des dépendances partagées pour le run suivant
# (systématique, que le cache ait servi ou non ce run-ci) -- voir
# actions/cache dans build-pdfs.yml pour la persistance entre runs.
echo "$GLOBAL_DEPS_HASH" > "$CACHE_DIR/global-deps.sha256"

echo "========================================"
echo "Réussis : ${#BUILT[@]}"
echo "  dont réutilisés depuis le cache (inchangés) : $CACHE_HITS"
echo "Échoués : ${#FAILED[@]}"
for f in "${FAILED[@]:-}"; do
  [ -n "$f" ] && echo "  - $f"
done

echo "Corrigés publiés : ${#CORRIGES[@]}"
echo "Corrigés en aperçu enseignant : ${#PROF_CORRIGES[@]}"
echo "Solutions publiées : ${#SOLUTIONS[@]}"
echo "Solutions en aperçu enseignant : ${#PROF_SOLUTIONS[@]}"
echo "Squelettes déclarés : ${#SQUELETTE_URLS[@]}"
echo "Commandes submit50 déclarées : ${#SUBMIT50_CMDS[@]}"
echo "Évaluations en mode .exam : ${#EXAM_DOCS[@]}"
echo "Commandes fin_exam déclarées : ${#FIN_EXAM_CMDS[@]}"
echo "Aperçus next-release : ${#NEXT_RELEASE_DOCS[@]}"
echo "Documents sans PDF publié (.no-pdf) : ${#NO_PDF_DOCS[@]}"

# Génère l'index HTML du site (script commun, voir gen_index.py dans ce
# même dossier -- paramétré par SITE_TITLE/SITE_SUBTITLE/GROUP_LABEL/
# CLASSIFY_MODE, transmis en variables d'environnement par le workflow).
python3 "$(dirname "$0")/gen_index.py" "$OUT_DIR" \
  --built "${BUILT[@]:-}" \
  --failed "${FAILED[@]:-}" \
  --corriges "${CORRIGES[@]:-}" \
  --prof-corriges "${PROF_CORRIGES[@]:-}" \
  --solutions "${SOLUTIONS[@]:-}" \
  --prof-solutions "${PROF_SOLUTIONS[@]:-}" \
  --squelette-urls "${SQUELETTE_URLS[@]:-}" \
  --submit50-cmds "${SUBMIT50_CMDS[@]:-}" \
  --exam-docs "${EXAM_DOCS[@]:-}" \
  --fin-exam-cmds "${FIN_EXAM_CMDS[@]:-}" \
  --exam-page-docs "${EXAM_PAGE_DOCS[@]:-}" \
  --next-release "${NEXT_RELEASE_DOCS[@]:-}" \
  --no-pdf-docs "${NO_PDF_DOCS[@]:-}"

# Code de sortie: on ne fait jamais échouer le job pour un document cassé
# (best-effort : on publie ce qui compile). On échoue seulement si RIEN
# n'a compilé, signe d'un problème d'environnement plus large.
if [ "${#BUILT[@]}" -eq 0 ]; then
  echo "Aucun document compilé, échec du job."
  exit 1
fi
exit 0
