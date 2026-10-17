#!/usr/bin/env bash
# Génère le projet Xcode (XcodeGen) et construit une .ipa NON SIGNÉE.
#
# Non signée = à installer/re-signer avec SideStore (ou AltStore/Sideloadly) :
#   - compte Apple gratuit : 7 jours de validité, 3 apps, re-signature hebdomadaire ;
#   - aucun secret de signature n'est nécessaire dans la CI.
#
#   QSID_TARGET=ios scripts/package-ipa.sh
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos

[ -f "$QSID_DIST/lib/QSlicerEngine.a" ] || die "archive du moteur absente : lancez scripts/package-engine.sh"

command -v xcodegen >/dev/null || die "xcodegen absent (brew install xcodegen)"

info "génération du projet Xcode"
( cd "$QSID_ROOT/ios" && xcodegen generate --quiet )

dd="$QSID_BUILD/xcode-$QSID_TARGET"
rm -rf "$dd"

info "xcodebuild (Release, $QSID_SDK, sans signature)"
( cd "$QSID_ROOT/ios" && xcodebuild \
    -project QSlicerPad.xcodeproj \
    -scheme QSlicerPad \
    -configuration Release \
    -sdk "$QSID_SDK" \
    -derivedDataPath "$dd" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    QSID_ENGINE_ARCHIVE="$QSID_DIST" \
    QSID_ENGINE_LINK_FLAGS="$(grep -v '^#' "$QSID_DIST/QSlicerEngine-link.txt" | tr '\n' ' ')" \
    build ) 2>&1 | tail -25

app="$(find "$dd/Build/Products" -maxdepth 2 -name 'QSlicerPad.app' -type d | head -1)"
[ -n "$app" ] || die "QSlicerPad.app introuvable dans $dd/Build/Products"

# Contrôles sur le bundle : c'est ce qu'on installe, autant vérifier ce qu'il est.
info "vérifications du bundle"
archs="$(lipo -archs "$app/QSlicerPad")"
platform="$(vtool -show-build "$app/QSlicerPad" 2>/dev/null | awk '/platform/ {print $2}' | sort -u | tr '\n' ' ')"
[ "$archs" = "arm64" ] || die "architecture inattendue : $archs (attendu arm64)"
case "$platform" in *IOS*|*iOS*) ;; *) die "plateforme inattendue : '$platform' (attendu IOS)" ;; esac
[ -f "$app/Resources/qidi/profiles/QIDITechnology.ini" ] || die "profils QIDI absents du bundle"

info "paquetage de la .ipa (non signée)"
ipa_dir="$QSID_BUILD/ipa-$QSID_TARGET"
rm -rf "$ipa_dir"
mkdir -p "$ipa_dir/Payload"
cp -R "$app" "$ipa_dir/Payload/"
( cd "$ipa_dir" && zip -qry "$QSID_DIST/QSlicerPad-unsigned.ipa" Payload )

ls -lh "$QSID_DIST/QSlicerPad-unsigned.ipa"
info "OK — installer avec SideStore : docs/sideloading.md"
