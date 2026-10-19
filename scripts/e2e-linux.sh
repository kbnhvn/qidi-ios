#!/usr/bin/env bash
# Test de bout en bout du vrai SlicerModel (Swift) contre le vrai moteur (C++) et le vrai bundle
# QIDI, sous Linux : sélection de presets, scène, annuler/rétablir, réglages, slicing, aperçu,
# calibration, préréglages, export/import de profil. Voir scripts/e2e/main.swift.
#
# Prérequis : `scripts/linux-engine.sh build` (moteur compilé) et un toolchain Swift (swiftc).
#
#   scripts/e2e-linux.sh [dossier de build du moteur]      (défaut : build/linux/build)
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

ENG="${1:-${QSID_LINUX_DIR:-$QSID_BUILD/linux}/build}"
[ -x "$ENG/src/ios-core/qidislice_scene_gate" ] || die "moteur Linux absent : scripts/linux-engine.sh build"
SWIFTC="${QSID_SWIFTC:-$(command -v swiftc || true)}"
[ -n "$SWIFTC" ] || die "swiftc absent (QSID_SWIFTC=…)"

A="$QSID_ROOT/ios/QSlicerPad"
T="$QSID_ROOT/scripts/typecheck"
W="${QSID_E2E_WORK:-$(mktemp -d)}"
mkdir -p "$W"

# Substituts SwiftUI/UIKit : cette fois compilés en bibliothèques (le test s'exécute).
for mod in SwiftUI UIKit; do
    "$SWIFTC" -emit-library -static -emit-module -parse-as-library -module-name "$mod" "$T/${mod}Stub.swift" \
        -emit-module-path "$W/$mod.swiftmodule" -o "$W/lib$mod.a"
done

# Ligne d'édition de liens du moteur (extraite de CMake) -> arguments pour swiftc.
link_args=()
read -r -a tokens <<< "$(cd "$ENG" && ninja -t commands qidislice_scene_gate | tail -1)"
seen_out=0
for tok in "${tokens[@]}"; do
    if [ "$seen_out" = "1" ] && [ "$tok" != "-o" ]; then :; fi
    case "$tok" in
        *.a|*.so|*.so.*)
            case "$tok" in /*) path="$tok" ;; *) path="$ENG/$tok" ;; esac
            link_args+=(-Xlinker "$path") ;;
        -l*) link_args+=(-Xlinker "$tok") ;;
    esac
done
link_args+=(-Xlinker -lstdc++ -Xlinker -lpthread -Xlinker -lm)

echo "==> compilation du test (SlicerModel + QSlicerCore + Core/*.swift)"
"$SWIFTC" -module-name E2E -I "$W" -L "$W" -lSwiftUI -lUIKit \
    -import-objc-header "$T/Bridge.h" -Xcc "-I$QSID_ROOT/core/include" \
    "$QSID_ROOT/scripts/e2e/main.swift" "$T/AppStubs.swift" \
    "$QSID_ROOT/ios/QSlicerKit/Sources/QSlicerKit/SimdShim.swift" \
    "$A/Model/SlicerModel.swift" "$A/Core/QSlicerCore.swift" "$A/Core/SceneTypes.swift" \
    "$A/Core/SliceOverrides.swift" "$A/Core/FilamentIndex.swift" "$A/Core/GCodeMesh.swift" \
    "$A/Core/SettingsCatalog.swift" "$A/Core/Calibration.swift" "$A/Core/MoonrakerClient.swift" \
    "$A/Core/BedGeometry.swift" "$A/Core/CalibrationGCode.swift" "$A/Core/PrinterDiscovery.swift" "$A/Core/UserPresets.swift" "$A/Core/QIDIBox.swift" "$A/Core/CutPlane.swift" "$A/Core/ObjectSettings.swift" "$A/Core/L10n.swift" \
    "${link_args[@]}" -o "$W/e2e"

echo "==> Moonraker simulé"
python3 "$QSID_ROOT/scripts/e2e/mock_moonraker.py" 0 "$W/moonraker.json" "$W/moonraker.port" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do [ -s "$W/moonraker.port" ] && break; sleep 0.1; done

echo "==> exécution"
QSID_MOCK_MOONRAKER="http://127.0.0.1:$(cat "$W/moonraker.port")" \
QSID_MOCK_JOURNAL="$W/moonraker.json" \
QSID_RESOURCES_DIR="${QSID_RESOURCES_DIR:-$QSID_SRC/resources}" \
QSID_CONFIG_DIR="$A/Resources/config" \
QSID_E2E_OUT="$W/out" \
QSID_TESTDATA="$QSID_ROOT/testdata" \
    "$W/e2e" 2>&1 | { grep --line-buffered -v "Vendor Config Bundle\|invalid toolchange" || true; }
exit "${PIPESTATUS[0]}"
