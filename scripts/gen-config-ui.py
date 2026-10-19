#!/usr/bin/env python3
"""Génère les ressources de l'écran « tous les réglages » depuis les sources QIDISlicer.

Entrées (révision épinglée, third_party/qidislicer ou --src) :
  src/slic3r/GUI/Tab.cpp                       pages, groupes et lignes des onglets
  src/libslic3r/PrintConfig.cpp                définitions d'options (contrôle de couverture)
  resources/localization/fr/QIDISlicer_fr.po   traductions françaises

Sorties (ios/QSlicerPad/Resources/config/) :
  config_pages.json   {"tabs":[{"id","title","pages":[{"title","groups":[{"title","lines":[{"label","keys"}]}]}]}]}
  config_fr.json      {msgid: msgstr} restreint aux textes de l'interface des réglages

Le schéma (type, libellé, aide, bornes, énumérations, mode) vient du moteur à
l'exécution (qsid_config_schema) : seule la *disposition* est extraite ici, car elle
n'existe que dans le code de la GUI wxWidgets, qu'on ne porte pas.

    python3 scripts/gen-config-ui.py [--src third_party/qidislicer] [--check]
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "ios/QSlicerPad/Resources/config"

TABS = [
    # (id, titre, fonction de Tab.cpp)
    ("print", "Réglages d'impression", "void TabPrint::build()"),
    ("filament", "Réglages du filament", "void TabFilament::build()"),
    ("printer", "Réglages de l'imprimante", "void TabPrinter::build_fff()"),
]

RE_PAGE = re.compile(r'add_options_page\(\s*L\("([^"]+)"\)')
RE_GROUP = re.compile(r'new_optgroup\(\s*L\("([^"]+)"\)')
RE_SINGLE = re.compile(r'append_single_option_line\(\s*"([a-z0-9_]+)"')
RE_SINGLE_VAR = re.compile(r'append_single_option_line\(\s*option\s*\)')
RE_GET_OPTION = re.compile(r'get_option\(\s*"([a-z0-9_]+)"')
RE_LINE_START = re.compile(r'(?:Line\s+)?line\s*(?:=\s*|)\{\s*L\("([^"]*)"\)')
RE_LINE_EMPTY = re.compile(r'(?:Line\s+)?line\s*(?:=\s*|)\{\s*""')
RE_NEAR = re.compile(r'create_line_with_(?:near_label_)?widget\(\s*\w+\s*,\s*"([a-z0-9_]+)"')
RE_APPEND_LINE = re.compile(r'append_line\(\s*line\s*\)')


def function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth, i = 0, brace
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[brace:i + 1]
        i += 1
    raise ValueError(signature)


def parse_tab(body: str):
    pages = []
    page = group = line = None
    last_key = None
    for raw in body.splitlines():
        code = raw.split("//")[0]
        m = RE_PAGE.search(code)
        if m:
            page = {"title": m.group(1), "groups": []}
            pages.append(page)
            group = line = None
            continue
        m = RE_GROUP.search(code)
        if m and page is not None:
            group = {"title": m.group(1), "lines": []}
            page["groups"].append(group)
            line = None
            continue
        if group is None:
            continue

        m = RE_LINE_START.search(code)
        if m:
            line = {"label": m.group(1), "keys": []}
        elif RE_LINE_EMPTY.search(code):
            line = {"label": "", "keys": []}

        for key in RE_GET_OPTION.findall(code):
            last_key = key
            if line is not None and "append_option" in code:
                line["keys"].append(key)

        if RE_APPEND_LINE.search(code) and line is not None:
            if line["keys"]:
                group["lines"].append(line)
            line = None
            continue
        m = RE_SINGLE.search(code)
        if m:
            group["lines"].append({"label": "", "keys": [m.group(1)]})
            continue
        if RE_SINGLE_VAR.search(code) and last_key:
            group["lines"].append({"label": "", "keys": [last_key]})
            continue
        m = RE_NEAR.search(code)
        if m:
            group["lines"].append({"label": "", "keys": [m.group(1)]})
    # pages / groupes vides (widgets personnalisés) retirés
    for p in pages:
        p["groups"] = [g for g in p["groups"] if g["lines"]]
    return [p for p in pages if p["groups"]]


def parse_po(path: pathlib.Path, wanted_refs):
    """{msgid: msgstr} des entrées référencées par l'un des fichiers voulus."""
    entries, cur, field = [], None, None

    def unquote(s):
        s = s.strip()[1:-1]
        return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)

    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#:"):
            if cur is None or cur.get("done"):
                cur = {"refs": [], "msgid": "", "msgstr": "", "fuzzy": False}
                entries.append(cur)
            cur["refs"].append(line[2:])
        elif line.startswith("#,") and cur is not None and "fuzzy" in line:
            cur["fuzzy"] = True
        elif line.startswith("msgid "):
            if cur is None or cur.get("done") or cur["msgid"]:
                cur = {"refs": [], "msgid": "", "msgstr": "", "fuzzy": False}
                entries.append(cur)
            cur["msgid"] = unquote(line[6:])
            field = "msgid"
        elif line.startswith("msgstr "):
            cur["msgstr"] = unquote(line[7:])
            field = "msgstr"
        elif line.startswith('"') and cur is not None and field:
            cur[field] += unquote(line)
        elif not line.strip() and cur is not None:
            cur["done"] = True
            field = None
    out = {}
    for e in entries:
        if not e["msgid"] or not e["msgstr"] or e["fuzzy"]:
            continue
        refs = " ".join(e["refs"])
        if any(w in refs for w in wanted_refs):
            out[e["msgid"]] = e["msgstr"]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(ROOT / "third_party/qidislicer"))
    ap.add_argument("--check", action="store_true", help="vérifie que les fichiers générés sont à jour")
    args = ap.parse_args()
    src = pathlib.Path(args.src)
    tab_cpp = (src / "src/slic3r/GUI/Tab.cpp").read_text(encoding="utf-8")
    cfg_cpp = (src / "src/libslic3r/PrintConfig.cpp").read_text(encoding="utf-8")
    defined = set(re.findall(r'this->add(?:_nullable)?\(\s*"([a-z0-9_]+)"', cfg_cpp))

    tabs = []
    for tab_id, title, signature in TABS:
        pages = parse_tab(function_body(tab_cpp, signature))
        tabs.append({"id": tab_id, "title": title, "pages": pages})

    unknown = sorted({k for t in tabs for p in t["pages"] for g in p["groups"]
                      for l in g["lines"] for k in l["keys"] if k not in defined})
    n_keys = sum(len(l["keys"]) for t in tabs for p in t["pages"] for g in p["groups"] for l in g["lines"])
    print(f"config_pages.json : {sum(len(t['pages']) for t in tabs)} pages, {n_keys} options "
          f"({', '.join(t['id'] + ':' + str(len(t['pages'])) for t in tabs)})")
    if unknown:
        print("options de la GUI absentes de PrintConfig.cpp :", ", ".join(unknown))

    fr = parse_po(src / "resources/localization/fr/QIDISlicer_fr.po",
                  ("PrintConfig.cpp", "GUI/Tab.cpp", "PresetHints.cpp", "ConfigManipulation.cpp"))
    print(f"config_fr.json    : {len(fr)} textes")

    pages_text = json.dumps({"tabs": tabs}, ensure_ascii=False, indent=1) + "\n"
    fr_text = json.dumps(fr, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    if args.check:
        ok = (OUT / "config_pages.json").read_text() == pages_text and (OUT / "config_fr.json").read_text() == fr_text
        print("à jour" if ok else "OBSOLÈTE : relancer scripts/gen-config-ui.py")
        return 0 if ok else 1
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "config_pages.json").write_text(pages_text)
    (OUT / "config_fr.json").write_text(fr_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
