# QIDISlicer → iPad mini 7 (iPadOS) : étude de faisabilité

Analyse par reverse engineering du binaire livré (REA).
Aucun code source utilisé : toutes les affirmations ci-dessous viennent de l'artefact publié.

> **Complément** : l'analyse des builds **macOS (`…MacOS_universal.dmg`) et Windows (`…Win64.zip`)**
> fait l'objet du document [`ANALYSE_MACOS_WINDOWS.md`](./ANALYSE_MACOS_WINDOWS.md) (mêmes outils REA +
> inspection directe des tranches Mach-O extraites). Elle confirme la portabilité du cœur sur
> `arm64-Apple` **au niveau du binaire** et nomme précisément les surfaces incompatibles avec iPadOS.
>
> **État de l'art** : [`PORTAGES_IOS_EXISTANTS.md`](./PORTAGES_IOS_EXISTANTS.md) recense les ports iOS
> déjà réalisés par la communauté (`bo0tzz/slicepad` — OrcaSlicer, `.ipa` non signée + SideStore ;
> `NilsN3DP/SlicerMobile` — PrusaSlicer 2.9.6, SwiftUI + OpenGL ES, TestFlight ; `adickin/PalmSlice`)
> et les recettes de cross-compilation associées. Conclusion : `libslic3r` **tourne déjà sur arm64-iOS**,
> mais uniquement en *headless* derrière une ABI C, avec une GUI réécrite (cf. §5.D).
>
> **Mise en œuvre** : le scénario D a été engagé dans ce dépôt — voir [`README.md`](./README.md)
> (toolchain iOS, série de patches, ABI C, app SwiftUI, CI macOS produisant une `.ipa` non signée).

## 1. Artefacts analysés (empreintes)

| Artefact | SHA-256 | Détail |
|---|---|---|
| `QIDISlicer_1.2.5_Ubuntu24.AppImage` | `4c78c03f4711ac6d7356753c9e7f2cf2e884b2c98e5326231368f8ba839b320f` | ELF 64-bit LSB pie, x86-64, static-pie, stripped (runtime AppImage) |
| `usr/bin/bin/qidi-slicer` (extrait) | `993bc0e3ab191efb1f11c43dc46030993e94132aaa52b20cacdb470930f5cf83` | ELF x86-64 PIE, 116 045 584 octets, non strippé |
| `usr/bin/bin/OCCTWrapper.so` | — | ELF x86-64 shared object, 41 689 376 octets (OpenCASCADE : import STEP) |

Opérations REA utilisées : `inspect_binary_layout` (indisponible, provider pwntools non configuré),
`open_binary` → document ELF x86-64 ouvert, `binary_overview` / `search_strings` / `read_bytes`
**indisponibles** faute de provider d'analyse profonde (`GHIDRA_INSTALL_DIR` non défini).
Le reste des preuves provient de l'inventaire de l'artefact extrait (strings, en-têtes ELF, arbre de fichiers).

## 2. Ce qu'est réellement QIDISlicer

**C'est un fork de Slic3r/PrusaSlicer** (63 930 occurrences de symboles `Slic3r::`), pas une application web.

