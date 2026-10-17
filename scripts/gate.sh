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

info "gate : cube 20 mm → G-code"
QSID_RESOURCES_DIR="$QSID_SRC/resources" \
QSID_DATA_DIR="$out/data" \
    "$gate" "$QSID_ROOT/testdata/cube_20mm.stl" \
            "$QSID_ROOT/testdata/qidi_generic_fff.ini" \
            "$out/cube_20mm.gcode" \
            --min-layers 20

info "gate : révision du G-code"
grep -c "^G1" "$out/cube_20mm.gcode" >/dev/null || die "aucun mouvement G1 dans le G-code"
grep -q "G28" "$QSID_BUILD/gate-out/cube_20mm.gcode" || echo "    (note : pas de G28 — le start-gcode générique est minimal)"
tail -5 "$out/cube_20mm.gcode" | sed 's/^/    /'

info "gate OK : $out/cube_20mm.gcode"
