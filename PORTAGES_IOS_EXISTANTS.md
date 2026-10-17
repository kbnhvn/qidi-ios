# libslic3r / PrusaSlicer sur arm64 iOS : état de l'art GitHub

Réponse courte : **oui, la bibliothèque a déjà été portée sur arm64-iOS — au moins trois fois**, et de
façon sérieuse deux fois. Le point commun des trois : **personne n'a porté la GUI**. Tous portent
`libslic3r` en *headless* derrière une ABI C et réécrivent l'interface en SwiftUI/Compose avec un
viewport OpenGL ES. C'est exactement le scénario D de [`FEASIBILITY.md`](./FEASIBILITY.md), avec les
recettes de compilation qui manquaient.

> **Suite** : ces recettes ont été appliquées dans ce dépôt — voir [`README.md`](./README.md)
> (série de patches iOS sur les sources officielles QIDISlicer, ABI C, app SwiftUI, CI macOS).

Vérifications faites le 2026-10-18 via GitHub (`search_code`, `search_repositories`, `search_issues`,
`get_file_contents`, `get_latest_release`, `issue_read`). Rien n'a été compilé ni exécuté ici :
les « claims » des README sont marqués comme tels.

---

## 1. Ports natifs iOS d'un moteur slic3r

| Projet | Moteur | Statut observable | Interface | Rendu | Distribution |
|---|---|---|---|---|---|
| **`bo0tzz/slicepad`** | **OrcaSlicer** (headless) | releases jusqu'à **v0.0.6** (2026-08-14) avec asset **`SlicePad.ipa`** (5 807 503 octets) | SwiftUI | — | `.ipa` non signée + source **SideStore** |
| **`NilsN3DP/SlicerMobile`** | **PrusaSlicer `version_2.9.6`** patché | bêta publique **0.2.2 (build 30)**, sept. 2026 ; pas de release GitHub | **SwiftUI** (iOS = référence) + Compose (Android) | **OpenGL ES** (viewport C++ partagé, `CAEAGLLayer`) | **TestFlight** + test fermé Play Store |
| **`adickin/PalmSlice`** | `libslic3r.a` cross-compilé arm64 | projet jeune (maj 2026-10-16), pas de release ; « entirely written by AI » | SwiftUI | **SceneKit** | — (local) |

### 1.1 `bo0tzz/slicepad` — le plus proche d'un « mode d'emploi »

Arborescence : `CMakeLists.txt`, `core/` (ABI C), `cli/main.cpp`, `app/Resources`, `patches/`,
`scripts/`, `tests/gate.cpp` (69 883 o), `docs/`, `.github/workflows/ci.yml` (25 134 o), `mise.toml`,
`sidestore.json`. Pas de `LICENSE` à la racine (voir §4).

**Preuves de faisabilité déjà présentes dans le dépôt** :

- `scripts/build-ios-framework.sh` : les drapeaux de compilation du cœur pour iOS —
  `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_SYSROOT=iphoneos` (ou `iphonesimulator`, préfixe de
  dépendances séparé, car ce sont deux plateformes Apple distinctes), puis fusion de **56 archives
  statiques en une seule `.a`** pour que la ligne de link Xcode tienne en une entrée.
