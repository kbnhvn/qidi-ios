# QSlicerPad — le moteur de QIDISlicer sur iPadOS

Portage **non officiel** du moteur de slicing de [QIDISlicer](https://github.com/QIDITECH/QIDISlicer)
(lui-même dérivé de PrusaSlicer, AGPL-3.0) vers **arm64-iOS**, avec une interface SwiftUI et une
distribution en `.ipa` non signée (SideStore).

Objectif : slicer **sur l'iPad**, hors ligne, avec le même moteur que le bureau — donc le même G-code —
sans serveur et sans sous-processus (interdits par iOS).

---

## État réel du projet

| Élément | État | Preuve |
|---|---|---|
| Dépendances cross-compilées (Boost, TBB, CGAL, OpenVDB, Blosc, z3, GMP/MPFR, Qhull, PNG/JPEG, Expat, heatshrink, LibBGCode, NLopt, Eigen, Cereal) | **✅ compilées pour arm64-iphoneos** | job `ios-engine` vert ; toutes les archives `lipo` = arm64, `vtool` = *platform IOS, minos 15.0* |
| Moteur `libslic3r` + ABI C | **✅ compilés et liés** | `Cœur (iOS arm64)` vert ; archive fusionnée de **136 Mo** ; symboles `qsid_*` présents |
| App SwiftUI | **✅ compilée et liée** | `ios-app` vert, deux fois ; binaire **27 Mo**, `Mach-O arm64`, *platform IOS, minos 17.0* |
| `.ipa` non signée | **✅ produite** | artefact `QSlicerPad-unsigned-ipa` (**8,4 Mo**, 0.3.0 build 3), profils QIDI embarqués sous `qidi/profiles/`, icônes compilées |
| Série de patches iOS | **✅ 16 patches**, appliqués en séquence | `scripts/lint.sh` les rejoue à chaque exécution |
| Gate de slicing à l'exécution (hôte macOS) | **✅ verte** (run `39130857606`) | cube 20 mm slicé par les deux chemins : CLI v1 et API objet v2 (chemin de l'app) → **G-code identique octet pour octet** (8 100 lignes, 100 couches, 1 397,9 mm), objet centré, progression 10→90 % |
| Slicing réel sur iPad | **⏳ à faire** | nécessite d'installer l'IPA (SideStore) |
| Profils QIDI embarqués (24 imprimantes, 78 réglages, 858 filaments) | **🟡 résolution vérifiée localement** | chaînes `inherits` résolues sur le vrai bundle : `Q2 0.4 nozzle` → 94 clés, preset print → 188, filament → 89, fusion → 369 |
| Progression + annulation du slicing | ✅ progression validée en gate ; annulation compilée | ABI `qsid_slice_async` / `qsid_cancel` au-dessus de `Print::apply/process/export_gcode` |
| Plateau 3D, manipulation d'objets (sélection multiple, menu contextuel, coupe, simplification), aperçu G-code en rubans, tous les réglages (dont par objet, modificateurs, plages de hauteurs), multi-filament / QIDI Box, calibrations, découverte des imprimantes | 🟡 écrit et analysé, **non compilé sous Xcode** | logique pure testée sous Linux (91 tests) ; types du modèle et du pont C vérifiés ; vues SwiftUI/SceneKit à compiler par la CI `ios-app` |
| Modèle de l'app (`SlicerModel`) de bout en bout contre le vrai moteur | ✅ 167 vérifications (Linux) | `scripts/e2e-linux.sh` : presets, scène, multi-sélection, coupe, réglages par objet, slicing, aperçu, calibrations, multi-filament, QIDI Box, découverte réseau… (a trouvé 5 bugs) |
| ABI v3 (scène, presets du moteur, slicing incrémental, vignettes, calibration, coupe, simplification, réglages par objet, multi-filament) | ✅ gate de scène verte (178 vérifications, aussi sous ASan/UBSan) | exécutée sous Linux contre le vrai moteur et le bundle QIDI (`scripts/linux-engine.sh gate`) ; CI macOS : `host-gate` |
| Envoi à l'imprimante (Moonraker) | 🟡 compilé, non exercé | `URLSession` : upload `server/files/upload` + `printer/print/start` + état |

Autrement dit : **rien n'a encore été compilé ici** (l'environnement de rédaction est Linux, sans SDK
Apple). Le premier passage de la CI est le point de vérité ; il est normal qu'il demande quelques
itérations — c'est la nature d'un portage de cette base (voir [`docs/risks.md`](docs/risks.md)).

Pourquoi c'est plausible malgré tout :

- le build macOS livré par QIDI prouve que tout l'arbre compile pour **arm64-Apple**
  ([`ANALYSE_MACOS_WINDOWS.md`](ANALYSE_MACOS_WINDOWS.md)) ;
- l'amont possède déjà `SLIC3R_GUI=OFF` (moteur sans wxWidgets) et `SLIC3R_OPENGL_ES` ;
- **deux portages iOS existent déjà** et documentent la même classe de problèmes
  ([`PORTAGES_IOS_EXISTANTS.md`](PORTAGES_IOS_EXISTANTS.md)).

---

