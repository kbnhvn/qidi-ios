#!/usr/bin/env bash
# Récupère les sources QIDISlicer à la révision épinglée, applique la série de
# patches, puis installe la cible ios-core dans l'arbre.
#
#   scripts/bootstrap.sh            # clone/fetch + patches + ios-core
#   QSID_REV=<sha> scripts/bootstrap.sh
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

mkdir -p "$QSID_ROOT/third_party"

if [ ! -d "$QSID_SRC/.git" ]; then
    info "clone $QSID_REPO @ $QSID_REV"
    mkdir -p "$QSID_SRC"
    git -C "$QSID_SRC" init -q
    git -C "$QSID_SRC" remote add origin "$QSID_REPO" 2>/dev/null || true
else
    info "dépôt tiers déjà présent, mise à jour"
fi

# Récupère exactement la révision épinglée (clone superficiel).
if ! git -C "$QSID_SRC" cat-file -e "$QSID_REV^{commit}" 2>/dev/null; then
    info "fetch de $QSID_REV"
    git -C "$QSID_SRC" fetch --depth 1 origin "$QSID_REV" 2>/dev/null \
        || die "fetch de $QSID_REV impossible (réseau ? révision supprimée ?)"
fi

git -C "$QSID_SRC" checkout -q --force "$QSID_REV"
git -C "$QSID_SRC" reset -q --hard "$QSID_REV"

# L'arbre doit être propre, *y compris* pour les fichiers que nos patches créent
# (par ex. deps/+z3/z3-lp-clang-typos.patch) : sans ce nettoyage, un second passage
# échouerait avec « already exists ». ios-core/ est géré explicitement juste après.
rm -rf "$QSID_SRC/ios-core"
git -C "$QSID_SRC" clean -qfd -e ios-core

info "application de la série de patches"
shopt -s nullglob
patches=("$QSID_ROOT"/patches/*.patch)
[ ${#patches[@]} -gt 0 ] || die "aucun patch dans patches/"
for p in "${patches[@]}"; do
    name="$(basename "$p")"
    if git -C "$QSID_SRC" apply --check "$p" 2>/dev/null; then
        git -C "$QSID_SRC" apply "$p"
        echo "    appliqué : $name"
    elif git -C "$QSID_SRC" apply --reverse --check "$p" 2>/dev/null; then
        echo "    déjà appliqué : $name"
    else
        die "le patch $name ne s'applique pas proprement (révision changée ?)"
    fi
done

info "installation de la cible ios-core dans l'arbre"
mkdir -p "$QSID_SRC/ios-core"
cp -R "$QSID_ROOT/core/include"      "$QSID_SRC/ios-core/"
cp -R "$QSID_ROOT/core/src"          "$QSID_SRC/ios-core/"
cp -R "$QSID_ROOT/core/gate"         "$QSID_SRC/ios-core/"
cp    "$QSID_ROOT/core/CMakeLists.txt" "$QSID_SRC/ios-core/CMakeLists.txt"

info "bootstrap terminé : $QSID_SRC @ $(git -C "$QSID_SRC" rev-parse --short HEAD)"
echo "    $(git -C "$QSID_SRC" diff --name-only | wc -l) fichier(s) amont modifié(s), + ios-core/ (4 fichiers)"