- `docs/ios-cross-compile.md` (6 405 o) : journal des échecs du superbuild `deps/` d'OrcaSlicer sur iOS,
  avec les patches **0010–0012 (+0014)** :
  - `CMAKE_SYSTEM_PROCESSOR` est **vide** pour iOS → `list(FIND …)` et les `STREQUAL` d'OpenSSL cassent
    (le même bug existe dans `deps/CMakeLists.txt` **et** dans la racine du moteur) ;
  - GMP : triple `--build` = `-apple-darwin` rejeté par `config.sub` ; MPFR reçoit un `--host=` nu ;
  - les sous-builds n'héritent ni de `CMAKE_SYSTEM_NAME`, ni du sysroot, ni de la cible de déploiement ;
  - autoconf exige des triples **différents** (`aarch64-apple-ios` vs `aarch64-apple-darwin`) sinon il se
    croit natif ; il faut donc deux compilateurs (`CC_FOR_BUILD`, et `-isysroot` l'emporte sur `SDKROOT`) ;
  - **GMP `--disable-assembly` sur iOS** (syntaxe de relocation `adrp x7, :got:sym` rejetée par as) —
    sans conséquence sur le slicing, GMP ne servant qu'aux prédicats exacts de CGAL ;
  - `CMAKE_MACOSX_BUNDLE=OFF` pour tous les sous-builds (CMake fait un bundle de chaque exécutable iOS ;
    Qhull puis PNG/JPEG/Expat échouent en « no BUNDLE DESTINATION ») ;
  - OpenSSL : `ios64-cross` compose `-isysroot` depuis `CROSS_TOP`/`CROSS_SDK` → `/SDKs/` littéral ;
  - `CMAKE_FIND_ROOT_PATH` obligatoire (le sysroot confine les recherches `find_package`) ;
  - **JPEG** : le superbuild déclare `dep_JPEG` mais ne le construit jamais (patch 0014) — invisible sur
    desktop parce qu'il linkait le libjpeg du runner ; **expat**, lui, est légitimement pris dans le SDK.
- Ce qu'une archive statique ne peut pas transporter : à la fin, il faut re-déclarer dans l'app ce que le
  moteur prend du SDK — `-lexpat -liconv -lz` et les frameworks `Foundation`, `ModelIO`, `Accelerate`.

**Claims du README** (non vérifiés ici) : 113 dépendances + libslic3r + ABI C + app SwiftUI compilent et
linkent pour **arm64-iOS**, avec `.ipa` non signée publiée à chaque run de CI qui *vérifie* que le bundle
est bien arm64/iOS, contient le moteur et les ressources ; 13 « gates » comparent le G-code à celui d'Orca
desktop depuis le même profil (dont un cas **byte-identique, 3 328/3 328 commandes**) ; sur iPad le G-code
est « équivalent, pas identique » (extrusions < 1 %) ; une impression réelle réussie sur une Sovol SV08.
Statut auto-déclaré de l'app : *« written, not yet used »*.

### 1.2 `NilsN3DP/SlicerMobile` — le plus abouti, et il documente les décisions

`external/PrusaSlicer` = PrusaSlicer **`version_2.9.6`** + `patches/`, `core/` (ABI C `psmobile_core.h`),
`viewport/` (rendu **OpenGL ES**, G-code via **libvgcode**), `android/shared` (Kotlin Multiplatform),
`ios/PSMobile` (SwiftUI + **XcodeGen**), `cmake/toolchains/ios.cmake` + `android.cmake`,
`build/scripts/*`.

Les ADR (`docs/decisions.md`) confirment, indépendamment de mon analyse des binaires QIDI, les points
structurants :

> **E-01** : « `src/libslic3r` (190k LOC) has zero wxWidgets includes and is portable C++17.
> `src/slic3r` (166k LOC, 404 files) is completely bound to wxWidgets; wxWidgets has no Android port
> and **`wxOSX/iPhone` is a stub**. The GUI layer therefore cannot come along technically. »

> **E-02** : interface native par plateforme (Compose/SwiftUI) au-dessus d'un **viewport C++ partagé en
> OpenGL ES**, embarqué via `GLSurfaceView`/`CAEAGLLayer`.

> **E-03** : ABI **C étroite** comme seule frontière ; le viewport reste en C++ et ne traverse pas l'ABI
> à chaque frame.

Chaîne de build iOS : Mac avec **Xcode 26**, CMake, Ninja, XcodeGen, JDK 17 ;
`PSM_IOS_PLATFORM=OS64 build/scripts/build-ios.sh all` (deps ~1–2 h par cible, cœur ~15 min) ;
`cmake/toolchains/ios.cmake` s'appuie sur le support iOS intégré de CMake. Les dépendances viennent du
`deps/` de PrusaSlicer, **moins** ce qui est exclu pour mobile (`build/scripts/dep-excludes.sh`) :
**wxWidgets, GLEW, OpenCSG, Catch2, CURL, OpenSSL**. Points d'attention documentés : GMP/MPFR en
autotools passent par `build/scripts/mk-autotools-wrappers.sh` ; libslic3r active
`-fno-aligned-allocation` pour Apple, inutile à partir de la cible de déploiement 15.0.

Statut : bêta publique 0.2.2 (build 30, sept. 2026), iOS via TestFlight, Android en test fermé ;
import STL/3MF/OBJ/**STEP (OCCT compilé)** ; envoi PrusaLink/OctoPrint ; « Klipper par le réseau non testé ».

### 1.3 `adickin/PalmSlice` — confirmation de la liste de dépendances

`SwiftUI → bridge C → libslic3r.a (arm64) → ~/ios-sysroot-sim/lib/` avec **Boost, TBB, CGAL, GMP, MPFR,
Qhull, LibBGCode, heatshrink, Clipper2, zlib, libpng, expat, nlohmann_json**. Viewer en SceneKit, export
G-code vers Fichiers/partage/OctoPrint. Il formule aussi la contrainte iOS dans son README : iOS interdit
de lancer des processus fils et le chargement de bibliothèques dynamiques à l'exécution (d'où le rejet de
CuraEngine, « architected as a CLI process communicating over a socket »).

---

## 2. Précédents mobiles et navigateur (utiles pour la décision)

| Projet | Approche | Intérêt pour nous |
|---|---|---|
| `utkabobr/SliceBeam` | **Android**, cœur PrusaSlicer, UI tactile ; **version web** `slice.beam3d.ru` | preuve que le cœur tourne sur mobile **et** en WASM |
| `taylormadearmy/u1-slicer-for-android` | OrcaSlicer (fork Snapmaker 2.2.4) via **JNI**, Kotlin/Compose, v4.0.1 | le « twin » Android du montage iOS |
| `ignacio82/OrcaXR` | OrcaSlicer compilé en **WebAssembly** (`wasm/slic3r_wasm.cpp`, `build_wasm_module.sh`, stubs) | slicing **dans Safari** sur iPad, sans sideload |
| `kimgh06/Three_Slicer` ★31 | « 3D Slicer For Browser (based on OrcaSlicer) » | même famille |
| `GridSpace/grid-apps` (Kiri:Moto) ★922 | moteur propre, 100 % navigateur | déjà cité dans `FEASIBILITY.md` §5.A |
| `mon593-dot/SnapSlice` | app **iPhone** qui slice avec **Kiri:Moto** (moteur navigateur dans une app) | alternative « sans libslic3r » |

---

## 3. Statut en amont (Prusa / Orca)

| Issue | État | Détail |
|---|---|---|
| `prusa3d/PrusaSlicer#8166` — « PrusaSlicer iOS/iPadOS app(s) » | **fermée 2026-09-10** (créée 2022-04-05) | fermée par politique (« legacy ») et **déplacée en Discussions** ; commentaire de `lukasmatena` : un post de Josef Prusa est *« not a promise of anything, just a hint that this was not forgotten in the 3.x rewrite »* |
| `OrcaSlicer/OrcaSlicer#4558` — « Port mac ARM application to iPad OS… » | **fermée `not_planned`** (2024-06-26) | — |
| `OrcaSlicer/OrcaSlicer#13156` — « iPad version » | **fermée comme doublon** (2026-04-10) | un mainteneur y renvoie vers « the web-version of Slice Beam (a **port of PrusaSlicer to mobile platforms**) » |

Aucun portage iOS officiel n'existe donc côté Prusa/Orca ; tout est communautaire. Bonne nouvelle pour
le projet QIDI : **le code source officiel existe aussi** (`QIDITECH/QIDISlicer`, fork PrusaSlicer sous
AGPL — vu notamment via `src/libslic3r/PrintConfig.cpp`), donc on n'est pas obligé de partir du binaire.

---

## 4. Licence et distribution (à ne pas rater)

- QIDISlicer descend de PrusaSlicer → **AGPL-3.0** : toute version distribuée (même un `.ipa` publié ou
  poussé sur SideStore) doit fournir le source correspondant. Sideload privé : pas de publication, donc
  pas d'obligation de distribution.
- `NilsN3DP/SlicerMobile` déclare **AGPL-3.0** (`LICENSE`).
- `bo0tzz/slicepad` : **aucun `LICENSE` à la racine** observé alors qu'il embarque le moteur
  **OrcaSlicer (AGPL-3.0)** — c'est une lacune de conformité de *leur* dépôt, pas un modèle à suivre.
- Distributions iOS constatées : **`.ipa` non signée + source SideStore** (slicepad — précisément la voie
  décrite dans `FEASIBILITY.md` §6) et **TestFlight** (SlicerMobile, donc compte développeur Apple).

---

## 5. Ce que ces précédents règlent (face aux blocages de `ANALYSE_MACOS_WINDOWS.md` §6.2)

| Blocage identifié dans nos binaires | Réglé par les ports existants | Comment |
|---|---|---|
| Sous-processus `fork`/`execve`/`popen`/`system` | ✅ contourné | cœur appelé **in-process** via ABI C ; PalmSlice documente explicitement l'interdiction iOS |
| Scan Wi‑Fi par `airport -I` | ⚠️ n/a chez eux | QIDI devra réécrire cette aide (NEHotspotNetwork) ou la supprimer |
| Frameworks macOS-only (`CoreWLAN`, `DiskArbitration`, `IOKit`, `Carbon`) | ✅ éliminés | la GUI n'est pas portée |
| wxWidgets absent sous iOS | ✅ confirmé et contourné | ADR E-01 : `wxOSX/iPhone` = stub ; UI réécrite |
| OpenGL desktop + GLU | ✅ remplacé | viewport **OpenGL ES** (SlicerMobile, `CAEAGLLayer`) ou SceneKit (PalmSlice) |
| Entitlements macOS sans équivalent | ✅ sans objet | app non sandboxée macOS non réutilisée ; `.ipa` non signée (SideStore) ou TestFlight |
| Bundle en lecture seule | ✅ | profils/ressources *staged* dans le bundle, écritures dans le conteneur |
| Toolchain (SDK iOS, Xcode) | ✅ recettes publiées | CMake iOS toolchain, XcodeGen, CI macOS arm64 |
| TBB / CGAL / GMP / MPFR / Qhull / OCCT sur iOS | ✅ (déclaré compilé) | PalmSlice liste TBB/CGAL/GMP/MPFR/Qhull ; SlicerMobile embarque OCCT ; slicepad : 113 deps ; **GMP : `--disable-assembly`** |
| Mémoire / thermique sur iPad | 🟡 partiellement | claims : impression réelle depuis un iPad (slicepad), profils Prusa testés (SlicerMobile) |

---

## 6. Ce que ça change pour QIDISlicer → iPadOS

1. **La question « est-ce porté ? » est close** : oui, sur arm64-iOS, avec des `.ipa` réellement
   produites. La question ouverte devient « combien de travail QIDI-spécifique ».
2. **La recette est téléchargeable** : patches `deps/` + drapeaux CMake de slicepad, `dep-excludes.sh` +
   toolchain iOS de SlicerMobile. Les corrections (GMP/MPFR autoconf, `CMAKE_SYSTEM_PROCESSOR` vide,
   bundles, sysroot OpenSSL, `CMAKE_FIND_ROOT_PATH`, JPEG absent) sont **de classe**, pas propres à
   OrcaSlicer : elles se reproduiront avec l'arbre PrusaSlicer de QIDISlicer 1.2.5.
3. **Ce qui restera spécifiquement QIDI** : connexion cloud (`Slic3r::QIDIConnectNew`, webview WKWebView
   + pont JS — déjà portable), types d'hôtes (`Moonraker`, `OctoPrint` — portable), profils QIDI
   (ressources, portable), et l'assistant Wi‑Fi (à réécrire). Tout cela est décrit dans
   `ANALYSE_MACOS_WINDOWS.md` §3.5–3.6.
4. **Deux trajectoires crédibles** :
   - *SlicerPad-like* : cœur + ABI C + SwiftUI + viewport GLES + `.ipa` SideStore → iPad autonome.
   - *WebAssembly* : `OrcaXR`/`Three_Slicer` montrent la voie navigateur (pas de sideload, mais RAM).
5. **Étape 0 recommandée** (inchangée, désormais avec des références) : partir du **source officiel
   QIDISlicer**, compiler `libslic3r` pour `arm64-iphoneos` avec les drapeaux de slicepad
   (cible de déploiement 15.0, sysroot `iphoneos`), et appeler le slicing **in-process** (CLI `run()`
   ou petite ABI C) — sans GUI, sans sous-processus.

---

## 7. Réserves

- Aucune compilation, aucun test d'app, aucune vérification des « gates » revendiqués : ce sont des
  affirmations de README, citées comme telles. Seules sont **observées** : l'existence des dépôts, leurs
  fichiers, leurs dates, la release `v0.0.6` de slicepad **avec l'asset `SlicePad.ipa`**, les ADR et les
  scripts de build.
- Les numéros de version des moteurs diffèrent de QIDISlicer 1.2.5 (PrusaSlicer 2.9.6 / OrcaSlicer
  récent vs fork QIDI plus ancien) : les recettes de `deps/` ne sont pas transposables ligne à ligne,
  seule la **classe** de correctifs l'est.
- `slicepad` est très récent (créé 2026-08-06) et à 0 étoile : la qualité de ses gates n'a pas été
  auditée ici, et son absence de licence est un problème pour tout usage dérivé.
