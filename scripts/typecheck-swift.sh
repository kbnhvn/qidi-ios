#!/usr/bin/env bash
# Vérifie les types de l'état de l'app (SlicerModel) et de l'enveloppe Swift de l'ABI C
# (QSlicerCore) *sous Linux*, avec le vrai en-tête qidislice.h : le modèle et le pont C
# sont ce qui change le plus et ce qui coûte le plus cher à découvrir cassé sur macOS.
#
# SwiftUI/UIKit n'existent pas sous Linux : scripts/typecheck/ en fournit de minuscules
# substituts (ObservableObject, Published, UIApplication…). Les vues SwiftUI/SceneKit ne
# sont donc pas typées ici (seulement analysées par `swiftc -parse`) : la CI macOS les compile.
#
#   scripts/typecheck-swift.sh          (nécessite `swiftc` dans le PATH ou QSID_SWIFTC)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${QSID_SWIFTC:-$(command -v swiftc || true)}"
[ -n "$SWIFTC" ] || { echo "swiftc absent (QSID_SWIFTC=…)" >&2; exit 3; }

A="$ROOT/ios/QSlicerPad"
T="$ROOT/scripts/typecheck"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

"$SWIFTC" -emit-module -parse-as-library -module-name SwiftUI "$T/SwiftUIStub.swift" -emit-module-path "$W/SwiftUI.swiftmodule"
"$SWIFTC" -emit-module -parse-as-library -module-name UIKit "$T/UIKitStub.swift" -emit-module-path "$W/UIKit.swiftmodule"

# Syntaxe de tous les fichiers de l'app (vues comprises).
status=0
while IFS= read -r f; do
    if ! out="$("$SWIFTC" -parse "$f" 2>&1)"; then
        echo "syntaxe : $f"; echo "$out" | grep error | head -3; status=1
    fi
done < <(find "$A" -name '*.swift')

# Types du modèle et du pont C.
if ! "$SWIFTC" -typecheck -I "$W" -import-objc-header "$T/Bridge.h" -Xcc "-I$ROOT/core/include" \
    "$T/AppStubs.swift" "$ROOT/ios/QSlicerKit/Sources/QSlicerKit/SimdShim.swift" \
    "$A/Model/SlicerModel.swift" "$A/Core/QSlicerCore.swift" "$A/Core/SceneTypes.swift" \
    "$A/Core/SliceOverrides.swift" "$A/Core/FilamentIndex.swift" "$A/Core/GCodeMesh.swift" \
    "$A/Core/SettingsCatalog.swift" "$A/Core/Calibration.swift" "$A/Core/MoonrakerClient.swift" \
    "$A/Core/BedGeometry.swift" "$A/Core/CalibrationGCode.swift" "$A/Core/PrinterDiscovery.swift" "$A/Core/UserPresets.swift" "$A/Core/QIDIBox.swift" "$A/Core/EngineThread.swift" "$A/Core/SoftwareThumbnail.swift" "$A/Core/ThumbnailRenderer.swift" "$A/Core/SliceBreadcrumb.swift" "$A/Core/CutPlane.swift" "$A/Core/ObjectSettings.swift" "$A/Core/L10n.swift" 2>"$W/typecheck.log"; then
    grep -E "error|warning" "$W/typecheck.log" | head -20
    status=1
fi
[ "$status" = "0" ] && echo "typecheck : SlicerModel + QSlicerCore + Core/*.swift OK ; syntaxe de $(find "$A" -name '*.swift' | wc -l | tr -d ' ') fichiers OK"
exit $status
