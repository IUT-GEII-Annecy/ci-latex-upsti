#!/usr/bin/env python3
"""Génère _site/index.html (+ _site/prof-preview/index.html) à partir de la
liste des documents compilés/échoués.

Script COMMUN à tous les dépôts de supports UPSTI (voir README.md de ce
dépôt) : ce qui varie d'un dépôt à l'autre est piloté par variables
d'environnement plutôt que par une copie modifiée du script.

Variables d'environnement reconnues (toutes optionnelles, valeurs par
défaut ci-dessous) :
  SITE_TITLE       (def. "Supports pédagogiques - BUT GEII")
  SITE_SUBTITLE    (def. "Tous les supports de cours, TD et TP - GEII IUT Annecy")
  GROUP_LABEL      (def. "Séquence") -- intitulé de la colonne de regroupement
  CLASSIFY_MODE    (def. "documentclass") -- "documentclass" ou "folder" :
    - "documentclass" : la catégorie (Cours/TD/TP) est déduite de l'option
      de \\documentclass (\\documentclass[TP,...]{{UPSTI_Document}}), et le
      regroupement se fait sur le dossier de premier niveau du chemin.
    - "folder" : la catégorie est déduite du nom du dossier contenant le
      document (préfixe "td"/"tp", ou motif "c\\d" pour un cours), et le
      regroupement se fait sur le second segment du chemin (typiquement un
      dossier "SeqNN_Nom" sous un dossier racine de semestre/module).

Usage:
  gen_index.py OUT_DIR
    --built    "doc1.tex<TAB>rel1.pdf" ...
    --failed   doc2.tex ...
    --corriges "doc1.tex<TAB>corrige_rel1.pdf" ...
    --prof-corriges "doc3.tex<TAB>corrige_prof_rel3.pdf" ...
    --solutions "doc1.tex<TAB>solution_rel1.zip" ...
    --prof-solutions "doc3.tex<TAB>solution_prof_rel3.zip" ...
    --squelette-urls "doc1.tex<TAB>https://.../tp1.zip" ...

Chaque entrée --built/--corriges/--prof-corriges/--solutions/--prof-solutions
est "chemin_tex<TAB>chemin_publié_réel" : le nom du fichier publié (basé
sur \\sequence/le type de document, voir build_pdfs.sh) est décidé une
seule fois côté bash puis transmis ici, jamais recalculé.
--squelette-urls est "chemin_tex<TAB>URL_complète" (voir marqueur
.squelette) : une URL externe, pas un chemin publié par ce script.

Cette fonctionnalité entière (solutions/scripts de démarrage) n'est active
que si le dépôt appelant l'a explicitement activée (input
enable-tp-downloads du workflow réutilisable, voir build_pdfs.sh) : elle
ne concerne que certains dépôts (étudiants en IDE cs50), pas tous les
dépôts de supports UPSTI qui partagent ce script.

--corriges / --solutions : correction publique (marqueurs .corrige /
  .solution, indépendants -- un TP peut avoir une solution de code sans
  corrigé PDF), affichée sur la page publique juste à côté du document
  concerné.
--prof-corriges / --prof-solutions : aperçu enseignant (marqueurs
  .corrige-prof / .solution-prof, chacun ignoré si son équivalent public
  est déjà présent), publiés mais JAMAIS liés depuis la page publique --
  uniquement sur _site/prof-preview/index.html, une page à part non
  référencée (ni depuis la page publique, ni indexable par les moteurs de
  recherche, voir robots.txt généré à côté). Ce n'est pas un vrai contrôle
  d'accès : quiconque devine/trouve l'URL peut la consulter. Ne pas y
  déposer les seuls exemplaires de quoi que ce soit de sensible.
--squelette-urls : toujours public (c'est le point de départ de
  l'exercice, pas une correction) -- affiche un bouton "copier la
  commande" à côté de "Sujet". La commande télécharge le script de
  démarrage générique (un seul exemplaire pour tous les TP, voir
  assets/script_demarrage.sh et build_pdfs.sh) PUIS le "source" (pas un
  simple `bash script`), avec cette URL en paramètre : le script se
  charge lui-même de télécharger l'archive, la décompresser, s'y placer
  et se supprimer -- rien à écrire ni maintenir par TP, juste déclarer
  son URL via le marqueur .squelette.
"""
import html
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

