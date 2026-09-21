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

# Métadonnées des documents compilés avec succès, une ligne TSV par
# document : type \t seqnum \t numnum \t doc \t dir \t base
# (voir "Numérotation des fichiers publiés" plus bas pour le format final).
COMPILED_META=()

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Liste des documents racine (contiennent \documentclass), hors exclusions.
mapfile -t DOCS < <(
  grep -rl '^\\documentclass' --include='*.tex' . 2>/dev/null \
    | grep -v '\.eval' \
    | grep -v '\.hide' \
    | grep -v '\.old' \
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

echo "→ ${#DOCS[@]} document(s) à compiler"

for doc in "${DOCS[@]}"; do
  [ -z "$doc" ] && continue
  dir=$(dirname "$doc")
  base=$(basename "$doc" .tex)
  echo "----------------------------------------"
  echo "Compilation: $doc"

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

  pdf_path="$dir/$base.pdf"
  if [ -f "$pdf_path" ]; then
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

    COMPILED_META+=("$type"$'\t'"$seqnum"$'\t'"$numnum"$'\t'"$doc"$'\t'"$dir"$'\t'"$base")
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

rows = [line.rstrip("\n").split("\t") for line in sys.stdin]
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
    printf '%s\n' "${COMPILED_META[@]}" | cut -f1-3 | python3 -c "$PY_ASSIGN_SUFFIXES"
  )
fi

for i in "${!COMPILED_META[@]}"; do
  IFS=$'\t' read -r type seqnum numnum doc dir base <<< "${COMPILED_META[$i]}"
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

  cp "$pdf_path" "$dest/$out_name"
  BUILT+=("$doc"$'\t'"$dir/$out_name")
  echo "Publié : $doc -> $dir/$out_name"

  # Correction : publiée uniquement si un marqueur .corrige a été déposé
  # dans le dossier du document (git add .corrige && git commit && git push).
  # Utilise le mécanisme UPSTI \ChoixDeVersion{P} (voir docs UPSTI), injecté
  # sans modifier le document original.
  if [ -f "$dir/.corrige" ]; then
    echo "  → marqueur .corrige trouvé, compilation de la version corrigée"
    wrapper="$dir/${base}__corrige.tex"
    printf '\\def\\ChoixDeVersion{P}\n\\input{%s.tex}\n' "$base" > "$wrapper"

    ( cd "$dir" && latexmk -pdf -interaction=nonstopmode -f -g "${base}__corrige.tex" ) \
      > "/tmp/build_${base}__corrige.log" 2>&1

    corrige_pdf="$dir/${base}__corrige.pdf"
    if [ -f "$corrige_pdf" ]; then
      corrige_out_name="${out_base}__corrige.pdf"
      cp "$corrige_pdf" "$dest/$corrige_out_name"
      CORRIGES+=("$doc"$'\t'"$dir/$corrige_out_name")
      echo "  → corrigé OK"
    else
      echo "  → ÉCHEC corrigé (voir /tmp/build_${base}__corrige.log)"
      tail -n 30 "/tmp/build_${base}__corrige.log"
    fi

    # Nettoyage : le wrapper est un artefact de build, jamais commité.
    rm -f "$wrapper" "$dir/${base}__corrige."{aux,log,out,fdb_latexmk,fls,synctex.gz,pdf}
  fi
done

echo "========================================"
echo "Réussis : ${#BUILT[@]}"
echo "Échoués : ${#FAILED[@]}"
for f in "${FAILED[@]:-}"; do
  [ -n "$f" ] && echo "  - $f"
done

echo "Corrigés publiés : ${#CORRIGES[@]}"

# Génère l'index HTML du site (script commun, voir gen_index.py dans ce
# même dossier -- paramétré par SITE_TITLE/SITE_SUBTITLE/GROUP_LABEL/
# CLASSIFY_MODE, transmis en variables d'environnement par le workflow).
python3 "$(dirname "$0")/gen_index.py" "$OUT_DIR" "${BUILT[@]:-}" -- "${FAILED[@]:-}" -- "${CORRIGES[@]:-}"

# Code de sortie: on ne fait jamais échouer le job pour un document cassé
# (best-effort : on publie ce qui compile). On échoue seulement si RIEN
# n'a compilé, signe d'un problème d'environnement plus large.
if [ "${#BUILT[@]}" -eq 0 ]; then
  echo "Aucun document compilé, échec du job."
  exit 1
fi
exit 0