## Démarrage rapide (sans Mac : GitHub Actions)

1. **Pousser ce dépôt sur GitHub** (Actions activées) :
   ```bash
   git remote add origin git@github.com:<vous>/qidi-ios.git
   git push -u origin main
   ```
2. Un push ne lance que **`configure-check`** (quelques minutes : patches + configuration des
   dépendances) — les runners macOS sont facturés ×10 en minutes Actions et le build complet dure 1–2 h.
   Trois portées, du moins cher au plus cher :
   ```bash
   gh workflow run ios.yml -f scope=configure    # défaut (ce que fait un push)
   gh workflow run ios.yml -f scope=deps-smoke   # + quelques dépendances compilées pour arm64-ios
   gh workflow run ios.yml -f scope=engine       # + moteur arm64-ios, app et .ipa
   gh workflow run ios.yml -f scope=full         # tout, gate hôte comprise
   ```
   (ou `gh variable set QSID_FULL_CI --body true` pour que chaque push lance tout).
3. `engine` puis `full` enchaînent : moteur arm64 → app → **`QSlicerPad-unsigned.ipa`** en artefact
   (`full` ajoute la gate hôte, qui exécute un slicing réel sur macOS).
4. Télécharger l'artefact, puis installer avec **SideStore** : [`docs/sideloading.md`](docs/sideloading.md).
- Recette pas-à-pas sur l'appareil : `docs/recette-ipad.md`
- Audit UI/UX + qualité de slicing et plan de travail : `docs/audit-ui-slicing.md`

> **Quota Actions.** Les runners macOS comptent **×10** en minutes. Mesuré sur ce projet :
> `configure` ≈ 15 s, `deps-smoke` ≈ 1 min, `engine` (moteur + app + IPA, cache chaud) ≈ 5 min,
> premier passage à froid ≈ 10 min, `host-gate` ≈ 10 min. Au-delà du quota inclus, GitHub refuse de
> démarrer les jobs : *« recent account payments have failed or your spending limit needs to be
> increased »*. Deux issues : relever la limite de dépense, ou rendre le dépôt **public** (les minutes
> des runners standard sont alors gratuites — cohérent avec l'AGPL, qui impose déjà la publication du
> source).

## Construction locale (macOS requis)

```bash
brew install cmake ninja xcodegen
scripts/bootstrap.sh                       # clone épinglé + patches + ios-core
QSID_TARGET=host scripts/build-deps.sh     # dépendances macOS (pour la gate)
QSID_TARGET=host scripts/build-engine.sh gate
QSID_TARGET=host scripts/gate.sh           # le moteur slice réellement un cube → G-code

QSID_TARGET=ios scripts/build-deps.sh      # dépendances arm64-iphoneos (~1–2 h)
QSID_TARGET=ios scripts/build-engine.sh
QSID_TARGET=ios scripts/package-engine.sh
QSID_TARGET=ios scripts/stage-resources.sh
QSID_TARGET=ios scripts/package-ipa.sh     # → build/dist-ios/QSlicerPad-unsigned.ipa
```

Détails, cibles (`ios`, `iossim`, `host`) et politique de patches : [`docs/building.md`](docs/building.md).

---

## Structure

```
core/                 ABI C du moteur + gate de vérification (copiés dans l'arbre amont)
  include/qidislice.h
  src/qidislice.cpp
  gate/main.cpp
ios/                  app SwiftUI (XcodeGen) — voir ios/README.md
patches/              série de patches iOS appliquée aux sources QIDISlicer
scripts/              bootstrap, deps, moteur, gate, paquetage, lint
cmake/toolchains/     toolchain iOS
testdata/             cube 20 mm + configuration FFF générique (gate)
.github/workflows/    CI macOS complète
docs/                 architecture, build, sideload, risques, feuille de route
FEASIBILITY.md        étude initiale (AppImage Linux)
ANALYSE_MACOS_WINDOWS.md  analyse REA des builds macOS/Windows
PORTAGES_IOS_EXISTANTS.md état de l'art des portages iOS existants
```

Le dossier `third_party/qidislicer/` (sources QIDISlicer clonées) et `build/` ne sont pas versionnés.

---

## Ce que fait la v1

- importer un modèle (STL/3MF/OBJ), choisir un profil exporté depuis QIDISlicer desktop,
  **slicer sur l'iPad**, partager/le déposer dans Fichiers ;
- lister les modèles d'imprimante du bundle vendor QIDI embarqué (repère visuel) ;
- tout est local : aucun réseau, aucun compte, aucun serveur.

**Pas encore** : connexion cloud QIDI (`QIDIConnect`), import STEP/OCCT, distribution TestFlight.
Voir [`docs/roadmap.md`](docs/roadmap.md) — chaque ligne dit si elle est ✅ vérifiée, 🟡 écrite mais non
validée, ou ⛔ bloquée (facturation Actions, iPad, compte Apple).

## Licence

**AGPL-3.0**, comme QIDISlicer dont ce projet dérive : toute distribution (y compris une `.ipa`
publiée ou déposée sur une source SideStore) doit fournir le code source correspondant. Le texte de
la licence est dans [`LICENSE`](LICENSE).