SITE_TITLE = os.environ.get("SITE_TITLE", "Supports pédagogiques - BUT GEII")
SITE_SUBTITLE = os.environ.get(
    "SITE_SUBTITLE", "Tous les supports de cours, TD et TP - GEII IUT Annecy"
)
GROUP_LABEL = os.environ.get("GROUP_LABEL", "Séquence")
CLASSIFY_MODE = os.environ.get("CLASSIFY_MODE", "documentclass")
# URL publique de base du site (ex. "https://iut-geii-annecy.github.io/supports-informatique"),
# nécessaire pour construire une commande "wget" absolue pour la solution
# de TP (contrairement à un lien <a href>, une commande collée dans un
# terminal ne peut pas être un chemin relatif à la page). Calculée par le
# workflow appelant (voir build-pdfs.yml) ; si absente, on se rabat sur le
# chemin relatif -- la commande affichée ne fonctionnera pas telle quelle,
# mais reste visible/copiable plutôt que de faire échouer le build.
SITE_BASE_URL = os.environ.get("SITE_BASE_URL", "").rstrip("/")

FLAGS = (
    "--built", "--failed", "--corriges", "--prof-corriges",
    "--solutions", "--prof-solutions", "--squelette-urls",
)

args = sys.argv[1:]
out_dir = Path(args[0])

buckets = {flag: [] for flag in FLAGS}
current = None
for a in args[1:]:
    if a in buckets:
        current = a
        continue
    if current is not None and a:
        buckets[current].append(a)


def split_pair(entry):
    doc, _, rel = entry.partition("\t")
    return doc, rel.removeprefix("./")


built = [split_pair(a) for a in buckets["--built"]]
failed = list(buckets["--failed"])
corriges = dict(split_pair(a) for a in buckets["--corriges"])
prof_corriges = dict(split_pair(a) for a in buckets["--prof-corriges"])
solutions = dict(split_pair(a) for a in buckets["--solutions"])
prof_solutions = dict(split_pair(a) for a in buckets["--prof-solutions"])
# Les URLs de squelette ne passent PAS par split_pair : ce sont des URLs
# externes absolues (jamais de préfixe "./" à retirer), pas des chemins
# publiés par ce script.
squelette_urls = dict(a.partition("\t")[::2] for a in buckets["--squelette-urls"])

PDF_ICON = """<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" class="pdf-icon">
<path d="M6 2h8l4 4v16H6z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
<path d="M14 2v4h4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
<text x="12" y="16.5" font-size="6.2" font-family="system-ui, sans-serif" font-weight="700" text-anchor="middle" fill="currentColor">PDF</text>
</svg>"""

CHECK_ICON = """<svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" class="pdf-icon">
<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.6"/>
<path d="M8 12.5l2.5 2.5L16 9.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>"""

COPY_ICON = """<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true" class="pdf-icon">
<rect x="7" y="3" width="10" height="4" rx="1" fill="none" stroke="currentColor" stroke-width="1.5"/>
<rect x="5" y="5" width="14" height="16" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/>
</svg>"""


def group_folder(doc_path: str) -> str:
    """Dossier de regroupement (mode "documentclass") : premier segment du chemin."""
    parts = [p for p in Path(doc_path).parts if p != "."]
    return parts[0] if parts else doc_path


def group_sequence_folder(doc_path: str) -> str:
    """Dossier de regroupement (mode "folder") : second segment du chemin
    (typiquement "SeqNN_Nom" sous un dossier racine)."""
    parts = [p for p in Path(doc_path).parts if p != "."]
    # ex: ('S1_Initiation_programmation_langageC', 'Seq01_Hello-world', 'tp01-hello-world', 'foo.tex')
    return parts[1] if len(parts) > 2 else parts[0]


def group_dir_folder(doc_path: str) -> str:
    """Chemin (relatif à la racine du dépôt) du dossier de regroupement
    (mode "documentclass") : identique à group_folder, déjà un chemin complet."""
    return group_folder(doc_path)


