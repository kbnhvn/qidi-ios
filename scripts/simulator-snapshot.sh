#!/usr/bin/env bash
# Lance l'app dans un simulateur iPad et capture l'écran.
#
#   scripts/simulator-snapshot.sh <chemin/QSlicerPad.app> [sortie.png]
#
# Utilisé par la CI pour vérifier *visuellement* la disposition tactile sans
# appareil physique. Laisse le simulateur démarré (la CI est éphémère).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos

app="${1:?usage: simulator-snapshot.sh <app> [sortie.png]}"
out="${2:-$QSID_BUILD/ui-snapshot.png}"
[ -d "$app" ] || die "app introuvable : $app"
mkdir -p "$(dirname "$out")"

info "recherche d'un simulateur iPad disponible"
udid="$(python3 - <<'PY'
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
best = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        name = d.get("name", "")
        if "iPad" in name and d.get("isAvailable"):
            best = d["udid"]
            break
    if best:
        break
if not best:
    sys.exit("aucun simulateur iPad disponible")
print(best)
PY
)"
info "simulateur : $udid"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null

info "installation de l'app"
xcrun simctl install "$udid" "$app"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
info "lancement ($bundle_id)"
xcrun simctl launch "$udid" "$bundle_id" >/dev/null
sleep 6   # laisse le temps au premier rendu (chargement des profils du bundle)

info "capture -> $out"
xcrun simctl io "$udid" screenshot "$out"
file "$out"
info "capture OK (le simulateur reste démarré ; la CI est éphémère)"
