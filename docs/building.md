# Construire

## Prérequis

| Cible | Machine | Outils |
|---|---|---|
| `ios` / `iossim` | macOS (ou runner GitHub `macos-15`) | Xcode, `cmake`, `ninja`, `xcodegen` |
| `host` (gate) | macOS | idem |
| `lint` (sans compiler) | n'importe quel OS | `bash`, `python3` (+ `cmake` pour la partie CMake) |

Aucun compte Apple n'est nécessaire pour produire la `.ipa` : elle est **non signée** et re-signée sur
la machine par SideStore/AltStore (voir [`sideloading.md`](sideloading.md)).

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `QSID_TARGET` | `ios` | `ios` (arm64-iphoneos), `iossim` (simulateur), `host` (macOS) |
| `QSID_REV` | révision épinglée | révision QIDISlicer à construire |
| `QSID_JOBS` | `hw.ncpu` | parallélisme |
| `QSID_IOS_MIN` | `15.0` | cible de déploiement du moteur (l'app vise iOS 17) |
| `QSID_DEPS_EXCLUDES` | `wxWidgets\|GLEW\|OpenCSG\|NanoSVG\|Catch2\|CURL\|OpenSSL\|OCCT` | paquets de dépendances non construits |
| `QSID_CMAKE`, `QSID_PYTHON` | — | binaires utilisés par `scripts/lint.sh` sur un hôte exotique |

## En local, sur macOS

```bash
scripts/bootstrap.sh                       # clone épinglé + patches + copie de core/ en ios-core/
scripts/stage-resources.sh                 # profils QIDI dans le bundle de l'app (léger)

# 1) Gate hôte : compile vite (deps macOS déjà largement disponibles) et exécute un slicing réel
QSID_TARGET=host scripts/build-deps.sh
QSID_TARGET=host scripts/build-engine.sh gate
QSID_TARGET=host scripts/gate.sh

# 2) Moteur iOS + app + .ipa
QSID_TARGET=ios scripts/build-deps.sh      # 1–2 h au premier passage
QSID_TARGET=ios scripts/build-engine.sh
QSID_TARGET=ios scripts/package-engine.sh
QSID_TARGET=ios scripts/package-ipa.sh
```

La gate hôte est le raccourci le plus utile : elle exerce le même code de slicing, en quelques minutes,
et produit `build/gate-out/cube_20mm.gcode`.

## Sans macOS : la CI

Le workflow [`.github/workflows/ios.yml`](../.github/workflows/ios.yml) fait tout, sur `macos-15` :

0. `configure-check` — bootstrap + **configuration** des dépendances iOS (sans compiler). Quelques
   minutes : c'est là que se révèlent les erreurs de patches et d'outillage, avant les builds longs.
0bis. `deps-smoke` — quelques dépendances **réellement compilées** pour arm64-iphoneos (Qhull, JPEG,
   PNG, Expat, heatshrink via CMake ; GMP/MPFR via autotools ; z3 ; Eigen/Cereal en en-têtes seuls),
   avec vérification `lipo` des architectures et `vtool` de la plateforme sur un objet extrait.
   **Statut : vert** (toutes les bibliothèques produites sont arm64, plateforme IOS, minos 15.0).
1. `host-gate` — dépendances + moteur + **exécution** du slicing sur un cube → artefact de G-code.
2. `ios-engine` — dépendances + `libslic3r` + ABI C pour **arm64-iphoneos** → archive fusionnée,
   avec des contrôles : architecture `arm64`, symboles `Slicer::CLI` présents, symboles `qsid_*`
   exportés, et `vtool -show-build` sur un objet pour vérifier le SDK de destination.
3. `ios-app` — XcodeGen + `xcodebuild` (sans signature), contrôles du bundle (arm64, plateforme iOS,
   profils présents), puis **`.ipa` non signée** en artefact.

**Déclenchement et coût.** Les runners macOS consomment les minutes Actions avec un multiplicateur
**×10**, et `ios-engine` construit toutes les dépendances (1–2 h). Les portées 0bis à 3 ne tournent donc
que sur demande :

```bash
gh workflow run ios.yml -f scope=deps-smoke   # vérification rapide du toolchain iOS
gh workflow run ios.yml -f scope=full         # tout
gh run watch                                  # suivre
gh run view --log-failed                      # lire les échecs
```

Un simple `push` (ou une PR) ne lance que `configure-check`. Pour que chaque push lance tout :
`gh variable set QSID_FULL_CI --body true`.

Les dépendances sont mises en cache (`build/deps-*`) avec une clé qui dépend de la révision épinglée et
de l'empreinte des patches : un rebasage invalide le cache, c'est voulu.

Le premier passage du build complet échouera probablement quelque part — c'est attendu, voir
[`risks.md`](risks.md).

## Mettre à jour la version amont

1. Trouver la nouvelle révision :
   ```bash
   git ls-remote https://github.com/QIDITECH/QIDISlicer refs/heads/master
   ```
2. Changer `QSID_REV` dans `scripts/lib/common.sh`.
3. Rebaser la série :
   ```bash
   git -C third_party/qidislicer fetch --depth 1 origin <nouvelle-rev>
   git -C third_party/qidislicer checkout --force <nouvelle-rev>
   # réappliquer les patches un par un, corriger les contextes, régénérer :
   for p in patches/*.patch; do git -C third_party/qidislicer apply "$p" || echo "à rebaser : $p"; done
   # après correction, régénérer le diff du fichier concerné :
   git -C third_party/qidislicer diff -- <fichier> > patches/<patch>.patch
   ```
4. `scripts/lint.sh` doit être vert (il vérifie que chaque patch s'applique sur la révision épinglée).

## Ce qui est vérifiable sans macOS

```bash
scripts/lint.sh
```

Vérifie : syntaxe de tous les scripts, validité des YAML (workflow + XcodeGen), application de chaque
patch sur la révision épinglée, analyse syntaxique de `core/CMakeLists.txt` par un harnais à cibles
factices, et cohérence des données de test. Sous Linux, on peut se donner un `cmake` sans root :

```bash
python3 -m venv .tooling/venv && .tooling/venv/bin/pip install cmake
QSID_CMAKE=.tooling/venv/bin/cmake scripts/lint.sh
```


## Banc de test Linux (développement rapide, sans Mac)

La CI macOS est lente et coûteuse ; la plupart des défauts se trouvent plus vite sous Linux. Trois outils,
du moins cher au plus cher (aucun ne remplace la CI `ios-app` ni la recette iPad) :

| Commande | Ce que ça vérifie | Durée |
|---|---|---|
| `scripts/lint.sh` | scripts, YAML, CMake, ABI C ↔ Swift, localisation, **tests Swift** (`ios/QSlicerKit`), **types du modèle et du pont C** (`scripts/typecheck-swift.sh`) | ≈ 1 min |
| `scripts/linux-engine.sh deps && build` puis `gate` | le moteur (libslic3r + ABI v3) compilé avec les paquets Ubuntu, la gate historique (8 100 lignes, 100 couches) et la **gate de scène** (90 vérifications contre le vrai bundle QIDI) | build ≈ 50 min à froid (4 cœurs), reprises en secondes |
| `scripts/linux-engine.sh clang` | notre code C++ analysé par clang `-Werror` (le compilateur de macOS/iOS) | secondes |
| `scripts/e2e-linux.sh` | le **vrai `SlicerModel`** (Swift) contre le vrai moteur et un Moonraker simulé : 68+ vérifications | ≈ 2 min |

Nécessite un toolchain Swift pour Linux (swift.org) pour `lint`, `typecheck` et `e2e`. Les vues SwiftUI /
SceneKit ne sont qu'analysées syntaxiquement : c'est la CI `ios-app` qui les compile.