def group_dir_sequence_folder(doc_path: str) -> str:
    """Chemin (relatif à la racine du dépôt) du dossier de regroupement
    (mode "folder") : les deux premiers segments du chemin, ex.
    "S1_Initiation_programmation_langageC/Seq01_Hello-world"."""
    parts = [p for p in Path(doc_path).parts if p != "."]
    return str(Path(*parts[:2])) if len(parts) > 2 else group_sequence_folder(doc_path)


def category_from_documentclass(doc_path: str) -> str:
    """Classe un document en Cours / TD / TP à partir de l'option de \\documentclass."""
    try:
        text = Path(doc_path).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return "Autre"
    m = re.search(r"^\\documentclass\[\s*([a-zA-Z]+)", text, re.MULTILINE)
    if not m:
        return "Autre"
    opt = m.group(1).lower()
    if opt in ("tp", "tutorial"):
        return "TP"
    if opt == "td":
        return "TD"
    if opt == "cours":
        return "Cours"
    if opt == "qcm":
        return "QCM"
    return "Autre"


def category_from_folder(doc_path: str) -> str:
    """Classe un document en Cours / TD / TP à partir du nom de son dossier."""
    name = Path(doc_path).parent.name.lower()
    if name.startswith("td"):
        return "TD"
    if name.startswith("tp"):
        return "TP"
    if re.match(r"^c\d", name):
        return "Cours"
    return "Autre"


if CLASSIFY_MODE == "folder":
    group_of = group_sequence_folder
    group_dir_of = group_dir_sequence_folder
    category_of = category_from_folder
else:
    group_of = group_folder
    group_dir_of = group_dir_folder
    category_of = category_from_documentclass


