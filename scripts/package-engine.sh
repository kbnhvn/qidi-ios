#!/usr/bin/env bash
# Fusionne tout ce que l'app doit lier en une seule archive statique :
#   - les archives de l'arbre amont (libslic3r, libcereal, arrange, seqarrange, …)
#   - l'ABI C (libqidislice.a)
#   - les archives du préfixe de dépendances (Boost, CGAL, TBB, OpenVDB, GMP…)
#
# Pourquoi fusionner : libslic3r tire plusieurs dizaines d'archives ; une ligne de
# link Xcode qui les énumère se périme à chaque évolution du moteur. Une archive
# fusionnée reste une seule entrée. Le sur-linkage ne coûte rien : l'éditeur de
# liens élimine ce qui n'est pas atteint (dead-strip).
#
#   QSID_TARGET=ios scripts/package-engine.sh
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
require_macos

[ -d "$QSID_ENGINE_BUILD" ] || die "arbre de build amont absent : lancez scripts/build-engine.sh"

mkdir -p "$QSID_DIST/include" "$QSID_DIST/lib"

# Toutes les archives produites dans l'arbre amont et par nos cibles…
# (pas de `mapfile` : macOS livre bash 3.2, où il n'existe pas.)
engine_archives=()
while IFS= read -r f; do engine_archives+=("$f"); done \
    < <(find "$QSID_ENGINE_BUILD" -name '*.a' -type f | sort)

# …et toutes celles installées par les dépendances.
dep_archives=()
while IFS= read -r f; do dep_archives+=("$f"); done \
    < <(find "$QSID_DEPS_PREFIX/lib" -maxdepth 1 -name '*.a' -type f | sort)

[ ${#engine_archives[@]} -gt 0 ] || die "aucune archive dans $QSID_ENGINE_BUILD"

info "fusion : ${#engine_archives[@]} archive(s) du moteur + ${#dep_archives[@]} du préfixe deps"
libtool -static -o "$QSID_DIST/lib/QSlicerEngine.a" \
    ${engine_archives[@]+"${engine_archives[@]}"} ${dep_archives[@]+"${dep_archives[@]}"} 2>&1 | tail -3

cp "$QSID_ROOT/core/include/qidislice.h" "$QSID_DIST/include/"

# Ce que la fusion ne peut pas transporter : tout ce que le moteur prend dans le
# SDK (aucun code objet à fusionner). L'app doit le nommer à l'édition de liens.
cat > "$QSID_DIST/QSlicerEngine-link.txt" <<'EOF'
# Bibliothèques et frameworks du SDK à ajouter à la ligne de link de l'app
# (une archive statique ne transporte que du code objet).
-lexpat -liconv -lz
-framework Foundation
-framework CoreFoundation
-framework ModelIO
-framework Accelerate
-framework IOKit
-framework CoreGraphics
-framework CoreServices
EOF

ls -lh "$QSID_DIST/lib/QSlicerEngine.a"
info "archive prête : $QSID_DIST/lib/QSlicerEngine.a (+ include/ + QSlicerEngine-link.txt)"
