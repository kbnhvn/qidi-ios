# Feuille de route

Chaque étape a un critère de sortie vérifiable. Règle : **rien ne passe à l'étape suivante sans
preuve**, et le slicing réel (une impression qui sort de l'imprimante) est le seul juge final.

Légende : ✅ fait et vérifié · 🟡 écrit, **pas encore validé** (CI/device) · ⛔ bloqué par une
dépendance externe.

## v0 — squelette

- [x] ✅ série de patches iOS sur les sources QIDISlicer 1.2.5 (applicable, rejouée par `scripts/lint.sh`)
- [x] ✅ toolchain CMake iOS, scripts de build, gate de slicing, paquetage `.ipa`
- [x] ✅ ABI C + app SwiftUI + CI macOS
- [x] ✅ **premier passage de la CI vert** — `ios-engine` + `ios-app` verts ; artefact
  `QSlicerPad-unsigned.ipa` produit (7,9 Mo) ; moteur de 136 Mo, app de 27 Mo (`arm64`,
  *platform IOS, minos 17.0*)
- [ ] 🟡 **`scripts/gate.sh` vert sur macOS hôte** — le job `host-gate` est écrit et prêt, mais les
  jobs Actions sont refusés pour facturation (*« recent account payments have failed or your spending
  limit needs to be increased »*). Le gate teste désormais **les deux chemins** (API objet v2 + CLI v1)

## v1 — « ça slice sur l'iPad »

- [ ] 🟡 l'app se lance sur l'iPad et slice un STL importé
  - code prêt ; critère : G-code dans `Documents/Exports`, aperçu de couches visible
- [ ] 🟡 profil réel : profil QIDI embarqué ou `.ini` exporté du bureau
  - la résolution d'héritage du bundle vendor est **vérifiée localement** sur le vrai fichier
    (`Q2 0.4 nozzle` → 94 clés ; preset print → 188 ; filament → 89 ; fusion → 369 clés)
  - critère restant : comparer le G-code iPad ↔ bureau pour le même modèle + profil
- [ ] ⛔ **acceptation matérielle** : impression réussie sur une imprimante QIDI depuis l'app
  (nécessite l'iPad + l'imprimante)

## v1.1 — confort

- [x] 🟡 profils embarqués exploitables : imprimante / réglages / filament lus dans
  `qidi/profiles/QIDITechnology.ini`, chaînes `inherits` résolues (séparateurs `,` **et** `;`),
  configuration `.ini` générée à la volée pour le moteur
- [x] 🟡 écran de réglages : imprimante Moonraker (hôte/port/clé), profils par défaut, langue
- [x] 🟡 icône d'app (1024², squircle + trois couches isométriques), écran de lancement
  (`UILaunchScreen`), mode sombre assuré par les couleurs système
- [x] 🟡 localisation FR/EN (dictionnaire `L10n`, sélecteur de langue ; les messages d'erreur
  techniques restent dans la langue du système)

## v2 — ce qui manque pour être « une app »

- [x] 🟡 **progression et annulation** : l'ABI expose `qsid_slice_async` (API objet libslic3r :
  `Print::apply` → `process` → `export_gcode`), `qsid_cancel`, et un callback de progression
  (`PrintBase::SlicingStatus`). L'app affiche une barre de progression et un bouton Annuler
- [x] 🟡 **visualiseur 3D + aperçu G-code** : SceneKit (Metal), sans portage OpenGL ES pour cette
  version. Modèle : STL lu directement, autres formats exportés en STL par le moteur
  (`qsid_export_stl`). G-code : analyse en *streaming*, segments par couche, curseur de couche
- [x] 🟡 **envoi à l'imprimante** : client Moonraker en Swift (`URLSession`) —
  `server/files/upload` puis `printer/print/start`, plus `printer/objects/query` pour l'état.
  ATS configuré pour le réseau local (comme l'app macOS)
- [x] 🟡 **robustesse mémoire** : statistiques et aperçu du G-code en streaming (jamais de fichier
  entier en mémoire), un seul slicing à la fois (`QSID_ERR_BUSY`), temporaires nettoyés

## v3 — parité

- [ ] ⛔ **import STEP (OCCT)** : le chemin est prévu (`SLIC3R_ENABLE_FORMAT_STEP` + recette OCCT à
  porter sur iOS, comme `SlicerMobile` le fait) ; **désactivé par défaut**, le stub
  `core/src/step_stub.cpp` renvoie une erreur explicite tant que ce n'est pas fait
- [x] 🟡 **réseau sans CURL/OpenSSL** : les échanges (Moonraker, et la place pour QIDI Connect) sont
  réécrits en Swift — c'est l'option retenue par la roadmap, elle évite de porter OpenSSL 1.1.0l
- [ ] ⛔ **connexion cloud QIDI** (`QIDIConnect`, OAuth2 + PKCE) : nécessite un travail dédié contre
  le service (redirecteurs, API privée). **Non implémenté** — volontairement, pour ne pas livrer du
  code qui *prétend* marcher contre un service non testé
- [ ] ⛔ **distribution TestFlight** : nécessite le programme développeur Apple (99 $/an) et des
  secrets de signature. Le workflow supporte déjà une `.ipa` non signée (SideStore)

## Non objectifs

- porter la GUI wxWidgets : impossible sur iOS (`wxOSX/iPhone` est un stub) et sans intérêt en tactile
- faire tourner le binaire macOS tel quel sur l'iPad : impossible (frameworks macOS, sous-processus,
  signature) — établi dans [`../ANALYSE_MACOS_WINDOWS.md`](../ANALYSE_MACOS_WINDOWS.md)
