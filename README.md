# QSlicerPad — le moteur de QIDISlicer sur iPadOS

Portage **non officiel** du moteur de slicing de [QIDISlicer](https://github.com/QIDITECH/QIDISlicer)
(lui-même dérivé de PrusaSlicer, AGPL-3.0) vers **arm64-iOS**, avec une interface SwiftUI et une
distribution en `.ipa` non signée (SideStore).

Objectif : slicer **sur l'iPad**, hors ligne, avec le même moteur que le bureau — donc le même G-code —
sans serveur et sans sous-processus (interdits par iOS).

---

## État réel du projet

| Élément | État | Vérifié comment |
|---|---|---|
| Série de patches iOS sur les sources QIDISlicer 1.2.5 | **écrite et applicable** | `git apply --check` sur la révision épinglée (`scripts/lint.sh`) |
| Toolchain CMake iOS, scripts de build, gate de slicing | **écrits** | syntaxe shell + analyse CMake par harnais (`scripts/lint.sh`) |
| ABI C du moteur (`core/include/qidislice.h`) | **écrite** | analyse CMake OK ; **pas encore compilée** |
| App SwiftUI, XcodeGen, paquetage `.ipa` | **écrite** | **pas encore compilée** (nécessite Xcode) |
| CI macOS (dépendances → moteur → app → `.ipa`) | **écrite** | première exécution = le vrai test |
| Compilation réussie / G-code produit / app qui se lance | **à faire** | c'est ce que la CI va établir |

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
   Le build complet se déclenche **à la demande** :
   ```bash
   gh workflow run ios.yml -f full=true
   ```
   (ou définir la variable de dépôt `QSID_FULL_CI=true` pour que chaque push le lance).
3. Il enchaîne : gate hôte → dépendances iOS (mises en cache) → moteur arm64 → app →
   **`QSlicerPad-unsigned.ipa`** en artefact.
4. Télécharger l'artefact, puis installer avec **SideStore** : [`docs/sideloading.md`](docs/sideloading.md).

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

**Pas encore** : visualiseur 3D, installation du bundle de profils, envoi vers l'imprimante (Moonraker),
connexion cloud QIDI, import STEP/OCCT. Voir [`docs/roadmap.md`](docs/roadmap.md).

## Licence

**AGPL-3.0**, comme QIDISlicer dont ce projet dérive : toute distribution (y compris une `.ipa`
publiée ou déposée sur une source SideStore) doit fournir le code source correspondant. Le texte de
la licence est dans [`LICENSE`](LICENSE).
