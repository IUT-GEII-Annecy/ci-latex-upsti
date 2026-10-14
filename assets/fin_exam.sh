#!/usr/bin/env bash
# Script de fin d'évaluation -- fait le submit50, cache les fichiers de
# l'évaluation (tels qu'ils ont été laissés par l'étudiant), puis
# restaure le contenu qui avait été mis à l'abri par
# script_demarrage_exam.sh dans .archive/.
#
# À UTILISER AVEC : source fin_exam.sh <SLUG_SUBMIT50>
# (jamais "bash fin_exam.sh" ni "./fin_exam.sh" : le script doit pouvoir
# s'auto-supprimer en fin d'exécution, comme script_demarrage.sh/
# script_demarrage_exam.sh -- un sous-shell séparé ne change rien ici,
# mais on garde la même convention d'usage pour tous ces scripts.)
#
# Publié tel quel (une seule fois, à la racine du site) par
# scripts/build_pdfs.sh ; la commande à copier-coller est générée par
# scripts/gen_index.py à partir du marqueur .fin_exam d'une évaluation.

_fe_slug="$1"
_fe_self="${BASH_SOURCE[0]}"

if [ -z "$_fe_slug" ]; then
    echo "✗ Usage : source fin_exam.sh <SLUG_SUBMIT50>"
    unset _fe_slug _fe_self
    return 1 2>/dev/null || exit 1
fi

if [ ! -d ".archive" ]; then
    echo "✗ Aucun dossier .archive trouvé ici -- cette évaluation ne semble pas avoir été démarrée avec script_demarrage_exam.sh. Rien n'a été fait."
    unset _fe_slug _fe_self
    return 1 2>/dev/null || exit 1
fi

echo "→ Soumission (submit50 $_fe_slug)..."
submit50 "$_fe_slug"

_fe_hide="archive_exam"
_fe_suffix=""
_fe_i=1
while [ -e ".${_fe_hide}${_fe_suffix}" ]; do
    _fe_suffix="_$_fe_i"
    _fe_i=$((_fe_i + 1))
done
_fe_hide=".${_fe_hide}${_fe_suffix}"

echo "→ Mise à l'abri des fichiers de l'évaluation dans $_fe_hide/..."
mkdir -- "$_fe_hide"
for _fe_entry in * ; do
    [ -e "$_fe_entry" ] || continue
    [ "$_fe_entry" = "$(basename -- "$_fe_self")" ] && continue
    mv -- "$_fe_entry" "$_fe_hide/"
done

echo "→ Restauration du contenu mis à l'abri avant l'évaluation..."
mv -- .archive/* . 2>/dev/null
rmdir ".archive" 2>/dev/null

echo "→ Terminé !"

echo "→ Suppression du script de fin d'évaluation..."
rm -f -- "$_fe_self"

unset _fe_slug _fe_self _fe_hide _fe_suffix _fe_i _fe_entry
