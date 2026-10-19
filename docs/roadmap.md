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
- [x] ✅ **`scripts/gate.sh` vert sur macOS hôte** (run `39130857606`) — les **deux chemins** slicent le
  cube 20 mm : CLI v1 → 8 100 lignes / 6 757 mouvements / **100 couches** / 1 397,9 mm d'extrusion ;
  API objet v2 (chemin de l'app) → **exactement les mêmes chiffres**, et le G-code est **identique
  octet pour octet** (0 différence sur 8 100 lignes) ; objet **centré** (CENTER=110,110) ; progression
  observée de 10 % à 90 %

## v1 — « ça slice sur l'iPad »

- [ ] 🟡 l'app se lance sur l'iPad et slice un STL importé
  - ✅ le **chemin de slicing de l'app** (arrange → extruders → `Print::apply` → `process` →
    `export_gcode`) est validé à l'exécution sur macOS par la gate, avec un G-code **identique** à
    celui de la CLI ; il reste à l'exercer dans le bundle iOS
  - critère : G-code dans `Documents/Exports`, aperçu de couches visible
- [ ] 🟡 profil réel : profil QIDI embarqué ou `.ini` exporté du bureau
  - la résolution d'héritage du bundle vendor est **vérifiée localement** sur le vrai fichier
    (`Q2 0.4 nozzle` → 94 clés ; preset print → 188 ; filament → 89 ; fusion → 369 clés)
  - critère restant : comparer le G-code iPad ↔ bureau pour le même modèle + profil
- [ ] ⛔ **acceptation matérielle** : impression réussie sur une imprimante QIDI depuis l'app
  (nécessite l'iPad + l'imprimante)

## v1.1 — confort

- [x] ✅ profils embarqués exploitables : imprimante / réglages / filament lus dans
  `qidi/profiles/QIDITechnology.ini`, chaînes `inherits` résolues (séparateurs `,` **et** `;`),
  configuration `.ini` générée à la volée pour le moteur
- [x] ✅ écran de réglages : imprimante Moonraker (hôte/port/clé), profils par défaut, langue
- [x] ✅ icône d'app (1024², squircle + trois couches isométriques), écran de lancement
  (`UILaunchScreen`), mode sombre assuré par les couleurs système
- [x] ✅ **ergonomie tactile iPad** : disposition deux colonnes (NavigationSplitView)
  sur iPad / une colonne sur iPhone, actions principales pleine largeur (52 pt) et
  boutons ≥ 44 pt, glisser-déposer d'un modèle ou d'un profil, raccourcis clavier
  (⌘↩, Échap, ⌘O, ⌘,), retours haptiques, états vides explicites, écran maintenu
  éveillé et tâche d'arrière-plan pendant le slicing, contrôles de caméra et
  pas-à-pas de couche dans le visualiseur
- [x] ✅ **options de slicing** (`SliceOverrides`) : supports + seuil d'inclinaison,
  brim/raft, densité de remplissage, hauteur de couche, périmètres, décalage de
  température buse. Appliquées *par-dessus* le preset QIDI (elles ont la priorité),
  persistées, récapitulées sur l'écran principal, accessibles depuis la barre
  latérale et la barre d'outils (donc même barre latérale masquée). Le mapping .ini
  est verrouillé par `scripts/tests/slice_overrides.py` (exécuté dans le lint).
