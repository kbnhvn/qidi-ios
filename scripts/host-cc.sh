#!/usr/bin/env bash
# Crée les compilateurs « machine de build » utilisés par les recettes autotools
# (GMP, MPFR) via CC_FOR_BUILD.
#
# Pourquoi des wrappers : un build iOS exporte SDKROOT, clang l'honore, donc un
# simple /usr/bin/clang émet du code iOS. GMP compile et *exécute* des programmes
# générateurs : il lui faut un compilateur qui produit du code macOS. -isysroot
# l'emporte sur SDKROOT, d'où le wrapper.
#
# Usage : scripts/host-cc.sh [répertoire de sortie]
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos

out="${1:-$QSID_BUILD/host-tools}"
mkdir -p "$out"

macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"

cat > "$out/cc" <<EOF
#!/bin/sh
# Compilateur C de la machine de build (macOS), insensible à SDKROOT.
exec /usr/bin/clang -isysroot "$macos_sdk" "\$@"
EOF

cat > "$out/cxx" <<EOF
#!/bin/sh
exec /usr/bin/clang++ -isysroot "$macos_sdk" "\$@"
EOF

chmod +x "$out/cc" "$out/cxx"

info "compilateurs hôtes : $out/cc et $out/cxx (SDK macOS = $macos_sdk)"
