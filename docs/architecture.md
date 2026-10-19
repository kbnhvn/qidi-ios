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

### 11. ABI v3 : une session « scène » (plateau, presets du moteur, slicing incrémental)

L'ABI v1/v2 prenait un fichier et rendait un G-code : rien ne survivait à l'appel, donc pas de plateau
manipulable, pas de re-slicing rapide, pas de statistiques. La v3 (`core/src/scene.cpp`) garde en mémoire
dans `qsid_ctx` :

| État | Classe libslic3r | Ce que ça permet |
|---|---|---|
| objets du plateau | `Model` / `ModelObject` / `ModelInstance` | déplacer, tourner, copier, poser sur une face, organiser, un maillage par objet |
| presets | `PresetBundle` (`load_configbundle`, `update_compatible`) | mêmes héritages et mêmes conditions de compatibilité que le bureau (remplace la résolution Swift) |
| réglages forcés | `DynamicPrintConfig::set_deserialize` | validation par la définition de l'option ; une valeur égale au preset retire la surcharge |
| dernier slicing | `Print` conservé | `Print::apply` n'invalide que les étapes touchées ; résumé et mouvements du `GCodeProcessorResult` |

Conventions : sorties JSON (UTF-8) allouées par la bibliothèque et libérées par `qsid_free`, tampons
binaires pour les maillages (`float*`) et les mouvements (`qsid_move*`), mutations refusées pendant un slicing
(`QSID_ERR_BUSY`), appels sérialisés par une file côté Swift (`SlicerModel.onEngine`).

Le schéma des options (`qsid_config_schema`) est celui de `PrintConfigDef` (type, libellé, aide, bornes,
énumérations, mode). La **disposition** (onglets, pages, groupes) n'existe que dans le code wxWidgets
(`Tab.cpp`) : `scripts/gen-config-ui.py` l'extrait en JSON versionné, avec les traductions françaises du
bureau ; un test vérifie que chacune des 306 options placées existe dans le schéma du moteur.

Vérification : `core/gate/scene_gate.cpp` exerce chaque famille d'appels contre le vrai bundle QIDI
(`scripts/gate.sh` sur macOS, `scripts/linux-engine.sh gate` sous Linux) ; les sorties réelles sont
capturées dans `ios/QSlicerKit/Tests/QSlicerKitTests/Fixtures/engine/` et décodées par les tests Swift.

### 12. Découpage de l'app : logique pure testable / colle d'interface

| Couche | Contenu | Où c'est vérifié |
|---|---|---|
| `Core/*.swift` (Foundation seul) | géométrie du plateau et caméra, maillage du G-code, options, catalogue des réglages, filaments, calibrations (tour, ligne, motif, débit, débit volumétrique), plan de coupe, réglages par objet, sélection de groupe, QIDI Box, préréglages, découverte réseau, Moonraker, types JSON | `ios/QSlicerKit` : `swift test` sous Linux (91 tests) |
| `QSlicerCore` + `SlicerModel` | pont C, file série du moteur, état | `scripts/typecheck-swift.sh` : types avec le vrai en-tête C |
| `Screens/*.swift`, `BedSceneView`, `GCodeSceneView`, `ThumbnailRenderer` | SwiftUI / SceneKit / UIKit | analyse syntaxique sous Linux ; compilation par la CI `ios-app` ; recette iPad |

Le paquet `QSlicerKit` ne duplique rien : ses sources sont des liens symboliques vers `ios/QSlicerPad/Core`.

Le modèle reçoit ses chemins par `SlicerLocations` (bundle dans l'app, dossiers temporaires dans les
tests) : c'est ce qui permet à `scripts/e2e-linux.sh` de faire tourner le vrai `SlicerModel` contre le vrai
moteur (voir `docs/audit-ui-slicing.md`, « Test de bout en bout »).

### 13. ABI v3.1 : outils d'objet, multi-filament

Ajouts à `core/src/scene.cpp`, tous au-dessus de classes que le bureau utilise déjà :

