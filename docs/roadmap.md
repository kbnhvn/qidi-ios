# Feuille de route

Chaque étape a un critère de sortie vérifiable. La règle : **rien ne passe à l'étape suivante sans
preuve**, et le slicing réel (une impression qui sort de l'imprimante) est le seul juge final.

## v0 — squelette (ce dépôt)

- [x] série de patches iOS sur les sources QIDISlicer 1.2.5 (applicable, vérifiée)
- [x] toolchain CMake iOS, scripts de build, gate de slicing, paquetage `.ipa`
- [x] ABI C + app SwiftUI + CI macOS
- [ ] **premier passage de la CI vert**
  - critère : artefact `QSlicerPad-unsigned.ipa` produit et `build/gate-out/cube_20mm.gcode` non vide
- [ ] **`scripts/gate.sh` vert sur macOS hôte**
  - critère : G-code avec ≥ 20 couches et une extrusion non nulle

## v1 — « ça slice sur l'iPad »

- [ ] l'app se lance sur l'iPad et slice un STL importé
  - critère : G-code présent dans `Documents/Exports`, ouvert dans un visualiseur, couches visibles
- [ ] profil réel : un `.ini` exporté de QIDISlicer desktop est accepté et donne un G-code équivalent
  - critère : comparer le G-code de l'iPad à celui du bureau pour le même modèle + profil
    (même démarche que les « gates » de `slicepad`) ; les différences attendues sont d'ordre
    flottant (extrusions à quelques % près)
- [ ] **acceptation matérielle** : impression réussie sur une imprimante QIDI depuis l'app

## v1.1 — confort

- [ ] installation du bundle vendor embarqué au premier lancement (au lieu d'importer un `.ini`)
  → l'app liste alors les profils QIDI (Q2, X-Plus 4, Q1 Pro, X-MAX 3, X-Plus 3, X-smart 3…) et les
  applique par nom
- [ ] écran de choix de profil (imprimante / filament / qualité) alimenté par le bundle
- [ ] icône d'app, écran d'accueil, mode sombre, localisation FR/EN

## v2 — ce qui manque pour être « une app »

- [ ] **visualiseur 3D** : l'amont contient déjà `SLIC3R_OPENGL_ES` et `libvgcode` (aperçu G-code).
  Réécrire `GLCanvas3D`/`GCodeViewer` côté Swift/Metal *ou* réutiliser le viewport C++ en OpenGL ES
  dans une `CAEAGLLayer` (voie choisie par `SlicerMobile`)
- [ ] **envoi à l'imprimante** : upload Moonraker (`server/files/upload` → `printer/gcode/script`)
  depuis Swift (`URLSession`), plus simple que de porter `boost::asio`/libcurl ; nécessite
  l'autorisation « réseau local » (déjà déclarée dans `Info.plist`)
- [ ] **progression et annulation** : remplacer l'appel CLI par l'API objet libslic3r
  (`Slic3r::Print`, `GCodeGenerator`) et faire évoluer l'ABI C
- [ ] arrêt/relance propre de gros slicings, gestion mémoire sur iPad mini

## v3 — parité

- [ ] **import STEP (OCCT)** : activer `SLIC3R_ENABLE_FORMAT_STEP=ON` et patcher `deps/+OCCT` si besoin
- [ ] **connexion cloud QIDI** (`QIDIConnect`, OAuth2 + PKCE) : `WKWebView` + pont JS — la partie
  navigateur existe déjà côté macOS dans le build livré, elle est transposable telle quelle
- [ ] réintégrer CURL/OpenSSL (avec patch OpenSSL iOS) ou réécrire les appels réseau en Swift
- [ ] distribution : programme développeur Apple → TestFlight, avantages durée (1 an) et confort

## Non objectif

- porter la GUI wxWidgets : impossible sur iOS (`wxOSX/iPhone` est un stub) et sans intérêt pour un
  usage tactile
- faire tourner le binaire macOS tel quel sur l'iPad : impossible (frameworks macOS, sous-processus,
  signature) — c'est établi dans [`../ANALYSE_MACOS_WINDOWS.md`](../ANALYSE_MACOS_WINDOWS.md)