- [x] ✅ **visualiseur présenté en feuille** : « Terminé » toujours disponible (la vue
  poussée n'offrait aucun retour) et commandes de caméra sous la scène, en boutons
  légendés — les icônes posées en overlay sur la scène SceneKit ne recevaient pas
  les taps sur l'appareil
- [ ] 🔧 vérification **visuelle** en simulateur (job `ui-snapshot`, non bloquant) :
  le build simulateur bute sur une couche SDK du superbuild de deps
- [x] ✅ localisation FR/EN (dictionnaire `L10n`, sélecteur de langue ; les messages d'erreur
  techniques restent dans la langue du système)

## v1.2 — plateau, aperçu, réglages (voir `audit-ui-slicing.md`)

- [x] ✅ ABI v3 : session « scène », presets du moteur, réglages forcés validés, slicing incrémental,
  mouvements du G-code, vignettes fournies par l'hôte — **gate de scène verte** (178 vérifications) sur le
  vrai moteur et le vrai bundle QIDI (banc Linux ; la CI macOS l'exécute dans `host-gate`)
- [x] ✅ correctifs de l'audit : `ensure_on_bed` (cubes décalés en Z = G-code identique), annulation sûre,
  filament cohérent avec l'imprimante, options « valeurs forcées »
- [x] 🟡 plateau 3D (volume + socle QIDI), sélection, glisser, rotation, caméra, champs numériques, copies,
  organiser, poser sur une face, annuler/rétablir, clavier
- [x] 🟡 aperçu G-code en rubans, 7 modes de couleur, légende, double curseur, curseur de mouvements, lecture
- [x] 🟡 tous les réglages (306 options, Simple/Avancé/Expert, recherche, français), préréglages nommés, export `.ini`
- [x] ✅/🟡 calibration Pressure Advance (tour) et débit ; Moonraker en flux avec progression et état
- [x] ✅ réglages par objet, modificateurs (boîte / cylindre / sphère, bloqueurs et forceurs de supports), plages de
  hauteurs, coupe par plan, simplification de maillage, sélection multiple, menu contextuel : moteur et modèle
  exécutés (gate + test de bout en bout) · 🟡 vues
- [x] ✅/🟡 calibrations Pressure Advance ligne / motif et débit volumétrique maximal ; multi-filament (1–16 extrudeurs)
  et commandes QIDI Box ; découverte des imprimantes (balayage + Bonjour) ; préréglages qui héritent des presets
- [ ] ⛔ lecture automatique du contenu du QIDI Box (couleur, matière) : module réseau fermé du bureau, non porté ;
  numéros d'emplacement à confirmer sur le matériel
- [ ] 🟡 tout ce qui est 🟡 ci-dessus reste à **compiler (CI `ios-app`) et à passer en recette** sur iPad

## v2 — ce qui manque pour être « une app »

- [x] ✅ **progression et annulation** : l'ABI expose `qsid_slice_async` (API objet libslic3r :
  `Print::apply` → `process` → `export_gcode`), `qsid_cancel`, et un callback de progression
  (`PrintBase::SlicingStatus`). La progression est **observée** dans la gate (10→90 %) ;
  l'annulation est compilée mais non exercée (à tester sur device)
- [x] ✅ compilé, 🟡 non exercé — **visualiseur 3D + aperçu G-code** : SceneKit (Metal), sans portage OpenGL ES pour cette
  version. Modèle : STL lu directement, autres formats exportés en STL par le moteur
  (`qsid_export_stl`). G-code : analyse en *streaming*, segments par couche, curseur de couche
- [x] ✅ compilé, 🟡 non exercé — **envoi à l'imprimante** : client Moonraker en Swift (`URLSession`) —
  `server/files/upload` puis `printer/print/start`, plus `printer/objects/query` pour l'état.
  ATS configuré pour le réseau local (comme l'app macOS)
- [x] ✅ **robustesse mémoire** : statistiques et aperçu du G-code en streaming (jamais de fichier
  entier en mémoire), un seul slicing à la fois (`QSID_ERR_BUSY`), temporaires nettoyés

## v3 — parité

- [ ] ⛔ **import STEP (OCCT)** : le chemin est prévu (`SLIC3R_ENABLE_FORMAT_STEP` + recette OCCT à
  porter sur iOS, comme `SlicerMobile` le fait) ; **désactivé par défaut**, le stub
  `core/src/step_stub.cpp` renvoie une erreur explicite tant que ce n'est pas fait
- [x] ✅ **réseau sans CURL/OpenSSL** : les échanges (Moonraker, et la place pour QIDI Connect) sont
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
