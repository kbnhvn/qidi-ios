#!/usr/bin/env bash
# Gate de slicing : le cœur doit produire un G-code cohérent depuis un cube de
# test, sans GUI et sans sous-processus. C'est la vérification de référence du
# projet (elle tourne sur macOS hôte et dans la CI).
#
#   QSID_TARGET=host scripts/gate.sh
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

[ "$QSID_TARGET" = "host" ] || die "la gate ne s'exécute que sur l'hôte (QSID_TARGET=host)"

gate="$QSID_ENGINE_BUILD/src/ios-core/qidislice_gate"
if [ ! -x "$gate" ]; then
    # Emplacement selon le générateur (Ninja : binaire à plat dans le binaire dir de la cible)
    gate="$(find "$QSID_ENGINE_BUILD" -name qidislice_gate -type f -perm -u+x | head -1 || true)"
fi
[ -x "$gate" ] || die "qidislice_gate introuvable — lancez scripts/build-engine.sh gate"

out="$QSID_BUILD/gate-out"
mkdir -p "$out"

info "gate : cube 20 mm par le chemin v1 (CLI) — référence"
QSID_RESOURCES_DIR="$QSID_SRC/resources" \
QSID_DATA_DIR="$out/data" \
    "$gate" "$QSID_ROOT/testdata/cube_20mm.stl" \
            "$QSID_ROOT/testdata/qidi_generic_fff.ini" \
            "$out/cube_20mm-legacy.gcode" \
            --min-layers 20 --legacy

info "gate : cube 20 mm → G-code (chemin v2 : API objet + progression)"
QSID_RESOURCES_DIR="$QSID_SRC/resources" \
QSID_DATA_DIR="$out/data" \
    "$gate" "$QSID_ROOT/testdata/cube_20mm.stl" \
            "$QSID_ROOT/testdata/qidi_generic_fff.ini" \
            "$out/cube_20mm.gcode" \
            --min-layers 20

info "gate : placement sur le plateau (220x220 dans la config de test)"
center=$(grep -o "CENTER=[0-9.-]*,[0-9.-]*" "$out/cube_20mm.gcode" | head -1)
echo "    $center"
"$QSID_ROOT/scripts/lib/check-center.py" "$center" 110 110 5

info "gate : le modèle est posé sur le plateau quel que soit son Z d'origine (ensure_on_bed)"
for variant in z30 zm5; do
    QSID_RESOURCES_DIR="$QSID_SRC/resources" \
    QSID_DATA_DIR="$out/data" \
        "$gate" "$QSID_ROOT/testdata/cube_20mm_$variant.stl" \
                "$QSID_ROOT/testdata/qidi_generic_fff.ini" \
                "$out/cube_20mm_$variant.gcode" \
                --min-layers 20 >/dev/null
    # Le nom d'objet figure dans des commentaires du G-code : on le normalise.
    sed "s/cube_20mm_$variant/cube_20mm/g" "$out/cube_20mm_$variant.gcode" > "$out/cube_20mm_$variant.norm.gcode"
    cmp -s "$out/cube_20mm.gcode" "$out/cube_20mm_$variant.norm.gcode" \
        || die "cube décalé en Z ($variant) : G-code différent de celui du cube posé (ensure_on_bed absent ?)"
    echo "    $variant : G-code identique au cube posé"
done

info "gate : révision du G-code"
grep -c "^G1" "$out/cube_20mm.gcode" >/dev/null || die "aucun mouvement G1 dans le G-code"
grep -q "G28" "$QSID_BUILD/gate-out/cube_20mm.gcode" || echo "    (note : pas de G28 — le start-gcode générique est minimal)"
tail -5 "$out/cube_20mm.gcode" | sed 's/^/    /'

info "gate OK : $out/cube_20mm.gcode"
