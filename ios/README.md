# App iPadOS (SwiftUI)

## Fichiers

| Fichier | Rôle |
|---|---|
| `project.yml` | spécification **XcodeGen** : le `.xcodeproj` n'est pas versionné, il se régénère |
| `QSlicerPad/QSlicerPadApp.swift` | point d'entrée |
| `QSlicerPad/Screens/HomeView.swift` | écran unique : modèle → profil → slicer → G-code |
| `QSlicerPad/Model/SlicerModel.swift` | état : import de fichiers, chemins du conteneur, exécution du slicing |
| `QSlicerPad/Core/QSlicerCore.swift` | enveloppe Swift de l'ABI C (`qsid_create` / `qsid_slice`) |
| `QSlicerPad/Core/QIDIProfiles.swift` | lecture du bundle vendor QIDI (liste des modèles d'imprimante) |
| `QSlicerPad/Support/QSlicerPad-Bridging-Header.h` | rend `qidislice.h` visible depuis Swift |
| `QSlicerPad/Resources/Info.plist` | types de fichiers, partage de fichiers, réseau local, orientations |
| `QSlicerPad/Resources/qidi/` | **généré** par `scripts/stage-resources.sh` (profils QIDI + config générique) |

## Construction

```bash
../scripts/stage-resources.sh                 # profils dans Resources/qidi/
../scripts/package-engine.sh                  # QSlicerEngine.a + include/
xcodegen generate
xcodebuild -project QSlicerPad.xcodeproj -scheme QSlicerPad \
  -configuration Release -sdk iphoneos \
  QSID_ENGINE_ARCHIVE=$PWD/../build/dist-ios \
  QSID_ENGINE_LINK_FLAGS="$(grep -v '^#' ../build/dist-ios/QSlicerEngine-link.txt | tr '\n' ' ')" \
  build
```

`project.yml` a besoin de deux réglages fournis par l'appelant :

- `QSID_ENGINE_ARCHIVE` : répertoire contenant `lib/QSlicerEngine.a` et `include/qidislice.h` ;
- `QSID_ENGINE_LINK_FLAGS` : bibliothèques/frameworks du SDK à réajouter à la ligne de liens
  (`-lexpat -liconv -lz`, `Foundation`, `ModelIO`, `Accelerate`, `IOKit`, …) — une archive statique ne
  transporte pas le code que le moteur résout dans le SDK.

## Le pont C

```swift
let core = try SlicerCore(resourcesDirectory: bundleResources, dataDirectory: containerData)
try core.slice(model: modelURL, config: profileURL, output: gcodeURL)
```

- `resourcesDirectory` : `Bundle.main.resourceURL/qidi` — **lecture seule**, c'est là que vivent les
  profils embarqués.
- `dataDirectory` : `Application Support/qidi-data` dans le conteneur — **inscriptible** ; le cœur y crée
  ses répertoires de presets.
- `qsid_slice()` est **bloquant et sans progression** (v1) : appelé sur une file d'arrière-plan, l'UIText
  affiche un indicateur indéterminé. Voir [`../docs/roadmap.md`](../docs/roadmap.md) pour la v2.
- L'app **ne lance aucun sous-processus** et n'ouvre aucune connexion réseau : c'est une contrainte iOS
  respectée par construction, pas une option.

## Limites assumées de la v1

- pas de visualiseur 3D (ni du modèle, ni du G-code) ;
- pas d'installation automatique du bundle de profils : il faut exporter un `.ini` depuis le bureau
  (la sélection d'imprimante ne sert qu'à se repérer) ;
- pas d'envoi à l'imprimante ;
- cible iOS 17 (le moteur, lui, est compilé pour iOS 15+).