def version_date(doc_path: str) -> str:
    """Date du dernier commit touchant le dossier du document (fenêtre limitée
    par le fetch-depth du checkout ; vide si hors fenêtre)."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%ad", "--date=short", "--", str(Path(doc_path).parent)],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip()
    except Exception:
        return ""


# rows[groupe][catégorie] = [entry, ...] -- page publique
# prof_rows : même structure, mais uniquement les entrées ayant un aperçu
# enseignant (corrige_prof/solution_prof) pas encore public -- page à part.
rows = defaultdict(lambda: defaultdict(list))
prof_rows = defaultdict(lambda: defaultdict(list))
autres = defaultdict(list)
group_dirs = {}  # grp -> chemin du dossier de regroupement (pour les marqueurs .active/.corrige-prof)

for doc, rel in built:
    grp = group_of(doc)
    group_dirs.setdefault(grp, group_dir_of(doc))
    cat = category_of(doc)
    # Le libellé affiché reprend le nom réel du PDF (celui décidé par
    # build_pdfs.sh à partir de \sequence/du type de document), pas le nom
    # du dossier : sinon la page affiche encore l'ancien intitulé alors que
    # le fichier téléchargé, lui, a le bon nom.
    label = Path(rel).stem
    date = version_date(doc)
    if cat == "Autre":
        autres[grp].append((label, rel, date))
        continue

    # La correction (PDF) et la solution de code (indépendante, voir
    # .solution/.solution-prof) sont attachées au même document plutôt que
    # listées à part : elles s'affichent juste à côté de son TD/TP/Cours.
    entry = {
        "label": label,
        "rel": rel,
        "date": date,
        "corrige": corriges.get(doc),
        "corrige_prof": prof_corriges.get(doc),
        "solution": solutions.get(doc),
        "solution_prof": prof_solutions.get(doc),
        "squelette_url": squelette_urls.get(doc),
    }
    rows[grp][cat].append(entry)
    if entry["corrige_prof"] or entry["solution_prof"]:
        prof_rows[grp][cat].append(entry)


def cell_html(entries):
    if not entries:
        return '<span class="empty">—</span>'
    parts = []
    for label, rel, date in sorted(entries):
        date_html = f'<span class="date">{html.escape(date)}</span>' if date else ""
        parts.append(
            f'<a class="pdf-link" href="{html.escape(rel)}">{PDF_ICON}'
            f'<span class="label">{html.escape(label)}</span></a>{date_html}'
        )
    return "<br>".join(parts)


def copy_button_html(label, command, tooltip):
    """Bouton "copier la commande" (script de démarrage/solution) : icône +
    libellé court, commande complète visible en bulle au survol/focus
    (voir .d-wrap/.d-popover), copie réellement au clic (voir <script> en
    bas de page) avec confirmation dans une bulle sous le bouton -- pas de
    lien de téléchargement direct, pensé pour un usage en terminal (IDE
    cs50, où un clic de souris ne sert à rien)."""
    return f"""<span class="d-wrap" tabindex="0">
                  <button type="button" class="copy-btn" data-copy="{html.escape(command)}" onclick="uiCopy(this)">
                    {COPY_ICON}<span class="label">{html.escape(label)}</span>
                    <span class="copy-callout"></span>
                  </button>
                  <span class="d-popover">{html.escape(tooltip)}</span>
                </span>"""


def abs_url(rel: str) -> str:
    """URL absolue pour une commande de terminal (wget/source) -- un chemin
    relatif au site ("S1_.../x.zip") ne veut rien dire une fois collé dans
    un terminal, contrairement à un <a href>. Le `prefix` de cat_list_html
    (utile pour les <a href> de la page prof-preview) n'entre pas en jeu
    ici : l'URL absolue est la même quelle que soit la page d'affichage."""
    return f"{SITE_BASE_URL}/{rel}" if SITE_BASE_URL else rel


def cat_list_html(cat_label, entries, prefix="", prof=False):
    """Bloc titré (Cours/TD/TP) listant ses documents ; rien si vide.

    Chaque document affiche son titre, puis "Sujet" (+ éventuellement un
    bouton "copier la commande" pour le script de démarrage, TP), "Corrigé"
    (PDF, si .corrige/.corrige-prof) et un bouton "copier la commande"
    pour "solution" (si .solution/.solution-prof) -- ces deux marqueurs
    sont indépendants, beaucoup de TP n'ont pas de corrigé PDF. La date de
    dernière mise à jour (git) est portée en infobulle (title=...) sur le
    lien du sujet.

    :param prefix: préfixe ajouté devant chaque href (ex. "../" depuis
      prof-preview/index.html, dont les chemins stockés sont relatifs à la
      racine du site).
    :param prof: si True, affiche les liens/commandes d'aperçu enseignant
      (corrige_prof/solution_prof) au lieu des publics -- jamais les deux
      à la fois. Le script de démarrage, toujours public, est inchangé.
    """
    if not entries:
        return ""
    items = []
    for e in sorted(entries, key=lambda e: (e["label"], e["rel"])):
        sujet_title = f' title="Mis à jour le {html.escape(e["date"])}"' if e["date"] else ""
        corrige_rel = e["corrige_prof"] if prof else e["corrige"]
        solution_rel = e["solution_prof"] if prof else e["solution"]

        demarrage_html = ""
        if e["squelette_url"]:
            # Le script de démarrage générique (un seul exemplaire publié
            # pour tout le site, voir assets/script_demarrage.sh) est
            # téléchargé PUIS "source"-é avec l'URL du squelette de ce TP
            # en paramètre -- pas juste exécuté : un script lancé `bash
            # script` tourne dans un sous-shell, ses `cd` ne persistent
            # pas dans le terminal de l'étudiant une fois terminé, alors
            # que `source` l'exécute dans le shell courant (le `cd` vers
            # le dossier décompressé reste actif après coup). Le script
            # se supprime lui-même en fin d'exécution.
            script_url = abs_url("script_demarrage.sh")
            command = f'wget -q {script_url} -O script_demarrage.sh && source script_demarrage.sh "{e["squelette_url"]}"'
            demarrage_html = copy_button_html("wget", command, command)

        corrige_html = ""
        if corrige_rel:
            corrige_label = "Corrigé (aperçu)" if prof else "Corrigé"
            corrige_title = (
                f' title="Corrigé mis à jour le {html.escape(e["date"])}"' if e["date"] else ""
            )
            corrige_html = (
                f'<span class="sep">·</span>'
                f'<a class="doc-corrige" href="{prefix}{html.escape(corrige_rel)}"{corrige_title}>'
                f'{CHECK_ICON}<span class="label">{corrige_label}</span></a>'
            )

        solution_html = ""
        if solution_rel:
            solution_url = abs_url(solution_rel)
            solution_html = (
                f'<span class="sep">·</span>'
                + copy_button_html("solution", f"wget {solution_url}", solution_url)
            )

        items.append(f"""            <li>
              <p class="doc-title">{html.escape(e["label"])}</p>
              <div class="doc-actions">
                <a class="doc-sujet" href="{prefix}{html.escape(e["rel"])}"{sujet_title}>{PDF_ICON}<span class="label">Sujet</span></a>
                {demarrage_html}
                {corrige_html}
                {solution_html}
              </div>
            </li>""")
    items_html = "\n".join(items)
    return f"""
        <div class="cat">
          <h3>{html.escape(cat_label)}</h3>
          <ul>
{items_html}
          </ul>
        </div>"""


def build_sequence_blocks(source_rows, prefix="", prof=False, force_open=False):
    blocks = []
    for grp in sorted(source_rows):
        cats_html = "".join(
            cat_list_html(cat, source_rows[grp].get(cat, []), prefix=prefix, prof=prof)
            for cat in ("Cours", "TD", "TP")
        )
        # Une séquence s'ouvre par défaut si un marqueur .active a été
        # déposé dans son dossier (git add .active && commit && push),
        # sans modifier aucun document LaTeX. La page d'aperçu enseignant
        # est courte et consultée ponctuellement : ses séquences restent
        # toujours dépliées, marqueur .active ou non.
        is_active = force_open or Path(group_dirs[grp], ".active").exists()
        open_attr = " open" if is_active else ""
        blocks.append(f"""
    <details class="seq"{open_attr}>
      <summary>{html.escape(GROUP_LABEL)} : {html.escape(grp)}</summary>
      <div class="cat-list">{cats_html}
      </div>
    </details>""")
    return blocks


def has_wget(source_rows) -> bool:
    """Y a-t-il au moins un bouton "copier la commande" (script de
    démarrage ou solution) quelque part dans ces lignes -- pour n'afficher
    la note explicative que si elle sert à quelque chose."""
    return any(
        e["squelette_url"] or e["solution"] or e["solution_prof"]
        for grp in source_rows for cat in source_rows[grp] for e in source_rows[grp][cat]
    )


sequence_blocks = build_sequence_blocks(rows)
prof_sequence_blocks = build_sequence_blocks(prof_rows, prefix="../", prof=True, force_open=True)

wget_note_html = ""
if has_wget(rows) or has_wget(prof_rows):
    wget_note_html = """
  <div class="site-note">
    <span aria-hidden="true">💡</span>
    <span>Pour chaque TP, vous pouvez copier la commande à côté de
    « Sujet » et la coller dans le terminal de votre environnement cs50 :
    elle télécharge automatiquement le squelette de code, le décompresse
    et vous place dedans — puis, une fois la solution publiée par
    l'enseignant, faites de même avec le bouton « solution ».</span>
  </div>"""

autres_html = ""
if autres:
    items = "\n".join(
        f'      <li>{cell_html([e])} <span class="grp-tag">({html.escape(grp)})</span></li>'
        for grp in sorted(autres) for e in autres[grp]
    )
    autres_html = f"""
    <section>
      <h2>Autres documents</h2>
      <ul class="autres-list">
{items}
      </ul>
    </section>"""

failed_html = ""
if failed:
    items = "\n".join(f"      <li>{html.escape(f)}</li>" for f in sorted(failed))
    failed_html = f"""
    <section class="failed">
      <h2>Non disponibles (échec de compilation)</h2>
      <ul>
{items}
      </ul>
    </section>"""

PAGE_STYLE = """
  :root {
    --bg: #ffffff;
    --fg: #1a1a1a;
    --muted: #666666;
    --border: #dddddd;
    --row-alt: #f7f7f8;
    --link: #b3121b;
    --link-hover: #7c0c12;
    --empty: #cccccc;
    --failed-fg: #a33333;
    --sujet: #1a7a4c;
    --sujet-hover: #135c39;
    --corrige: #b3121b;
    --corrige-hover: #7c0c12;
    --ok: #1a7a4c;
    --ok-bg: #e8f5ee;
    --ok-border: #bfe3cf;
    --banner-bg: #fff4e0;
    --banner-border: #e8c579;
    --banner-fg: #6b4c05;
    --note-bg: #eef3fb;
    --note-border: #c9d9f0;
    --note-fg: #274a7a;
    --mono: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #14161a;
      --fg: #e8e8e8;
      --muted: #9a9a9a;
      --border: #33363c;
      --row-alt: #1b1e23;
      --link: #ff8a80;
      --link-hover: #ffb3ab;
      --empty: #4a4d53;
      --failed-fg: #ff8a80;
      --sujet: #6cd9a0;
      --sujet-hover: #93e6ba;
      --corrige: #ff8a80;
      --corrige-hover: #ffb3ab;
      --ok: #6cd9a0;
      --ok-bg: #16342650;
      --ok-border: #2d5a41;
      --banner-bg: #332a12;
      --banner-border: #6b5412;
      --banner-fg: #edd493;
      --note-bg: #182636;
      --note-border: #2c4d78;
      --note-fg: #a9c6ef;
    }
  }
  :root[data-theme="dark"] {
    --bg: #14161a;
    --fg: #e8e8e8;
    --muted: #9a9a9a;
    --border: #33363c;
    --row-alt: #1b1e23;
    --link: #ff8a80;
    --link-hover: #ffb3ab;
    --empty: #4a4d53;
    --failed-fg: #ff8a80;
    --sujet: #6cd9a0;
    --sujet-hover: #93e6ba;
    --corrige: #ff8a80;
    --corrige-hover: #ffb3ab;
    --ok: #6cd9a0;
    --ok-bg: #16342650;
    --ok-border: #2d5a41;
    --banner-bg: #332a12;
    --banner-border: #6b5412;
    --banner-fg: #edd493;
    --note-bg: #182636;
    --note-border: #2c4d78;
    --note-fg: #a9c6ef;
  }
  body {
    font-family: system-ui, sans-serif;
    max-width: 60rem;
    margin: 2rem auto;
    padding: 0 1rem;
    background: var(--bg);
    color: var(--fg);
  }
  h1 { margin-bottom: 0.2rem; }
  .subtitle { color: var(--muted); margin-top: 0; }
  .site-note {
    display: flex; gap: 0.6rem; align-items: flex-start;
    background: var(--note-bg); border: 1px solid var(--note-border); color: var(--note-fg);
    border-radius: 8px; padding: 0.75rem 1rem; margin: 1rem 0 1.5rem;
    font-size: 0.88rem; line-height: 1.55;
  }
  .site-note code { background: rgba(127,127,127,0.15); border-radius: 3px; padding: 0.03rem 0.3rem; }
  .banner {
    display: flex;
    gap: 0.6rem;
    align-items: flex-start;
    background: var(--banner-bg);
    border: 1px solid var(--banner-border);
    color: var(--banner-fg);
    border-radius: 8px;
    padding: 0.8rem 1rem;
    margin: 0 0 1.5rem;
    font-size: 0.92em;
    line-height: 1.5;
  }
  .banner strong { display: block; margin-bottom: 0.15rem; }
  .sequences { margin-bottom: 2rem; }
  details.seq {
    border: 1px solid var(--border);
    border-radius: 6px;
    margin-bottom: 0.6rem;
    overflow: visible;
  }
  details.seq summary {
    cursor: pointer;
    padding: 0.7rem 1rem;
    font-weight: 600;
    background: var(--row-alt);
    list-style: none;
    border-radius: 6px;
  }
  details.seq[open] summary { border-radius: 6px 6px 0 0; }
  details.seq summary::-webkit-details-marker { display: none; }
  details.seq summary::before {
    content: "▸";
    display: inline-block;
    width: 1em;
    color: var(--muted);
  }
  details.seq[open] summary::before { content: "▾"; }
  details.seq summary:hover { color: var(--link); }
  .cat-list {
    padding: 0.8rem 1rem 1rem;
    display: flex;
    flex-wrap: wrap;
    gap: 1.5rem;
  }
  .cat { min-width: 12rem; }
  .cat h3 { margin: 0 0 0.4rem; font-size: 0.95em; color: var(--muted); }
  .cat ul { margin: 0; padding: 0; list-style: none; }
  .cat li { margin: 0 0 0.9rem; }
  .pdf-link { display: inline-flex; align-items: center; gap: 0.35rem; color: var(--link); text-decoration: none; }
  .pdf-link:hover { color: var(--link-hover); text-decoration: underline; }
  .pdf-icon { flex: none; }
  .date { display: block; margin: 0.1rem 0 0.4rem 1.5rem; color: var(--muted); font-size: 0.8em; }
  .doc-title { margin: 0 0 0.35rem; font-size: 0.92em; font-weight: 600; }
  .doc-actions { display: flex; align-items: center; flex-wrap: wrap; gap: 0.5rem; row-gap: 0.5rem; position: relative; }
  .doc-actions > a, .doc-actions > .d-wrap > button {
    display: inline-flex; align-items: center; gap: 0.3rem;
    font-weight: 700; font-size: 0.9em; text-decoration: none;
  }
  .doc-actions a:hover { text-decoration: underline; }
  .doc-sujet { color: var(--sujet); }
  .doc-sujet:hover { color: var(--sujet-hover); }
  .doc-corrige { color: var(--corrige); }
  .doc-corrige:hover { color: var(--corrige-hover); }
  .sep { color: var(--border); }
  .empty { color: var(--empty); }
  section { margin-bottom: 1.5rem; }
  h2 { border-bottom: 1px solid var(--border); padding-bottom: 0.2rem; }
  .autres-list li { margin: 0.3rem 0; }
  .grp-tag { color: var(--muted); font-size: 0.85em; }
  .failed { color: var(--muted); }
  .failed h2 { color: var(--failed-fg); }
  footer { margin-top: 2rem; color: var(--muted); font-size: 0.85em; }

  /* Boutons "copier la commande" (script de démarrage/solution) : toujours en
     rouge (--corrige), qu'il s'agisse du script de démarrage ou de la solution --
     même famille visuelle que "Corrigé", pour signifier "va chercher du
     code" plutôt qu'un simple lien de téléchargement. */
  .d-wrap { position: relative; display: inline-flex; }
  .copy-btn {
    border: none; background: none; padding: 0; margin: 0;
    font-family: inherit; cursor: pointer; color: var(--corrige);
  }
  .copy-btn:hover { color: var(--corrige-hover); text-decoration: underline; }
  .d-popover {
    position: absolute; bottom: 130%; left: 50%; transform: translateX(-50%);
    background: var(--fg); color: var(--bg);
    font-family: var(--mono); font-size: 0.74rem; font-weight: 400;
    padding: 0.4rem 0.6rem; border-radius: 6px; white-space: nowrap;
    max-width: 22rem; overflow: hidden; text-overflow: ellipsis;
    opacity: 0; pointer-events: none; transition: opacity 0.12s ease; z-index: 4;
  }
  .d-popover::after {
    content: ""; position: absolute; top: 100%; left: 50%; transform: translateX(-50%);
    border: 5px solid transparent; border-top-color: var(--fg);
  }
  .d-wrap:hover .d-popover, .d-wrap:focus-within .d-popover { opacity: 1; }
  .copy-callout {
    position: absolute; top: calc(100% + 0.4rem); left: 0; z-index: 5;
    display: none; align-items: flex-start; gap: 0.4rem;
    background: var(--ok-bg); border: 1px solid var(--ok-border); color: var(--ok);
    border-radius: 7px; padding: 0.5rem 0.7rem;
    font-size: 0.82rem; font-weight: 600; line-height: 1.4;
    max-width: 19rem; white-space: normal;
    box-shadow: 0 2px 10px rgba(0,0,0,0.12);
  }
  .copy-callout.show { display: flex; }
  .copy-callout svg { flex: none; margin-top: 0.1rem; }
  .copy-callout kbd {
    font-family: var(--mono); font-size: 0.85em; font-weight: 600;
    background: var(--bg); border: 1px solid var(--ok-border);
    border-bottom-width: 2px; border-radius: 4px; padding: 0.03rem 0.32rem;
  }
