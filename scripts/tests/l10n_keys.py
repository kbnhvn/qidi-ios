#!/usr/bin/env python3
"""Chaque texte français passé à L10n.t("…") dans l'app doit avoir une entrée anglaise
(sinon l'interface anglaise affiche du français) et le dictionnaire n'a pas de doublon."""
import collections
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2] / "ios" / "QSlicerPad"
l10n = (root / "Core" / "L10n.swift").read_text(encoding="utf-8")
keys = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', l10n, re.M)

errors = []
for key, count in collections.Counter(keys).items():
    if count > 1:
        errors.append(f"clé en double : {key!r}")

known = set(keys)
for path in sorted(root.rglob("*.swift")):
    if path.name == "L10n.swift":
        continue
    for m in re.finditer(r'L10n\.t\("((?:[^"\\]|\\.)*)"\)', path.read_text(encoding="utf-8")):
        if m.group(1) not in known:
            errors.append(f"{path.name} : pas de traduction anglaise pour {m.group(1)!r}")

if errors:
    print("\n".join(errors[:20]))
    sys.exit(1)
print(f"{len(known)} entrées, toutes les clés utilisées sont traduites")
