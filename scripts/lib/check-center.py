#!/usr/bin/env python3
"""Vérifie que l'objet imprimé est centré sur le plateau.

Usage : check-center.py "CENTER=110.000,110.000" <x_attendu> <y_attendu> <tolérance_mm>
Échoue si le centre est absent ou hors tolérance.
"""
import sys

if len(sys.argv) < 5:
    sys.exit("usage: check-center.py 'CENTER=x,y' x y tolerance")

raw, expect_x, expect_y, tol = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
if not raw or "=" not in raw or "," not in raw:
    sys.exit(f"centre introuvable dans le G-code (reçu : {raw!r})")

x, y = (float(v) for v in raw.split("=", 1)[1].split(",", 1))
if abs(x - expect_x) > tol or abs(y - expect_y) > tol:
    sys.exit(f"objet mal centré : {raw} (attendu {expect_x:g},{expect_y:g} ±{tol:g} mm)")

print(f"    centré : {x:g},{y:g} (attendu {expect_x:g},{expect_y:g})")
