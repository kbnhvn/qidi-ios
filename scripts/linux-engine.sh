#!/usr/bin/env bash
# Banc de test Linux du moteur : compile libslic3r + l'ABI (core/) avec les paquets
# Ubuntu 24.04 et exécute les gates (CLI v1/v2 et ABI v3 contre le vrai bundle QIDI).
#
# Pourquoi : la CI macOS coûte ×10 en minutes et chaque itération est longue ; ce banc
# reproduit le comportement de la gate hôte (mêmes chiffres : 8 100 lignes, 100 couches,
# 1 397,9 mm) et permet de développer l'ABI C++ avec un retour en minutes. Il ne remplace
# pas la CI : il ne valide ni Xcode, ni le SDK iOS, ni SwiftUI.
#
#   scripts/bootstrap.sh                 # sources amont + patches (une fois)
#   scripts/linux-engine.sh deps         # paquets apt + libbgcode + heatshrink (une fois)
#   scripts/linux-engine.sh build        # configure + compile (≈ 50 min à froid, 4 cœurs)
#   scripts/linux-engine.sh gate         # lance les gates
#   scripts/linux-engine.sh sync         # recopie core/ dans l'arbre amont et recompile (rapide)
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

LX="${QSID_LINUX_DIR:-$QSID_BUILD/linux}"
PREFIX="$LX/prefix"
JOBS="${QSID_JOBS:-$(nproc)}"

install_core() {
    rm -rf "$QSID_SRC/ios-core"
    mkdir -p "$QSID_SRC/ios-core"
    cp -R "$QSID_ROOT/core/include" "$QSID_ROOT/core/src" "$QSID_ROOT/core/gate" "$QSID_SRC/ios-core/"
    cp "$QSID_ROOT/core/CMakeLists.txt" "$QSID_SRC/ios-core/"
}

cmd_deps() {
    sudo apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ccache \
        libboost-all-dev libtbb-dev libeigen3-dev libcereal-dev libnlopt-cxx-dev libopenvdb-dev \
        libblosc-dev libcgal-dev libgmp-dev libmpfr-dev libqhull-dev libpng-dev libjpeg-dev \
        libexpat1-dev libz3-dev zlib1g-dev libcurl4-openssl-dev libglew-dev libdbus-1-dev \
        libopenexr-dev libgl-dev libnanosvg-dev
    mkdir -p "$LX/dl" "$PREFIX"

    # libbgcode et heatshrink : mêmes révisions que deps/ de l'amont (pas de paquet Ubuntu).
    [ -d "$LX/dl/libbgcode" ] || git clone -q https://github.com/prusa3d/libbgcode "$LX/dl/libbgcode"
    git -C "$LX/dl/libbgcode" checkout -q 5041c093b33e2748e76d6b326f2251310823f3df
    [ -d "$LX/dl/heatshrink" ] || git clone -q https://github.com/atomicobject/heatshrink "$LX/dl/heatshrink"
    git -C "$LX/dl/heatshrink" checkout -q v0.4.1
    cp "$QSID_SRC/deps/+heatshrink/CMakeLists.txt" "$QSID_SRC/deps/+heatshrink/Config.cmake.in" "$LX/dl/heatshrink/"

    cmake -S "$LX/dl/heatshrink" -B "$LX/hs-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build "$LX/hs-build" >/dev/null && cmake --install "$LX/hs-build" >/dev/null
    cmake -S "$LX/dl/libbgcode" -B "$LX/bg-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DLibBGCode_BUILD_TESTS=OFF -DLibBGCode_BUILD_CMD_TOOL=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build "$LX/bg-build" >/dev/null && cmake --install "$LX/bg-build" >/dev/null

    # Z3 d'Ubuntu n'a pas de fichier de configuration CMake.
    mkdir -p "$PREFIX/lib/cmake/Z3"
    cat > "$PREFIX/lib/cmake/Z3/Z3Config.cmake" <<'CMAKE'
set(Z3_FOUND TRUE)
if(NOT TARGET z3::libz3)
    add_library(z3::libz3 SHARED IMPORTED)
    set_target_properties(z3::libz3 PROPERTIES
        IMPORTED_LOCATION /usr/lib/x86_64-linux-gnu/libz3.so
        INTERFACE_INCLUDE_DIRECTORIES /usr/include)
endif()
CMAKE
    # OpenVDB d'Ubuntu utilise Imath, pas IlmBase.
    cat > "$LX/prelude.cmake" <<'CMAKE'
if(NOT TARGET IlmBase::Half)
    add_library(IlmBase::Half INTERFACE IMPORTED)
endif()
CMAKE
}

cmd_build() {
    require_src
    install_core
    # -DNDEBUG : comme la Release macOS/iOS (sans lui, des assert du code amont se déclenchent).
    cmake -S "$QSID_SRC" -B "$LX/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_CXX_FLAGS_RELEASE=-O1 -DNDEBUG -g0" "-DCMAKE_PREFIX_PATH=$PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "-DCMAKE_PROJECT_INCLUDE=$LX/prelude.cmake" \
        -DOPENVDB_FIND_MODULE_PATH=/usr/lib/x86_64-linux-gnu/cmake/OpenVDB \
        -DSLIC3R_GUI=OFF -DSLIC3R_STATIC=OFF -DSLIC3R_IOS_CORE=ON -DSLIC3R_BUILD_TESTS=OFF \
        -DSLIC3R_BUILD_SANDBOXES=OFF -DSLIC3R_PCH=OFF -DSLIC3R_ENABLE_FORMAT_STEP=OFF \
        -DSLIC3R_DESKTOP_INTEGRATION=OFF -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    cmake --build "$LX/build" --parallel "$JOBS" --target qidislice_gate qidislice_scene_gate
}

cmd_sync() {
    install_core
    cmake --build "$LX/build" --parallel "$JOBS" --target qidislice_gate qidislice_scene_gate
}

cmd_gate() {
    local out="$LX/out"; mkdir -p "$out"
    local g="$LX/build/src/ios-core"
    export QSID_RESOURCES_DIR="$QSID_SRC/resources" QSID_DATA_DIR="$out/data"
    "$g/qidislice_gate" "$QSID_ROOT/testdata/cube_20mm.stl" "$QSID_ROOT/testdata/qidi_generic_fff.ini" \
        "$out/cube.gcode" --min-layers 20 | tail -3
    QSID_CALIB_DIR="$QSID_SRC/resources/calib" \
    "$g/qidislice_scene_gate" "$QSID_SRC/resources/profiles/QIDITechnology.ini" \
        "$QSID_ROOT/testdata/cube_20mm.stl" "$QSID_ROOT/testdata/cube_20mm_z30.stl" "$out" \
        2>&1 | grep -v "Vendor Config Bundle\|invalid toolchange"
}

case "${1:-}" in
    deps)  cmd_deps ;;
    build) cmd_build ;;
    sync)  cmd_sync ;;
    gate)  cmd_gate ;;
    *) echo "usage: $0 deps|build|sync|gate" >&2; exit 2 ;;
esac
