#!/usr/bin/env bash
# Script de démarrage générique -- télécharge un squelette de TP,
# le décompresse, se place dans le dossier obtenu, puis se supprime
# lui-même. Un seul exemplaire de ce script sert pour tous les TP
# (l'URL de l'archive lui est passée en paramètre) : rien à dupliquer ni
# à maintenir par TP.
#
# À UTILISER AVEC : source script_demarrage.sh <URL_DU_ZIP>
# (jamais "bash script_demarrage.sh" ni "./script_demarrage.sh" : le "cd"
# final ne resterait pas actif dans votre terminal une fois le script
# terminé, car il tournerait dans un sous-shell séparé.)
#
# Publié tel quel (une seule fois, à la racine du site) par
# scripts/build_pdfs.sh ; la commande à copier-coller est générée par
# scripts/gen_index.py à partir du marqueur .squelette d'un TP.

_sd_url="$1"
_sd_self="${BASH_SOURCE[0]}"

if [ -z "$_sd_url" ]; then
    echo "✗ Usage : source script_demarrage.sh <URL_DU_ZIP>"
    unset _sd_url _sd_self
    return 1 2>/dev/null || exit 1
fi

_sd_archive="$(basename "$_sd_url")"
_sd_dir="${_sd_archive%.zip}"

echo "→ Téléchargement de $_sd_archive..."
if ! _sd_out=$(wget "$_sd_url" -O "$_sd_archive" 2>&1); then
    echo "✗ Échec du téléchargement :"
    echo "$_sd_out"
    rm -f "$_sd_archive"
    unset _sd_url _sd_self _sd_archive _sd_dir _sd_out
    return 1 2>/dev/null || exit 1
fi

echo "→ Décompression..."
if ! _sd_out=$(unzip -o "$_sd_archive" 2>&1); then
    echo "✗ Échec de la décompression :"
    echo "$_sd_out"
    unset _sd_url _sd_self _sd_archive _sd_dir _sd_out
    return 1 2>/dev/null || exit 1
fi

echo "→ Suppression de l'archive..."
rm -f "$_sd_archive"

if [ -d "$_sd_dir" ]; then
    cd "$_sd_dir"
    echo "→ Terminé ! Vous êtes maintenant dans $(pwd)."
else
    echo "→ Terminé, mais le dossier $_sd_dir est introuvable : vous restez dans $(pwd)."
fi

echo "→ Suppression du script de démarrage..."
rm -f -- "$_sd_self"

unset _sd_url _sd_self _sd_archive _sd_dir _sd_out
