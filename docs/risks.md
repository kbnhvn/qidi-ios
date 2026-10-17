# Risques et inconnues

Ce projet est un portage : la liste ci-dessous est celle des choses qui peuvent échouer, classées par
degré de confiance. Elle est tenue à jour à mesure que la CI répond.

## Ce qui est établi

| Fait | Preuve |
|---|---|
| L'arbre QIDISlicer compile pour **arm64-Apple** | tranche arm64 du binaire macOS livré ([`../ANALYSE_MACOS_WINDOWS.md`](../ANALYSE_MACOS_WINDOWS.md)) |
| Le moteur fonctionne **sans GUI** | option amont `SLIC3R_GUI=OFF` ; `src/CMakeLists.txt` isole la GUI |
| `Slic3r::CLI::run()` est appelable en ligne de commande | symbole présent dans le binaire macOS, appelé par `main()` |
| iOS interdit les sous-processus et le chargement dynamique | `fork`/`execve`/`popen`/`dlopen` importés par le build macOS, mais **jamais utilisés par notre ABI** ; confirmé par le README de `PalmSlice` |
| Des portages iOS de cette base existent | `slicepad` (`.ipa` publiée), `SlicerMobile` (TestFlight) |

## Risques techniques (par ordre décroissant de probabilité)

| # | Risque | Signal / preuve actuelle | Mitigation |
|---|---|---|---|
| 1 | **D'autres patches nécessaires** : la série actuelle (4 patches) vient de la *classe* de bugs documentée par d'autres portages, pas de notre propre journal de build | `docs/ios-cross-compile.md` de `slicepad` recense ~14 patches sur OrcaSlicer ; notre arbre est plus ancien | itérer : chaque échec est explicite (souvent autotools : lire `config.log` en entier) ; garder les patches petits et commentés |
| 2 | **TBB/OpenVDB/z3 sur iOS** : support non officiel | dépendances présentes ; `libseqarrange` **exige** z3 (`find_package(Z3 REQUIRED)`) | la CI dira ; sinon exclusion ciblée (arrange → v2) en isolant la dépendance |
| 3 | **GMP sans assembleur** (`--disable-assembly`) : l'arithmétique multi-précision passe en C | conséquence directe du patch 0003 | CGAL ne l'utilise que pour les prédicats exacts, pas le chemin chaud ; mesurer la gate |
| 4 | **Mémoire / thermique sur iPad** avec CGAL/OpenVDB | non mesuré ; la gate n'utilise qu'un cube de 20 mm | modèles réels à tester une fois l'app lancée ; la v1 slice de façon synchrone (pas de gros pipeline) |
| 5 | **OCCT (STEP) exclu** en v1 | `SLIC3R_ENABLE_FORMAT_STEP=OFF` | v2 : activer, puis patcher `deps/+OCCT` si nécessaire (comme `SlicerMobile`, qui l'embarque) |
| 6 | **CURL/OpenSSL exclu** en v1 : pas de cloud QIDI ni d'envoi réseau | ils ne sont référencés que par `src/slic3r` (GUI) | v2 : les réintégrer + patch OpenSSL iOS (la recette amont est en 1.1.0l, très ancienne) |
| 7 | **Pas de progression ni d'annulation** | choix de la v1 (appel CLI synchrone) | v2 : API objet libslic3r (`Print`, `GCodeGenerator`) + callback, et l'ABI C évolue (`qsid_slice_async`) |
| 8 | **Profils** : la v1 demande un `.ini` exporté du bureau | `--datadir` seul ne suffit pas : le bundle vendor doit être *installé* dans le conteneur (le wizard du desktop fait ce travail) | v2 : installer le bundle embarqué au premier lancement |
| 9 | **`data_dir` et écritures du cœur** : le cœur crée des répertoires (`vendor/`, `user/`, caches) | `PresetBundle::setup_directories()` écrit dans `data_dir` | `data_dir` est dans le conteneur de l'app (inscriptible) ; le dossier des ressources du bundle est en lecture seule et n'est que lu |
| 10 | **Signature/durée de vie** : compte gratuit = 7 jours | règle Apple | SideStore/AltStore ; ou programme développeur |
| 11 | **Le choix du flag `-DSLIC3R_STATIC=ON`** peut changer des détails de linkage | l'amont remappe des configs Qhull/OCCT selon ce flag | cohérent avec les builds livrés (tout statique) |

## Risques de méthode

- **Rien n'a été compilé dans l'environnement de rédaction** (Linux, sans SDK iOS). Tout ce qui est
  « écrit » dans ce dépôt a été relu et vérifié syntaxiquement (`scripts/lint.sh`), mais **le premier
  passage de la CI est la première compilation**. Les estimations de durée (1–2 h pour les dépendances)
  viennent des portages comparables, pas d'une mesure ici.
- Les patches sont **générés contre une révision épinglée** ; changer de révision amont les invalide
  (procédure dans [`building.md`](building.md)).
- Les affirmations des projets tiers (gates, impressions réussies) sont citées comme des affirmations
  de leurs auteurs, jamais comme des observations de ce dépôt.

## Risques juridiques

- QIDISlicer est sous **AGPL-3.0** (vérifié sur le dépôt amont). Cette application en dérive : **toute
  distribution doit fournir le source**. Un sideload strictement privé n'est pas une distribution.
- Le nom « QIDI » appartient à QIDI Technology : le projet est explicitement **non officiel** et ne doit
  pas être présenté comme tel. C'est ce que font les deux portages existants.