"""

COPY_SCRIPT = """
<script>
function uiCopy(btn) {
  var text = btn.getAttribute('data-copy');
  var callout = btn.querySelector('.copy-callout');
  var show = function () {
    document.querySelectorAll('.copy-callout.show').forEach(function (c) {
      if (c !== callout) c.classList.remove('show');
    });
    callout.innerHTML =
      '<svg width="16" height="16" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 12.5l2.5 2.5L16 9.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
      '<span>Copié ! Collez cette commande dans le terminal (<kbd>Maj</kbd> + <kbd>Inser</kbd>).</span>';
    callout.classList.add('show');
    clearTimeout(btn._t);
    btn._t = setTimeout(function () { callout.classList.remove('show'); }, 4500);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(show, function () { fallbackCopy(text, show); });
  } else {
    fallbackCopy(text, show);
  }
}
function fallbackCopy(text, done) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
  done();
}
document.addEventListener('click', function (e) {
  if (!e.target.closest('.copy-btn')) {
    document.querySelectorAll('.copy-callout.show').forEach(function (c) { c.classList.remove('show'); });
  }
});
</script>
"""


def render_page(title, subtitle, sequence_blocks, banner_html="", note_html="", extra_html="", robots=""):
    robots_tag = f'\n<meta name="robots" content="{html.escape(robots)}">' if robots else ""
    return f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">{robots_tag}
<style>{PAGE_STYLE}</style>
</head>
<body>
{banner_html}  <h1>{html.escape(title)}</h1>
  <p class="subtitle">{html.escape(subtitle)}</p>
{note_html}
  <div class="sequences">{''.join(sequence_blocks)}
  </div>
{extra_html}
  <footer>Généré automatiquement par GitHub Actions.</footer>
{COPY_SCRIPT}</body>
</html>
"""


