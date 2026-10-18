#!/usr/bin/env bash
# Helpers partagés par les scripts de build.
# Usage : . "$(dirname "$0")/lib/common.sh"
set -euo pipefail

QSID_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QSID_SRC="$QSID_ROOT/third_party/qidislicer"
QSID_BUILD="$QSID_ROOT/build"
QSID_TOOLCHAIN="$QSID_ROOT/cmake/toolchains/ios.cmake"

# Révision QIDISlicer épinglée. Les patches de patches/ sont générés contre cette
# révision : la changer demande de rebaser la série (voir docs/building.md).
QSID_REV="${QSID_REV:-988f4198021ce0b5907636a146f83481aa7daf89}"
QSID_REPO="${QSID_REPO:-https://github.com/QIDITECH/QIDISlicer}"

# Cible : ios (device), iossim (simulateur), host (machine de build, macOS).
QSID_TARGET="${QSID_TARGET:-ios}"
case "$QSID_TARGET" in
    ios)    QSID_SDK=iphoneos ;;
    iossim) QSID_SDK=iphonesimulator ;;
    host)   QSID_SDK=macosx ;;
    *) echo "QSID_TARGET invalide : $QSID_TARGET (ios|iossim|host)" >&2; exit 2 ;;
esac

QSID_ARCH="${QSID_ARCH:-arm64}"
QSID_IOS_MIN="${QSID_IOS_MIN:-15.0}"
QSID_MACOS_MIN="${QSID_MACOS_MIN:-11.0}"  # builds hôte (gate)
QSID_JOBS="${QSID_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

QSID_DEPS_BUILD="$QSID_BUILD/deps-$QSID_TARGET"
QSID_DEPS_PREFIX="$QSID_DEPS_BUILD/destdir/usr/local"
QSID_ENGINE_BUILD="$QSID_BUILD/engine-$QSID_TARGET"
QSID_DIST="$QSID_BUILD/dist-$QSID_TARGET"

# Paquets de dépendances qu'on ne construit pas pour iOS :
# - wxWidgets, GLEW, OpenCSG : uniquement utilisés par la GUI (wxWidgets) ;
#   le cœur libslic3r n'en dépend pas et wxOSX n'a pas de portage iOS.
# - Catch2 : tests désactivés (cross-compilation).
# - CURL, OpenSSL : référencés uniquement par src/slic3r (réseau/GUI). Le
#   portage de QIDIConnect/Moonraker en v2 les ramènera (avec un patch OpenSSL).
# - OCCT : import STEP, exclu de la v1 (SLIC3R_ENABLE_FORMAT_STEP=OFF).
# - NanoSVG n'est PAS exclu : libslic3r/EmbossShape.hpp inclut nanosvg/nanosvg.h
#   (embossage de texte) — ses en-têtes arrivent via <prefix>/include.
QSID_DEPS_EXCLUDES="${QSID_DEPS_EXCLUDES:-wxWidgets|GLEW|OpenCSG|Catch2|CURL|OpenSSL|OCCT}"

die()  { echo "erreur: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "ce script nécessite macOS (Xcode) : $(uname -s) détecté"
}

require_src() {
    [ -d "$QSID_SRC/src/libslic3r" ] || die "sources amont absentes : lancez scripts/bootstrap.sh"
}
