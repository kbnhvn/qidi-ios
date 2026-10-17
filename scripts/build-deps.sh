#!/usr/bin/env bash
# Construit les dépendances (Boost, CGAL, GMP, MPFR, TBB, OpenVDB, Qhull, z3…) pour
# la cible demandée.
#
#   QSID_TARGET=ios  scripts/build-deps.sh     # arm64-iphoneos
#   QSID_TARGET=host scripts/build-deps.sh     # macOS hôte (pour la gate)
#
# Long : de l'ordre de 1 à 2 h par cible (aucun cache local). La CI met ce
# répertoire en cache.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos
require_src

"$QSID_ROOT/scripts/host-cc.sh" "$QSID_BUILD/host-tools" >/dev/null

toolchain_args=()
if [ "$QSID_TARGET" != "host" ]; then
    toolchain_args+=(
        -DCMAKE_TOOLCHAIN_FILE="$QSID_TOOLCHAIN"
        -DQSID_SDK="$QSID_SDK"
        -DQSID_ARCH="$QSID_ARCH"
        -DQSID_IOS_MIN="$QSID_IOS_MIN"
        "-DQSID_DEPS_PREFIX=$QSID_DEPS_PREFIX"
        -DQSID_HOST_CC="$QSID_BUILD/host-tools/cc"
        -DQSID_HOST_CXX="$QSID_BUILD/host-tools/cxx"
    )
fi

info "deps : configure ($QSID_TARGET, SDK=$QSID_SDK)"
cmake -S "$QSID_SRC/deps" -B "$QSID_DEPS_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "-DQIDISlicer_deps_PACKAGE_EXCLUDES=$QSID_DEPS_EXCLUDES" \
    "-DQIDISlicer_deps_DEP_INSTALL_PREFIX=$QSID_DEPS_PREFIX" \
    "-DQIDISlicer_deps_DEP_DOWNLOAD_DIR=$QSID_BUILD/dl-cache" \
    "${toolchain_args[@]}"

# `scripts/build-deps.sh configure` : s'arrêter après la configuration. Quelques
# minutes, et c'est là que se révèlent les erreurs de patches/outillage, avant les
# builds longs.
if [ "${1:-all}" = "configure" ]; then
    info "configuration seule demandée — arrêt avant la compilation"
    grep -E "^(QIDISlicer_deps_(PACKAGE_EXCLUDES|DEP_INSTALL_PREFIX)|CMAKE_SYSTEM_NAME|CMAKE_OSX_ARCHITECTURES|CMAKE_OSX_DEPLOYMENT_TARGET):" \
        "$QSID_DEPS_BUILD/CMakeCache.txt" | sed 's/^/    /' || true
    exit 0
fi

info "deps : build (${QSID_JOBS} jobs)"
cmake --build "$QSID_DEPS_BUILD" --parallel "$QSID_JOBS"

info "deps OK -> $QSID_DEPS_PREFIX"
