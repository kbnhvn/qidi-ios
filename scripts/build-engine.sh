#!/usr/bin/env bash
# Configure et construit le cœur : libslic3r + l'ABI C (qidislice) et, sur l'hôte,
# le binaire de vérification (qidislice_gate).
#
#   QSID_TARGET=ios  scripts/build-engine.sh            # libslic3r + qidislice (arm64-ios)
#   QSID_TARGET=host scripts/build-engine.sh gate       # + qidislice_gate, puis exécution
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos
require_src

[ -d "$QSID_DEPS_PREFIX" ] || die "dépendances absentes ($QSID_DEPS_PREFIX) : lancez d'abord scripts/build-deps.sh"

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
else
    toolchain_args+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=${QSID_MACOS_MIN}")
fi

asan_args=()
if [ "${QSID_ASAN:-0}" = "1" ] && [ "$QSID_TARGET" = "host" ]; then
    # Diagnostique la gate : ASan symbolise les SIGSEGV que lldb ne peut pas
    # dérouler (libslic3r est compilé -O3, sans frame pointer).
    asan_args+=(-DSLIC3R_ASAN=ON "-DCMAKE_CXX_FLAGS=-g -fno-omit-frame-pointer")
    info "ASan activé pour la gate hôte"
fi

info "cœur : configure ($QSID_TARGET)"
cmake -S "$QSID_SRC" -B "$QSID_ENGINE_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_PREFIX_PATH=$QSID_DEPS_PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSLIC3R_GUI=OFF \
    -DSLIC3R_STATIC=ON \
    -DSLIC3R_IOS_CORE=ON \
    -DSLIC3R_BUILD_TESTS=OFF \
    -DSLIC3R_BUILD_SANDBOXES=OFF \
    -DSLIC3R_PCH=OFF \
    -DSLIC3R_ENABLE_FORMAT_STEP=OFF \
    ${toolchain_args[@]+"${toolchain_args[@]}"} ${asan_args[@]+"${asan_args[@]}"}

targets=(libslic3r qidislice)
if [ "${1:-}" = "gate" ] && [ "$QSID_TARGET" = "host" ]; then
    targets+=(qidislice_gate qidislice_scene_gate)
fi

info "cœur : build (${QSID_JOBS} jobs) — cibles : ${targets[*]}"
cmake --build "$QSID_ENGINE_BUILD" --parallel "$QSID_JOBS" --target "${targets[@]}"

info "cœur OK -> $QSID_ENGINE_BUILD"