| Fonction | Ce qu'elle appelle | Remarques |
|---|---|---|
| `qsid_scene_cut` | `Cut(...).perform_with_plane()` (`CutUtils`) | même matrice de coupe que `GLGizmoCut3D::get_cut_matrix` ; refuse un plan qui ne traverse pas l'objet ; les moitiés sont replacées sur le plateau sans chevauchement |
| `qsid_scene_simplify` | `its_quadric_edge_collapse` | par volume « pièce » ; `set_mesh` + `calculate_convex_hull`, comme `GLGizmoSimplify` |
| `qsid_object_config_set/reset` | `ModelObject::config` / `ModelVolume::config` | seules les options de `PrintObjectConfig` / `PrintRegionConfig` (+ `extruder`) sont acceptées ; le schéma les marque `"per_object":true` |
| `qsid_object_add_modifier`, `_set_modifier`, `_remove_volume` | `ModelObject::add_volume(mesh, type)` | formes unitaires (boîte, cylindre, sphère) mises à l'échelle ; types modificateur / bloqueur / forceur de supports |
| `qsid_layer_range_set/remove` | `ModelObject::layer_config_ranges` | refuse les chevauchements ; **chaque plage reçoit `layer_height` et `extruder`** (sans eux `layer_height_profile_from_ranges` déréférence un pointeur nul — bug trouvé par le test de bout en bout) |
| `qsid_presets_set_extruders` | `Preset::set_num_extruders`, `update_multi_material_filament_presets`, `set_filament_preset` | 1 à 16 extrudeurs (QIDI Box) ; le choix est mémorisé dans `ctx->extruder_filaments` et réappliqué à chaque changement d'imprimante ; `full_config()` bascule alors sur la lecture « un filament par extrudeur » |

`qsid_scene_info` expose pour chaque objet `config`, `volumes` (pièces et modificateurs avec position, taille et
réglages) et `layer_ranges`. Côté Swift : `CutPlane`, `ObjectSettings`, `SelectionGroup` (logique pure), et dans
`SlicerModel` une sélection multiple (`selectedObjectIDs`), un historique d'annulation par **groupe** de
transformations, les opérations de coupe / simplification / réglages, et le multi-filament.

**QIDI Box.** Ce que le bureau envoie à l'imprimante avant un job (`Plater`) est reproduit à l'identique :
`SAVE_VARIABLE VARIABLE=enable_box VALUE=1|0` puis `SAVE_VARIABLE VARIABLE=value_t<n> VALUE=\"'slot<k>'\"` par outil
(`QIDIBox.activationCommands`, envoyées par `POST /printer/gcode/script`). La **lecture automatique** du contenu du
Box passe par `QIDINetwork::get_box_info`, un module fermé absent des sources : elle n'est pas portée, les
emplacements se règlent à la main (et se relisent depuis les variables Klipper `save_variables`). La numérotation des
emplacements (0…15 = 1A…4D) suit l'ordre des plateaux du bureau ; elle reste à confirmer sur un vrai Box.

**Calibrations.** `Calibration.plan` couvre désormais tour / ligne / motif de Pressure Advance, débit grossier et fin,
et débit volumétrique maximal (plages de hauteurs avec `external_perimeter_speed` croissante, comme
`Plater::calib_max_volumetric_speed`). Ligne et motif génèrent leur G-code en Swift (`CalibrationGCode`, port de
`calib_pa_line` / `calib_pa_pattern`) et le placent à la fin du G-code de l'imprimante ; seules les étiquettes
numériques (maillage de texte) sont remplacées par une légende dans l'app.

**Découverte des imprimantes.** `PrinterDiscovery` balaie les sous-réseaux des interfaces actives (au plus un /22) en
sondant `GET /server/info` — seul un vrai Moonraker répond avec `moonraker_version` — et `BonjourBrowser`
(`_moonraker._tcp`, `_http._tcp`) accélère la recherche. Info.plist déclare `NSBonjourServices` et la raison de
l'accès au réseau local.

### 14. Robustesse du slicing sur iPad

Trois choses se jouent au moment de « Slicer », et aucune ne se voyait sous Linux :

- **Pile.** Un thread secondaire de GCD n'a que 512 Ko de pile sous iOS (8 Mo ailleurs) ; le découpage récursif de
  libslic3r la dépasse sur des modèles réels et l'app tombe sans message. Le moteur tourne donc sur un fil dédié de
  **64 Mo** (`EngineThread`, Swift) et les threads de travail de TBB reçoivent **16 Mo** (`tbb::global_control` dans
  `qsid_create`).
- **Vignettes.** Le moteur appelle le fournisseur *pendant* le slicing, depuis son thread. Un rendu SceneKit/Metal hors
  écran exigeait le thread principal et un appareil Metal : remplacé par un rasteriseur logiciel
  (`SoftwareThumbnail` : tampon de profondeur, Lambert, suréchantillonnage 2×2), sans appel système, testé sous Linux.
- **Trace de plantage.** `SliceBreadcrumb` écrit la progression sur disque au fil de l'eau ; au lancement suivant,
  si le fichier existe encore, l'app affiche la dernière étape atteinte.

### 15. Annuler / rétablir

L'historique mêle deux sortes d'entrées : un groupe de transformations (déplacements, rotations, échelles) et un
**instantané complet de la scène** (`qsid_scene_snapshot/restore/discard`). Les maillages sont partagés (`shared_ptr`) :
un instantané coûte peu, 64 au plus côté moteur, 60 entrées côté app. Restaurer conserve les identifiants d'objets.
