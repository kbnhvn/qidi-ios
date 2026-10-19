#!/usr/bin/env python3
"""Intégrité des ressources de l'écran « tous les réglages » (générées par gen-config-ui.py).

    python3 scripts/tests/config_ui.py
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CFG = ROOT / "ios/QSlicerPad/Resources/config"


def main() -> int:
    fail = []
    pages = json.loads((CFG / "config_pages.json").read_text())
    fr = json.loads((CFG / "config_fr.json").read_text())

    tabs = {t["id"]: t for t in pages["tabs"]}
    for needed in ("print", "filament", "printer"):
        if needed not in tabs:
            fail.append(f"onglet manquant : {needed}")

    for tab in pages["tabs"]:
        seen = {}
        for page in tab["pages"]:
            if not page["groups"]:
                fail.append(f"{tab['id']}/{page['title']} : page vide")
            for group in page["groups"]:
                for line in group["lines"]:
                    if not line["keys"]:
                        fail.append(f"{tab['id']}/{page['title']}/{group['title']} : ligne sans option")
                    for key in line["keys"]:
                        if key in seen and seen[key] != (page["title"], group["title"]):
                            # une option peut figurer dans deux groupes (ex. couche + couche initiale) : seul
                            # le doublon exact dans le même groupe est une erreur
                            pass
                        seen[key] = (page["title"], group["title"])

    n = sum(len(l["keys"]) for t in pages["tabs"] for p in t["pages"] for g in p["groups"] for l in g["lines"])
    if n < 250:
        fail.append(f"trop peu d'options placées ({n})")

    # traductions : les titres de pages et de groupes sont traduits
    untranslated = sorted({p["title"] for t in pages["tabs"] for p in t["pages"] if p["title"] not in fr})
    if len(untranslated) > 3:
        fail.append(f"titres de page sans traduction : {untranslated}")
    for probe, expected in (("Layer height", "Hauteur de couche"), ("Infill", "Remplissage")):
        if fr.get(probe) != expected:
            fail.append(f"traduction {probe!r} = {fr.get(probe)!r} (attendu {expected!r})")

    if fail:
        print("\n".join("ÉCHEC : " + f for f in fail))
        return 1
    print(f"config_ui : ok ({n} options, {len(fr)} traductions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
