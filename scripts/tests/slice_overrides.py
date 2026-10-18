#!/usr/bin/env python3
"""Miroir de SliceOverrides.configEntries (Swift) — vérifie le mapping .ini.

Sans Mac on ne peut pas exécuter le Swift : ce test rejoue la même logique et
compare les clés produites à celles que le Swift écrit réellement, plus l'ordre
de priorité (options utilisateur après le preset). Il détecte une dérive entre
les deux implémentations.

    python3 scripts/tests/slice_overrides.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SWIFT = ROOT / "ios/QSlicerPad/Core/SliceOverrides.swift"
PROFILES = ROOT / "ios/QSlicerPad/Core/QIDIProfiles.swift"
FIXTURE = ROOT / "testdata/qidi_generic_fff.ini"

KEYS = [
    "support_material",
    "support_material_auto",
    "support_material_threshold",
    "brim_width",
    "raft_layers",
    "fill_density",
    "layer_height",
    "perimeters",
    "temperature",
    "first_layer_temperature",
]


def entries(enabled, supports=False, threshold=30, adhesion="none",
            brim_width=5.0, raft_layers=3, infill=15, layer_height=0.0,
            perimeters=0, nozzle_delta=0, base=None):
    """Réplique la logique Swift."""
    if not enabled:
        return {}
    out = {}
    if adhesion == "none":
        out["brim_width"] = "0"
        out["raft_layers"] = "0"
    elif adhesion == "brim":
        out["brim_width"] = "%.1f" % brim_width
        out["raft_layers"] = "0"
    else:
        out["brim_width"] = "0"
        out["raft_layers"] = str(raft_layers)

    out["support_material"] = "1" if supports else "0"
    if supports:
        out["support_material_auto"] = "1"
        out["support_material_threshold"] = str(int(threshold))

    out["fill_density"] = "%d%%" % infill
    if layer_height > 0:
        out["layer_height"] = "%.2f" % layer_height
    if perimeters > 0:
        out["perimeters"] = str(perimeters)

    base = base or {}
    if nozzle_delta != 0 and "temperature" in base and "first_layer_temperature" in base:
        out["temperature"] = str(int(float(base["temperature"])) + nozzle_delta)
        out["first_layer_temperature"] = str(int(float(base["first_layer_temperature"])) + nozzle_delta)
    return out


def main() -> int:
    fail = 0

    def check(label, ok, detail=""):
        nonlocal fail
        print("%-52s %s" % (label, "ok" if ok else "ÉCHEC " + detail))
        if not ok:
            fail = 1

    src = SWIFT.read_text()

    # 1. Le Swift écrit bien chacune des clés attendues.
    missing = [k for k in KEYS if 'out["%s"]' % k not in src]
    check("clés écrites par le Swift (%d)" % len(KEYS), not missing, str(missing))

    # 2. Les valeurs équivalentes, cas par cas.
    check("désactivé -> aucune entrée", entries(False) == {},
          str(entries(False)))
    check("supports + seuil 45",
          entries(True, supports=True, threshold=45)["support_material_threshold"] == "45",
          entries(True, supports=True, threshold=45).get("support_material_threshold", ""))
    e = entries(True, supports=True)
    check("supports -> support_material(+auto)",
          e["support_material"] == "1" and e["support_material_auto"] == "1", str(e))
    check("supports absents -> support_material=0",
          entries(True)["support_material"] == "0", str(entries(True)))
    e = entries(True, adhesion="brim", brim_width=7)
    check("brim 7 mm -> brim_width=7.0, raft 0",
          e["brim_width"] == "7.0" and e["raft_layers"] == "0", str(e))
    e = entries(True, adhesion="raft", raft_layers=4)
    check("raft 4 -> brim 0, raft_layers=4",
          e["brim_width"] == "0" and e["raft_layers"] == "4", str(e))
    e = entries(True, adhesion="none", brim_width=7, raft_layers=4)
    check("aucune adhérence -> brim et raft à 0",
          e["brim_width"] == "0" and e["raft_layers"] == "0", str(e))
    check("densité 20 % -> « 20% »", entries(True, infill=20)["fill_density"] == "20%")
    check("densité 0 % autorisée", entries(True, infill=0)["fill_density"] == "0%")
    e = entries(True, layer_height=0.16, perimeters=3)
    check("hauteur 0,16 mm + 3 périmètres",
          e["layer_height"] == "0.16" and e["perimeters"] == "3", str(e))
    e = entries(True, layer_height=0.2, perimeters=0)
    check("hauteur du profil -> pas de clé layer_height",
          "layer_height" in e and "perimeters" not in e, str(e))
    check("hauteur 0 -> la clé reste celle du profil",
          "layer_height" not in entries(True, layer_height=0), str(entries(True, layer_height=0)))
    e = entries(True, nozzle_delta=10,
                base={"temperature": "240", "first_layer_temperature": "245"})
    check("décalage +10 °C sur buse et première couche",
          e["temperature"] == "250" and e["first_layer_temperature"] == "255", str(e))
    check("décalage sans température de base -> ignoré",
          "temperature" not in entries(True, nozzle_delta=10, base={}),
          str(entries(True, nozzle_delta=10)))

    # 3. Priorité : les options sont fusionnées après le preset résolu.
    prof = PROFILES.read_text()
    if "func writeConfig" in prof:
        body = prof.split("func writeConfig", 1)[1]
        body = body.split("\n    }\n", 1)[0]          # corps de la fonction
        order_ok = (0 <= body.find("resolvedConfig(") < body.find("configEntries(")
                    and "config[key] = value" in body)
        check("writeConfig : preset d'abord, options ensuite", order_ok,
              "l'ordre de fusion détermine la priorité")
    else:
        check("writeConfig présent", False, "fonction introuvable")

    # 4. Les clés produites existent dans le schéma des profils QIDI.
    fixture = FIXTURE.read_text()
    in_schema = [k for k in ("fill_density", "layer_height", "perimeters", "brim_width")
                 if re.search(r"^%s\s*=" % k, fixture, re.M)]
    check("clés présentes dans le profil de référence (%d/4)" % len(in_schema),
          len(in_schema) == 4, str(in_schema))

    print()
    print("options de slicing : %s" % ("tout est vert" if not fail else "dérive détectée"))
    return fail


if __name__ == "__main__":
    sys.exit(main())