out_dir.mkdir(parents=True, exist_ok=True)

page = render_page(
    SITE_TITLE, SITE_SUBTITLE, sequence_blocks,
    note_html=wget_note_html,
    extra_html=f"{autres_html}\n{failed_html}",
)
(out_dir / "index.html").write_text(page, encoding="utf-8")

prof_page_written = False
if prof_rows:
    prof_banner = """  <div class="banner">
    <span aria-hidden="true">🔒</span>
    <div>
      <strong>Aperçu enseignant</strong>
      Corrections/solutions pas encore publiées aux étudiants (marqueurs
      .corrige-prof / .solution-prof). Cette page n'est pas un vrai
      contrôle d'accès : quiconque a le lien peut la consulter -- ne pas
      le partager, ne pas le publier ailleurs.
    </div>
  </div>
"""
    prof_page = render_page(
        f"{SITE_TITLE} — Aperçu enseignant",
        "Corrections et solutions pas encore publiées aux étudiants.",
        prof_sequence_blocks,
        banner_html=prof_banner,
        note_html=wget_note_html,
        robots="noindex, nofollow",
    )
    prof_dir = out_dir / "prof-preview"
    prof_dir.mkdir(parents=True, exist_ok=True)
    (prof_dir / "index.html").write_text(prof_page, encoding="utf-8")
    prof_page_written = True

# robots.txt : ceinture et bretelles en plus du <meta robots> ci-dessus --
# décourage les crawlers de suivre/indexer l'aperçu enseignant s'il existe,
# sans jamais le mentionner sur la page publique elle-même.
robots_txt = "User-agent: *\n"
if prof_page_written:
    robots_txt += "Disallow: /prof-preview/\n"
(out_dir / "robots.txt").write_text(robots_txt, encoding="utf-8")

print(
    f"index.html généré ({len(built)} document(s), {len(failed)} échec(s), "
    f"{len(corriges)} corrigé(s), {len(solutions)} solution(s), {len(squelette_urls)} squelette(s))"
    + (f" + prof-preview/index.html ({len(prof_corriges)} corrigé(s), {len(prof_solutions)} solution(s) en aperçu)"
       if prof_page_written else "")
)
