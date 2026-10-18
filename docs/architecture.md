# Architecture

## Vue d'ensemble

```
┌──────────────────────────────────────────────────────────────────────┐
│ App iPadOS — SwiftUI (ios/QSlicerPad)                                │
│   écran, import de fichiers, état de l'app, partage du G-code        │
├──────────────────────────────────────────────────────────────────────┤
│ ABI C étroite — core/include/qidislice.h                             │
│   qsid_create / qsid_slice_async / qsid_cancel / qsid_export_stl     │
│   qsid_slice + qsid_run_cli (v1, CLI) — v2 : API objet libslic3r     │
├──────────────────────────────────────────────────────────────────────┤
│ ios-core (compilé dans l'arbre amont)                                │
│   src/CLI/*  → Slic3r::CLI::run()      (le point d'entrée du desktop) │
│   src/libslic3r → le moteur                                          │
├──────────────────────────────────────────────────────────────────────┤
│ src/libslic3r + libslic3r_cgal + arrange + seqarrange + libvgcode(v2) │
├──────────────────────────────────────────────────────────────────────┤
│ Dépendances statiques cross-compilées pour arm64-ios                  │
│ Boost · TBB · CGAL · GMP · MPFR · Eigen · OpenVDB/Blosc/Cereal ·      │
│ Qhull · z3 · LibBGCode · heatshrink · PNG · JPEG · EXPAT · miniz …    │
└──────────────────────────────────────────────────────────────────────┘
```

Tout ce qui est au-dessus de l'ABI C est écrit une fois ; l'interface est la seule partie spécifique
à la plateforme — le même choix que les portages iOS existants (voir
[`../PORTAGES_IOS_EXISTANTS.md`](../PORTAGES_IOS_EXISTANTS.md)).

## Décisions

### 1. Réutiliser la moitié « moteur » de l'amont, pas la GUI

`SLIC3R_GUI=OFF` existe déjà en amont : il ne compile ni wxWidgets, ni OpenCSG, ni GLEW, ni NanoSVG,
ni `src/slic3r` (la GUI, ~250 fichiers). C'est exactement la découpe nécessaire — wxWidgets n'a pas de
backend iOS (`wxOSX/iPhone` est un stub).

### 2. Le slicing passe par `Slic3r::CLI::run()` (pour la v1)

Le binaire macOS livré par QIDI contient `Slic3r::CLI::run(int, char**)` : c'est un point d'entrée réel,
appelé tel quel par `main()`, dans le même exécutable que la GUI. L'appeler **dans le processus** évite
toute la machinerie de sous-processus, impossible sous iOS.

Conséquence : la v1 n'a ni progression, ni annulation, ni erreurs structurées — la CLI imprime sur la
sortie standard, qui n'existe pas sous iOS. La v2 passera à l'API objet (`Slic3r::Model`, `Slic3r::Print`,
`GCodeGenerator`) pour les obtenir. Ce compromis est explicite dans `core/include/qidislice.h`.

### 3. `core/` est compilé *dans* l'arbre amont

`scripts/bootstrap.sh` copie `core/` en `third_party/qidislicer/ios-core/`, et le patch
`0004-ios-core-target.patch` ajoute `add_subdirectory(ios-core)` depuis `src/CMakeLists.txt`. Bénéfice :
la cible hérite de `SLIC3R_CLI_SOURCES` et lie `libslic3r` **comme cible CMake**, donc toutes les
dépendances transitives sont résolues par CMake au lieu d'être énumérées à la main.

### 4. Une archive fusionnée pour l'app

`scripts/package-engine.sh` fusionne toutes les archives (moteur + nos cibles + préfixe de dépendances,
~50–60 fichiers) en un seul `QSlicerEngine.a`. Une ligne de liens Xcode qui énumère ces archives se
périmerait à chaque évolution du moteur. Ce que la fusion ne peut pas transporter — ce que le moteur
résout dans le SDK (`-lexpat -liconv -lz`, `Foundation`, `ModelIO`, `Accelerate`, `IOKit`,
`CoreFoundation`, `CoreGraphics`, `CoreServices`) — est listé dans `QSlicerEngine-link.txt` et réinjecté
à l'édition de liens de l'app.

### 5. XcodeGen plutôt qu'un `.xcodeproj` versionné

Un projet Xcode est un fichier binaire difficile à relire et à fusionner. `ios/project.yml` est la
source : `xcodegen generate` recrée le projet — y compris en local, et la CI fait pareil.

### 6. Patches plutôt qu'un fork