- Interface : **wxWidgets 3.2 + GTK-3** (`wx-3.2/wx/checkbox.h`, `libgtk-3.so.0`, `libgdk-3.so.0`, `libpango*`)
- Rendu : **OpenGL desktop** (`libGL.so.1`) — pas de GLES/Metal
- Web embarqué : **WebKit2GTK-4.1 + libsoup-3.0 + JavaScriptCore** (pages locales `resources/web/*`, et **Fluidd**, l'UI web de Klipper)
- Bibliothèques de calcul liées statiquement : **Boost, CGAL, OpenVDB, TBB, GMP, MPFR, Qhull, Eigen/IGL, OpenEXR, admesh, OpenCASCADE (OCCT)**
- 24 dépendances `DT_NEEDED`, toutes Linux desktop ; l'AppImage embarque son propre jeu de libs dans `usr/bin/bin/`
- Machine de build visible dans les symboles : `/home/wjy/work/projects/release/QIDISlicer/deps/build/destdir/...`
- Aucun marqueur `arm64`, `aarch64`, `android`, `iOS` dans le binaire. Les seules occurrences de `iPhone`/`iOS` sont des chaînes **User-Agent** (webview).

## 3. Couches réseau présentes dans le binaire (très important)

### LAN — Klipper / Moonraker
```
machine/connect?password=%2%          machine/file/gcodes/%2%
printer/gcode/script                  printer/objects/query?print_stats=state&display_status=progress
server/files/upload                   server/files/config/officiall_filas_list.cfg
printer/objects/query?save_variables=variables     (données AMS / box_count / runout)
```
Types d'hôte d'impression exposés : `qidilink`, `qidiconnect`, `OctoPrint`, `moonraker2` (« Klipper via Moonraker »),
`flashair`, `astrobox`. Classes natives confirmées : `Slic3r::Moonraker`, `Slic3r::PrintHost`.

### Cloud — QIDI Connect
```
https://api.qidi3dprinter.com/qidi        https://api2.qidi3dprinter.com/qidi
https://connect.qidi3d.com                (broker QIDIConnect)
https://login_%1%.qidi3dprinter.com/#/account/login?lang=%2%&token=
OAuth2 + PKCE : client_id, code_challenge_method=S256, grant_type=authorization_code|refresh_token
Upload : %1%/app/users/teams/%2%/uploads , %1%/app/teams/%2%/files/raw?upload_id=%3%
Stockage : %1%/%2%/files?printer_uuid=%3%
```
Le tout est dialogué via **WebView (login) + HTTP(s) + boost::asio**, avec jeton OAuth stocké sur disque.

## 4. Chaîne de slicing pilotable en ligne de commande (confirmé)

Options CLI présentes dans le binaire :
`--slice|s`, `--export-gcode|gcode|g`, `--export-3mf`, `--export-stl`, `--export-obj`, `--export-sla`,
`--datadir`, `--load`, `--query-printer-models`, `--query-print-filament-profiles`,
`--gcodeviewer`, `--no-single-instance`.

→ **Le cœur de slicing est exécutable sans interface graphique.** C'est la brique qui rend possible
un iPad comme client léger.

### Distribution existante (relevé GitHub, release V1.2.5)
`QIDISlicer_1.2.5_Win64.zip`, `QIDISlicer_Setup_1.2.5_Win64.exe`,
**`QIDISlicer_1.2.5_MacOS_universal.dmg`**, `QIDISlicer_1.2.5_Ubuntu24.AppImage`.

→ **`MacOS_universal` = x86_64 + arm64-apple.** QIDI compile donc déjà tout l'arbre
libslic3r + CGAL/OpenVDB/TBB/Boost/GMP/MPFR/OCCT pour **arm64 Apple**. C'est la preuve
la plus forte que le cœur de calcul est portable sur Apple Silicon.

## 5. Verdict sur le scénario « sideloader QIDISlicer sur iPad »

**Impossible tel quel.** Barrières dures de iPadOS :

1. `qidi-slicer` est un **ELF x86-64 Linux** ; iPadOS (ARM64, XNU/Darwin) n'exécute pas de binaire Linux.
2. Pas de **FUSE** → une AppImage ne peut pas se monter.
3. Pas de `fork`/`exec` de binaires arbitraires (sandbox + pas d'entitlement), pas de JIT pour les apps non développeur.
4. Pas de portage ARM64 Linux de QIDISlicer (aucun build arm64 publié, aucun marqueur dans le binaire).
5. Construire une app iOS demande le **SDK Apple** (Xcode/macOS) : Linux seul ne suffit pas.

**Mais l'objectif « slicer sur iPad » est atteignable**, par 4 chemins, du moins coûteux au plus ambitieux.

### A. Aucun développement — iPad comme client web (aujourd'hui)
Les imprimantes QIDI récentes (Q2, Plus4, Max4, X-Plus4…) tournent sous **Klipper + Moonraker**.
Donc directement dans Safari sur l'iPad :
- **Fluidd** sur `http://<ip-imprimante>:4408` → monitoring, upload G-code, démarrage d'impression
- **Kiri:Moto** (`grid.space/kiri`) → slicer FFF **100 % navigateur (WASM)**, fonctionne sur iPad,
  avec connexion Moonraker/OctoPrint intégrée → slice puis envoi à l'imprimante

→ Workflow complet sur iPad mini 7, sans coder une ligne. Limite : Kiri:Moto n'utilise pas
les profils QIDI, il faut créer les profils à la main.

### B. Slicing côté serveur + client iPad (recommandé si tu veux « l'app »)
```
iPad (SwiftUI)  --(STL/3MF)-->  host Linux  --(qidi-slicer --export-gcode)-->  G-code
        |                                                                            |
        +------------------- Moonraker server/files/upload <-----------------------+ 
```
- Serveur : `qidi-slicer --datadir <profil> --load <cfg.ini> --export-gcode -o out.gcode model.stl`
- Client iPad : upload fichier, retour du G-code (+ aperçu), envoi via Moonraker, suivi de statut.
- Coût réel : un client réseau Swift, pas un portage. Sideloadable via AltStore/SideStore/Sideloadly.

### C. Streaming / bureau distant (trivial)
Garder QIDISlicer sur un PC/NAS et l'afficher sur l'iPad (Moonlight/Sunshine, RDP, VNC, Jump Desktop).
Fonctionne immédiatement ; nécessite une machine allumée.

### D. Vrai portage natif iPadOS du cœur libslic3r (le projet « pur »)
Faisable sur le principe, mais c'est un projet lourd :
- Le cœur de calcul compile déjà pour **arm64 Apple** (cf. DMG universal) → bon signe.
- À refaire : remplacer **wxWidgets/GTK par SwiftUI/UIKit**, remplacer **OpenGL desktop par Metal/GLES**
  (le plater est un `wxGLCanvas`), adapter Boost.Filesystem/TBB au sandbox, remplacer les WebView
  WebKit2GTK par `WKWebView`, et se passer de toute dépendance desktop.
- Volume de code : ordre de grandeur **plusieurs centaines de milliers de lignes** de C++ à intégrer.
- Estimation : **6 à 24 mois** pour un développeur expérimenté, avec un risque élevé d'abandon.
- Précédents : l'issue PrusaSlicer #8166 « iOS/iPadOS app » est ouverte **depuis 2022 et jamais réalisée** ;
  aucun portage iOS officiel n'existe pour PrusaSlicer, OrcaSlicer ni Bambu Studio.

## 6. Contraintes de sideload (iPad mini 7 / iPadOS)

| Voie | Coût | Durée signature | Limites |
|---|---|---|---|
| Compte Apple gratuit + AltStore / SideStore / Sideloadly | 0 € | 7 jours | 3 apps, resignature hebdo |
| Apple Developer Program | 99 $/an | 1 an | — |

**Prérequis bloquant depuis Linux** : compiler une .ipa exige le SDK iOS + Xcode.
Solutions sans Mac physique :
- **GitHub Actions runner `macos-*`** pour builder l'archive puis sideloader le `.ipa`
- une VM macOS, ou un Mac d'occasion
- (jailbreak uniquement) toolchain Theos cross-compilée

## 7. Recommandation

1. **Court terme (0 dev)** : Fluidd dans Safari + Kiri:Moto pour slicer → tu imprimes depuis l'iPad demain.
2. **Cible intermédiaire (faisable)** : app iPad SwiftUI de type « telemetry + upload + print »,
   s'appuyant sur `--export-gcode` côté serveur et Moonraker/QIDIConnect côté transport.
   C'est le meilleur rapport valeur/effort pour un vrai « app iPad » sideloadée.
3. **Long terme (à n'engager qu'avec beaucoup de temps)** : portage natif du cœur libslic3r.
   Ne pas commencer sans une preuve de concept limitée : faire tourner `libslic3r`
   en slicing pur (sans UI) dans un binaire arm64 iOS, piloté par un test unitaire.

## 8. Réserve méthodologique

`GHIDRA_INSTALL_DIR` n'étant pas configuré, l'analyse est **au niveau artefact et chaînes/symboles**,
pas au niveau fonction (pas de décompilation, pas de vérification dynamique). Les conclusions de
portabilité reposent sur les en-têtes ELF, les dépendances dynamiques, les symboles exportés et
les ressources embarquées : elles sont solides pour ce type de question.

**Réserve levée en partie** par [`ANALYSE_MACOS_WINDOWS.md`](./ANALYSE_MACOS_WINDOWS.md) : la tranche
`arm64` du binaire macOS a été extraite et inspectée (minos macOS 14 / SDK 14, 369 390 symboles non
strippés, dont 43 198 `Slic3r::*` et l'entrée `Slic3r::CLI::run`) : la compilation du cœur pour
`arm64-Apple` est donc **observée**, et non plus inférée. Elle reste une **inférence** pour
`arm64-iphoneos` (SDK iOS), et les limites d'exécution sur iPadOS (sous-processus, frameworks macOS,
gui wxWidgets/Cocoa, OpenGL desktop) y sont documentées précisément.

## 9. Mise à jour — apports de l'analyse macOS + Windows (résumé)

| Point | Apport |
|---|---|
| Cœur arm64 | **observé** : tranche `arm64` (minos macOS 14, SDK 14) contenant libslic3r, CGAL/TBB/OpenVDB/GMP/MPFR/OCCT et `Slic3r::CLI::run` |
| Point d'entrée non-GUI | `Slic3r::CLI::run(int,char**)` sur macOS/Linux, export **`slic3r_main`** côté Windows (les `.exe` sont des stubs chargeant `QIDISlicer.dll`) |
| Webview | macOS = **WKWebView** + pont `window.webkit.messageHandlers._qidiSlicer` (≈ transposable tel quel en `WKWebView`/`WKScriptMessageHandler` sur iPadOS) ; Windows = WebView2/Edge ; Linux = WebKit2GTK |
| Sous-processus | importés et utilisés côté macOS (`_fork`, `_execve`, `_popen`, `_system`, `_waitpid`, `wxExecute`) avec usage concret : `airport -I` pour scanner le Wi‑Fi, `hdiutil`, relance `--gcodeviewer` → **inutilisable sous iPadOS** |
| Frameworks macOS-only | `CoreWLAN`, `DiskArbitration`, `IOKit`, `Carbon`, `AppKit` liés en dur → pas d'équivalent iPhoneOS |
| Signature | Developer ID (Team `5J4Z7YXY79`), hardened runtime, **non sandboxé**, entitlements `com.apple.security.cs.*`/exceptions mach-iokit-home sans équivalent iOS |
| Rendu | OpenGL **desktop** (glad + GLEW + **GLU**, ImGui backend GL) ; GLU inexistant sous iOS (→ GLES/Metal) |
| Verdict | Porter le **cœur** devient le scénario crédible ; repackager le build macOS reste impossible. Étape 0 recommandée : POC « libslic3r en `arm64-iphoneos`, `CLI::run()` in-process » avant tout travail GUI |
