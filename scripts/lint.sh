#!/usr/bin/env bash
# Vérifications disponibles *sans* macOS ni SDK iOS : syntaxe des scripts, YAML,
# application de la série de patches, et analyse syntaxique de nos CMakeLists par
# un harnais. À lancer avant de pousser — la CI fait le reste (compilation réelle).
#
#   scripts/lint.sh
#
# Sur Linux, les étapes qui exigent Xcode/clang sont marquées « ignoré ».
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

fail=0
note() { printf '%-52s %s\n' "$1" "$2"; }
ok()   { note "$1" "ok"; }
skip() { note "$1" "ignoré ($2)"; }
bad()  { note "$1" "ÉCHEC"; fail=1; }

echo "--- scripts shell"
while IFS= read -r s; do
    if bash -n "$s" 2>/dev/null; then ok "$(basename "$s")"; else bad "$(basename "$s")"; fi
done < <(find "$QSID_ROOT/scripts" -name '*.sh' -type f | sort)

echo "--- YAML"
PY="${QSID_PYTHON:-python3}"
for y in "$QSID_ROOT/.github/workflows/ios.yml" "$QSID_ROOT/ios/project.yml"; do
    if "$PY" -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$y" 2>/dev/null; then
        ok "$(basename "$y")"
    else
        bad "$(basename "$y")"
    fi
done