Les modifications des sources amont sont une **série de patches** (4 fichiers, ~90 lignes) appliquée à
une révision épinglée (`QSID_REV` dans `scripts/lib/common.sh`). Mettre à jour = rebaser la série, ce
que `scripts/lint.sh` vérifie à chaque exécution.

Les quatre patches :

| Patch | Fichier | Ce qu'il règle |
|---|---|---|
| `0001-ios-cross-compilation` | `CMakeLists.txt` | iOS = cross-compilation (tests désactivés) ; refuse `SLIC3R_GUI=ON` sur iOS ; désactive STEP/OCCT par défaut |
| `0002-deps-ios-subbuild` | `deps/CMakeLists.txt` | les sous-builds de dépendances héritent de `CMAKE_SYSTEM_NAME=iOS`, du sysroot, de `CMAKE_FIND_ROOT_PATH` ; `CMAKE_MACOSX_BUNDLE=OFF` ; OpenGL/CURL ne sont plus « fournis par le système » |
| `0003-gmp-ios-autotools` | `deps/+GMP/GMP.cmake` | triples autoconf distincts (`aarch64-apple-ios` vs `aarch64-apple-darwin`), `--disable-assembly`, compilateur de build (`CC_FOR_BUILD`) |
| `0004-ios-core-target` | `src/CMakeLists.txt` | ajoute `ios-core/` (ABI C + gate) à l'arbre |

### 7. Ce que la v1 n'inclut pas volontairement

| Écarté | Pourquoi |
|---|---|
| wxWidgets, GLEW, OpenCSG, NanoSVG | GUI uniquement ; wxWidgets n'a pas de portage iOS |
| CURL, OpenSSL | utilisés seulement par `src/slic3r` (réseau/GUI) ; reviendront avec la connexion QIDI en v2, et OpenSSL 1.1.0l demande alors son propre patch |
| OCCT (import STEP) | `SLIC3R_ENABLE_FORMAT_STEP=OFF` en v1 : gros morceau, aucun besoin pour slicer du STL/3MF |
| PCH | première compilation iOS : moins de variables d'un coup |

### 8. ABI v2 : progression, annulation, export STL

La v1 appelait `Slic3r::CLI::run()` : simple, mais sans progression ni annulation (la CLI écrit sur
stdout et ne s'interrompt pas). La v2 utilise l'API objet que le binaire desktop emploie déjà :

| Appel ABI | Implémentation libslic3r |
|---|---|
| `qsid_slice_async` | `FileReader::load_model` → `DynamicPrintConfig::load_from_ini` → `Print::apply` → `Print::process` → `Print::export_gcode` |
| progression | `PrintBase::set_status_callback` (`SlicingStatus.percent/text`) |
| `qsid_cancel` | drapeau atomique + `PrintBase::cancel()` (appelable depuis un autre thread, comme le GUI) |
| `qsid_export_stl` | CLI `--export-stl` (le moteur convertit 3MF/OBJ/AMF en STL pour le visualiseur) |

Un seul slicing à la fois (`QSID_ERR_BUSY`) : libslic3r n'est pas réentrant ; les erreurs
d'annulation remontent en `QSID_ERR_CANCELED` (`Slic3r::CanceledException`).

### 9. Profils : résolution d'héritage côté Swift

Le bundle QIDI est un ensemble de sections héritées (`inherits = *Q2*; *0.12mm Extra High*`).
Deux options : installer le bundle via `PresetBundle` (mécanique AppConfig + dossier vendor, non
testable ici), ou **résoudre les chaînes nous-mêmes**. La seconde a été retenue : elle est explicite,
vérifiable hors app, et produit un `.ini` complet que `qsid_slice_async` consomme sans état caché.

Vérifié sur le vrai bundle : 24 imprimantes, 78 réglages, 858 filaments, séparateurs `,` **et** `;`,
suffixes `@<imprimante>` ; `Q2 0.4 nozzle` → 94 clés, `0.12mm Extra High @Q2 0.4 nozzle` → 188,
`QIDI ABS Odorless @Q2 0.4 nozzle` → 89, fusion → 369 clés.

### 10. Rendu et réseau : ce qu'on ne porte pas

- **Visualiseur** : SceneKit (donc Metal). On évite pour l'instant le portage du viewport C++
  OpenGL ES (`SLIC3R_OPENGL_ES` + `libvgcode`) : SceneKit donne un rendu correct avec très peu de
  code, et le G-code est affiché par couche (analyse en *streaming*, jamais le fichier entier).
- **Réseau** : Swift `URLSession` (Moonraker). C'est l'option « réécrire les appels réseau en Swift »
  de la roadmap : elle évite de porter OpenSSL 1.1.0l et libcurl, et laisse la place à `WKWebView`
  si la connexion cloud QIDI est reprise un jour.
