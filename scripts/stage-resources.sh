#!/usr/bin/env bash
# Copie dans le bundle de l'app les ressources dont le cœur a besoin, et rien de
# plus : les profils vendor QIDI (pour lister les modèles et, à terme, installer
# le bundle) et la configuration générique de secours.
#
# Volontairement exclus pour l'instant (GUI), à revoir en v2 :
#   localization/ (45 Mo), web/ (42 Mo), fonts/ (20 Mo), shapes/ (17 Mo),
#   stl_thumb/ (9 Mo), shaders/, calib/.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_src

dst="$QSID_ROOT/ios/QSlicerPad/Resources/qidi"
rm -rf "$dst"
mkdir -p "$dst/profiles" "$dst/generic" "$dst/calib"

info "profils vendor QIDI"
cp -R "$QSID_SRC/resources/profiles/." "$dst/profiles/"

info "modèles de calibration"
cp -R "$QSID_SRC/resources/calib/." "$dst/calib/"

info "configuration générique de secours"
cp "$QSID_ROOT/testdata/qidi_generic_fff.ini" "$dst/generic/"

echo "    $(find "$dst" -type f | wc -l) fichier(s), $(du -sh "$dst" | cut -f1)"
info "ressources prêtes -> $dst"