echo "--- série de patches (appliqués en séquence, comme bootstrap.sh)"
if [ -d "$QSID_SRC/.git" ]; then
    git -C "$QSID_SRC" reset -q --hard "$QSID_REV"
    git -C "$QSID_SRC" clean -qfd -e ios-core || true
    for p in "$QSID_ROOT"/patches/*.patch; do
        # Un patch de la série peut dépendre des précédents (contexte déplacé par
        # un patch antérieur) : c'est la *séquence* qu'il faut valider, pas chaque
        # patch isolément.
        if git -C "$QSID_SRC" apply "$p" 2>/dev/null; then
            ok "$(basename "$p")"
        else
            bad "$(basename "$p") (n'applique pas après les précédents, sur $QSID_REV)"
        fi
    done
else
    skip "patches" "sources amont absentes (scripts/bootstrap.sh)"
fi

echo "--- syntaxe CMake (harnais avec cibles factices)"
# cmake est fourni par la CI/macOS ; sous Linux, en installer un est possible sans
# root via un venv : `python3 -m venv .tooling/venv && .tooling/venv/bin/pip install cmake`
# puis QSID_CMAKE=.tooling/venv/bin/cmake scripts/lint.sh
cmake_bin="${QSID_CMAKE:-$(command -v cmake || true)}"
[ -z "$cmake_bin" ] && [ -x "$QSID_ROOT/.tooling/venv/bin/cmake" ] && cmake_bin="$QSID_ROOT/.tooling/venv/bin/cmake"
if [ -n "$cmake_bin" ]; then
    harness="$(mktemp -d)"
    mkdir -p "$harness/src"
    cp -R "$QSID_ROOT/core" "$harness/src/ios-core"
    cat > "$harness/src/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(qsid_lint CXX)
set(CMAKE_CXX_STANDARD 17)
# Cibles factices à la place de celles de l'amont, pour ne tester que la syntaxe
# et les références de ios-core/CMakeLists.txt.
set(SLIC3R_CLI_SOURCES)
foreach(t libslic3r libcereal slic3r-arrange-wrapper libseqarrange stb_image)
    add_library(${t} INTERFACE)
endforeach()
add_subdirectory(ios-core)
EOF
    if "$cmake_bin" -S "$harness/src" -B "$harness/build" -G "Unix Makefiles" \
            > "$harness/out.txt" 2>&1; then
        ok "core/CMakeLists.txt (configure)"
    elif grep -qiE "parse error|while evaluating|unknown CMake command" "$harness/out.txt"; then
        bad "core/CMakeLists.txt : $(grep -iE 'parse error|while evaluating|unknown CMake command' "$harness/out.txt" | head -1)"
    else
        # Un échec de génération (pas de compilateur C++ par ex.) ne met pas en
        # cause la syntaxe de nos fichiers.
        skip "core/CMakeLists.txt" "configure impossible ici : $(tail -2 "$harness/out.txt" | tr '\n' ' ' | cut -c1-70)"
    fi
    rm -rf "$harness"
else
    skip "syntaxe CMake" "cmake absent"
fi

echo "--- toolchain iOS (analyse syntaxique)"
if [ -n "$cmake_bin" ]; then
    probe="$(mktemp -d)"
    printf 'cmake_minimum_required(VERSION 3.20)\nproject(probe C CXX)\n' > "$probe/CMakeLists.txt"
    if "$cmake_bin" -S "$probe" -B "$probe/b" \
            -DCMAKE_TOOLCHAIN_FILE="$QSID_TOOLCHAIN" -DQSID_SDK=iphoneos \
            > "$probe/out.txt" 2>&1; then
        ok "cmake/toolchains/ios.cmake"
    elif grep -qiE "parse error|while evaluating|syntax error" "$probe/out.txt"; then
        bad "ios.cmake : $(grep -iE 'parse error|while evaluating|syntax error' "$probe/out.txt" | head -1)"
    else
        skip "ios.cmake" "configure interrompu (attendu hors macOS) : $(tail -1 "$probe/out.txt" | cut -c1-70)"
    fi
    rm -rf "$probe"
fi

echo "--- compatibilité bash 3.2 (macOS livre /bin/bash 3.2)"
# On ne regarde que le *code* : un commentaire peut citer ces noms sans risque.
bash4_hits="$(grep -rnE "mapfile|readarray|declare -A" "$QSID_ROOT/scripts" --include="*.sh" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -v "/lint.sh:" || true)"
if [ -z "$bash4_hits" ]; then
    ok "aucune construction bash 4+ dans les scripts"
else
    bad "construction bash 4+ détectée :"
    printf '%s\n' "$bash4_hits" | sed 's/^/    /'
fi

echo "--- cohérence de l'ABI C (en-tête, implémentation, appels Swift)"
abi_header="$QSID_ROOT/core/include/qidislice.h"
abi_impl="$QSID_ROOT/core/src/qidislice.cpp"
missing_impl=""
for fn in $(grep -oE 'qsid_[a-z_]+\(' "$abi_header" | tr -d '(' | sort -u); do
    grep -qE "\\b${fn}\\(" "$abi_impl" || missing_impl="$missing_impl $fn"
done
if [ -z "$missing_impl" ]; then
    ok "chaque fonction déclarée a une implémentation"
else
    bad "déclarées mais absentes de qidislice.cpp :$missing_impl"
fi

missing_in_header=""
for fn in $(grep -rhoE 'qsid_[a-z_]+\(' "$QSID_ROOT/ios" --include="*.swift" | tr -d '(' | sort -u); do
    grep -qE "\\b${fn}\\(" "$abi_header" || missing_in_header="$missing_in_header $fn"
done
if [ -z "$missing_in_header" ]; then
    ok "les appels Swift correspondent à l'en-tête"
else
    bad "appelés depuis Swift mais absents de l'en-tête :$missing_in_header"
fi

echo "--- clés de localisation (doublons = crash à l'exécution)"
l10n="$QSID_ROOT/ios/QSlicerPad/Core/L10n.swift"
if [ -f "$l10n" ]; then
    if "$PY" - "$l10n" <<'EOF'
import re, sys
src = open(sys.argv[1]).read()
body = src.split('private static let english: [String: String] = [',1)[1].rsplit(']',1)[0]
keys = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', body, re.M)
dupes = sorted({k for k in keys if keys.count(k) > 1})
if dupes:
    print("doublons :", dupes)
    sys.exit(1)
EOF
    then ok "aucune clé en double ($(grep -c '":' "$l10n") entrées)"; else bad "clés en double dans L10n.swift"; fi
else
    skip "L10n" "fichier absent"
fi

echo "--- miroir des algorithmes Swift (le Swift ne tourne pas ici)"
for t in "$QSID_ROOT"/scripts/tests/*.py; do
    [ -f "$t" ] || continue
    if out="$("$PY" "$t")" 2>&1; then
        ok "$(basename "$t")"
    else
        bad "$(basename "$t")"
        printf '%s\n' "$out" | tail -4 | sed 's/^/    /'
    fi
done

echo "--- tests Swift (paquet QSlicerKit : profils, options, G-code… sous Linux)"
swift_bin="${QSID_SWIFT:-$(command -v swift || true)}"
if [ -n "$swift_bin" ]; then
    if out="$(cd "$QSID_ROOT/ios/QSlicerKit" && "$swift_bin" test 2>&1)"; then
        ok "swift test ($(printf '%s\n' "$out" | grep -oE 'Executed [0-9]+ tests' | tail -1))"
    else
        bad "swift test"
        printf '%s\n' "$out" | grep -E "error|failed" | head -8 | sed 's/^/    /'
    fi
else
    skip "swift test" "toolchain Swift absente (QSID_SWIFT=…/swift)"
fi

echo "--- divers"
if [ "$(grep -c 'facet normal' "$QSID_ROOT/testdata/cube_20mm.stl")" = "12" ]; then
    ok "testdata/cube_20mm.stl (12 facettes)"
else
    bad "testdata/cube_20mm.stl"
fi
for k in bed_shape layer_height perimeters gcode_flavor; do
    grep -q "^$k" "$QSID_ROOT/testdata/qidi_generic_fff.ini" || bad "clé $k absente de qidi_generic_fff.ini"
done
ok "testdata/qidi_generic_fff.ini"

if [ "$fail" = "0" ]; then
    echo
    echo "lint : tout est vert (les étapes macOS/SDK restent à la CI)."
else
    echo
    echo "lint : au moins une vérification a échoué."
    exit 1
fi
