#!/usr/bin/env python3
"""Miroir de GCodePreview.parse (Swift) — verrouille la gestion M82/M83.

Régression B1 : les profils QIDI sont en extrusion relative (M83) ; un parseur qui
l'ignore compare chaque E relatif au précédent et perd la majorité des trajectoires.
Le test rejoue la logique du parseur sur un G-code réel en M83 et exige que tous
les mouvements extrudés soient retenus, et vérifie que le Swift contient bien les
mêmes règles (garde contre la dérive entre les deux implémentations).

    python3 scripts/tests/gcode_preview.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SWIFT = ROOT / "ios/QSlicerPad/Core/GCodePreview.swift"
FIXTURE = ROOT / "testdata/cube_relative_e_2layers.gcode"


def parse(lines, honor_mode):
    x = y = 0.0
    absolute_e = True
    last_e = 0.0
    kept = extruded = 0
    for line in lines:
        line = line.rstrip("\n")
        if honor_mode:
            if line.startswith("M83"):
                absolute_e = False
                continue
            if line.startswith("M82"):
                absolute_e = True
                continue
        is_move = line.startswith(("G0 ", "G1 ")) or line in ("G0", "G1")
        if not is_move:
            if line.startswith("G92"):
                value = 0.0
                for tok in line.split(" "):
                    if tok.startswith("E"):
                        try:
                            value = float(tok[1:])
                        except ValueError:
                            value = 0.0
                last_e = value
            continue
        nx, ny, e = x, y, None
        for tok in line.split(" "):
            if not tok:
                continue
            try:
                v = float(tok[1:])
            except ValueError:
                v = None
            if tok[0] == "X" and v is not None:
                nx = v
            elif tok[0] == "Y" and v is not None:
                ny = v
            elif tok[0] == "E":
                e = v
        extruding = False
        if e is not None:
            delta = (e - last_e) if absolute_e else e
            extruding = delta > 0.0001
            last_e = e if absolute_e else last_e + e
        if extruding and (nx != x or ny != y):
            kept += 1
        if e is not None and e > 0 and (nx != x or ny != y):
            extruded += 1
        x, y = nx, ny
    return kept, extruded


def main():
    failures = []
    src = SWIFT.read_text()
    for needle in ('hasPrefix("M83")', 'hasPrefix("M82")', 'hasPrefix("G92")'):
        if needle not in src:
            failures.append(f"GCodePreview.swift ne gère plus {needle}")
    if 'hasPrefix("G90") { absoluteE' in src:
        failures.append("G90/G91 ne doivent pas régler le mode d'extrusion (Klipper)")

    lines = FIXTURE.read_text().splitlines()
    kept, extruded = parse(lines, honor_mode=True)
    if extruded == 0:
        failures.append("fixture sans mouvement extrudé")
    elif kept != extruded:
        failures.append(f"M83 pris en compte : {kept}/{extruded} segments retenus (attendu : tous)")
    blind, _ = parse(lines, honor_mode=False)
    if blind >= extruded:
        failures.append("la fixture ne détecte plus la régression (E relatif ignoré = même résultat)")

    if failures:
        print("\n".join("ÉCHEC : " + f for f in failures))
        return 1
    print(f"gcode_preview : ok ({kept}/{extruded} segments ; sans M83 : {blind})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
