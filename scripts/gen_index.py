#!/usr/bin/env python3
"""Génère _site/index.html à partir de la liste des documents compilés/échoués.

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

Usage: gen_index.py OUT_DIR "doc1.tex<TAB>rel1.pdf" ... -- failed1.tex ... -- "doc1.tex<TAB>corrige_rel1.pdf" ...
(corrige* = sous-ensemble de built* pour lequel un PDF __corrige a aussi été produit)

Chaque entrée built/corrige est "chemin_tex<TAB>chemin_pdf_reel" : le nom du
PDF (basé sur \\sequence/le type de document, voir build_pdfs.sh) est décidé
une seule fois côté bash puis transmis ici, jamais recalculé.
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

args = sys.argv[1:]
out_dir = Path(args[0])
seps = [i for i, a in enumerate(args) if a == "--"]
sep1 = seps[0] if len(seps) > 0 else len(args)
sep2 = seps[1] if len(seps) > 1 else len(args)


def split_pair(entry):
    doc, _, rel = entry.partition("\t")
    return doc, rel.removeprefix("./")


built = [split_pair(a) for a in args[1:sep1] if a]
failed = [a for a in args[sep1 + 1:sep2] if a]
corriges = dict(split_pair(a) for a in args[sep2 + 1:] if a)

PDF_ICON = """<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" class="pdf-icon">
<path d="M6 2h8l4 4v16H6z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
<path d="M14 2v4h4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
<text x="12" y="16.5" font-size="6.2" font-family="system-ui, sans-serif" font-weight="700" text-anchor="middle" fill="currentColor">PDF</text>
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
    category_of = category_from_folder
else:
    group_of = group_folder
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


rows = defaultdict(lambda: defaultdict(list))  # rows[groupe][catégorie] = [(label, rel_pdf, date), ...]
autres = defaultdict(list)

for doc, rel in built:
    grp = group_of(doc)
    cat = category_of(doc)
    # Le libellé affiché reprend le nom réel du PDF (celui décidé par
    # build_pdfs.sh à partir de \sequence/du type de document), pas le nom
    # du dossier : sinon la page affiche encore l'ancien intitulé alors que
    # le fichier téléchargé, lui, a le bon nom.
    label = Path(rel).stem
    date = version_date(doc)
    if cat == "Autre":
        autres[grp].append((label, rel, date))
    else:
        rows[grp][cat].append((label, rel, date))

    if doc in corriges:
        rows[grp]["Correction"].append((f"{label} (corrigé)", corriges[doc], date))


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


table_rows = []
for grp in sorted(rows):
    cours = cell_html(rows[grp].get("Cours", []))
    td = cell_html(rows[grp].get("TD", []))
    tp = cell_html(rows[grp].get("TP", []))
    correction = cell_html(rows[grp].get("Correction", []))
    table_rows.append(f"""
      <tr>
        <th scope="row">{html.escape(grp)}</th>
        <td>{cours}</td>
        <td>{td}</td>
        <td>{tp}</td>
        <td>{correction}</td>
      </tr>""")

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

page = f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<title>{html.escape(SITE_TITLE)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {{
    --bg: #ffffff;
    --fg: #1a1a1a;
    --muted: #666666;
    --border: #dddddd;
    --row-alt: #f7f7f8;
    --link: #b3121b;
    --link-hover: #7c0c12;
    --empty: #cccccc;
    --failed-fg: #a33333;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg: #14161a;
      --fg: #e8e8e8;
      --muted: #9a9a9a;
      --border: #33363c;
      --row-alt: #1b1e23;
      --link: #ff8a80;
      --link-hover: #ffb3ab;
      --empty: #4a4d53;
      --failed-fg: #ff8a80;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #14161a;
    --fg: #e8e8e8;
    --muted: #9a9a9a;
    --border: #33363c;
    --row-alt: #1b1e23;
    --link: #ff8a80;
    --link-hover: #ffb3ab;
    --empty: #4a4d53;
    --failed-fg: #ff8a80;
  }}
  body {{
    font-family: system-ui, sans-serif;
    max-width: 60rem;
    margin: 2rem auto;
    padding: 0 1rem;
    background: var(--bg);
    color: var(--fg);
  }}
  h1 {{ margin-bottom: 0.2rem; }}
  .subtitle {{ color: var(--muted); margin-top: 0; }}
  .table-wrap {{ overflow-x: auto; }}
  table {{ border-collapse: collapse; width: 100%; margin-bottom: 2rem; }}
  caption {{ caption-side: top; text-align: left; font-weight: 600; margin-bottom: 0.5rem; }}
  th, td {{ border: 1px solid var(--border); padding: 0.6rem 0.8rem; text-align: left; vertical-align: top; }}
  thead th {{ background: var(--row-alt); }}
  tbody th {{ white-space: nowrap; }}
  tbody tr:nth-child(even) {{ background: var(--row-alt); }}
  .pdf-link {{ display: inline-flex; align-items: center; gap: 0.35rem; color: var(--link); text-decoration: none; }}
  .pdf-link:hover {{ color: var(--link-hover); text-decoration: underline; }}
  .pdf-icon {{ flex: none; }}
  .date {{ display: block; margin: 0.1rem 0 0.4rem 1.5rem; color: var(--muted); font-size: 0.8em; }}
  .empty {{ color: var(--empty); }}
  section {{ margin-bottom: 1.5rem; }}
  h2 {{ border-bottom: 1px solid var(--border); padding-bottom: 0.2rem; }}
  .autres-list li {{ margin: 0.3rem 0; }}
  .grp-tag {{ color: var(--muted); font-size: 0.85em; }}
  .failed {{ color: var(--muted); }}
  .failed h2 {{ color: var(--failed-fg); }}
  footer {{ margin-top: 2rem; color: var(--muted); font-size: 0.85em; }}
</style>
</head>
<body>
  <h1>{html.escape(SITE_TITLE)}</h1>
  <p class="subtitle">{html.escape(SITE_SUBTITLE)}</p>
  <div class="table-wrap">
    <table>
      <caption>Tableau des supports</caption>
      <thead>
        <tr><th scope="col">{html.escape(GROUP_LABEL)}</th><th scope="col">Cours</th><th scope="col">TD</th><th scope="col">TP</th><th scope="col">Correction</th></tr>
      </thead>
      <tbody>{''.join(table_rows)}
      </tbody>
    </table>
  </div>
{autres_html}
{failed_html}
  <footer>Généré automatiquement par GitHub Actions.</footer>
</body>
</html>
"""

out_dir.mkdir(parents=True, exist_ok=True)
(out_dir / "index.html").write_text(page, encoding="utf-8")
print(f"index.html généré ({len(built)} document(s), {len(failed)} échec(s), {len(corriges)} corrigé(s))")
