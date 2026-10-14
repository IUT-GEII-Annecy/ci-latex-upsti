#!/usr/bin/env bash
# Script de démarrage pour une évaluation -- comme script_demarrage.sh
# (télécharge un squelette, le décompresse, s'y place, se supprime), mais
# AVANT cela, met tout le contenu visible du dossier courant à l'abri
# dans un sous-dossier caché .archive/, pour qu'il n'apparaisse pas
# pendant l'épreuve (seuls les fichiers de l'évaluation restent
# visibles). Restauré par fin_exam.sh en fin d'épreuve.
#
# À UTILISER AVEC : source script_demarrage_exam.sh <URL_DU_ZIP>
# (jamais "bash script_demarrage_exam.sh" ni "./script_demarrage_exam.sh" :
# le "cd" final ne resterait pas actif dans votre terminal une fois le
# script terminé, car il tournerait dans un sous-shell séparé.)
#
# Publié tel quel (une seule fois, à la racine du site) par
# scripts/build_pdfs.sh ; la commande à copier-coller est générée par
# scripts/gen_index.py à partir des marqueurs .squelette + .exam d'une
# évaluation.

_sde_url="$1"
_sde_self="${BASH_SOURCE[0]}"

if [ -z "$_sde_url" ]; then
    echo "✗ Usage : source script_demarrage_exam.sh <URL_DU_ZIP>"
    unset _sde_url _sde_self
    return 1 2>/dev/null || exit 1
fi

if [ -e ".archive" ]; then
    echo "✗ Un dossier .archive existe déjà ici -- une évaluation a peut-être déjà été démarrée dans ce répertoire. Rien n'a été fait."
    unset _sde_url _sde_self
    return 1 2>/dev/null || exit 1
fi

echo "→ Mise à l'abri du contenu actuel dans .archive/..."
mkdir ".archive"
for _sde_entry in * ; do
    [ -e "$_sde_entry" ] || continue
    [ "$_sde_entry" = "$(basename -- "$_sde_self")" ] && continue
    mv -- "$_sde_entry" ".archive/"
done

_sde_archive="$(basename "$_sde_url")"
_sde_dir="${_sde_archive%.zip}"

echo "→ Téléchargement de $_sde_archive..."
if ! _sde_out=$(wget "$_sde_url" -O "$_sde_archive" 2>&1); then
    echo "✗ Échec du téléchargement :"
    echo "$_sde_out"
    rm -f "$_sde_archive"
    unset _sde_url _sde_self _sde_entry _sde_archive _sde_dir _sde_out
    return 1 2>/dev/null || exit 1
fi

echo "→ Décompression..."
if ! _sde_out=$(unzip -o "$_sde_archive" 2>&1); then
    echo "✗ Échec de la décompression :"
    echo "$_sde_out"
    unset _sde_url _sde_self _sde_entry _sde_archive _sde_dir _sde_out
    return 1 2>/dev/null || exit 1
fi

echo "→ Suppression de l'archive téléchargée..."
rm -f "$_sde_archive"

if [ -d "$_sde_dir" ]; then
    echo "→ Déplacement des fichiers de l'évaluation dans le dossier courant..."
    mv -- "$_sde_dir"/* .
    rmdir -- "$_sde_dir" 2>/dev/null
    echo "→ Terminé ! Les fichiers de l'évaluation sont dans $(pwd)."
else
    echo "→ Terminé, mais le dossier $_sde_dir est introuvable."
fi

echo "→ Suppression du script de démarrage..."
rm -f -- "$_sde_self"

unset _sde_url _sde_self _sde_entry _sde_archive _sde_dir _sde_out
