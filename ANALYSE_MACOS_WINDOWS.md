# QIDISlicer (builds macOS + Windows) → iPadOS : analyse de faisabilité

Étude complémentaire de [`FEASIBILITY.md`](./FEASIBILITY.md), qui portait sur l'AppImage Linux.
Ici : les deux artefacts livrés dans ce dépôt — `QIDISlicer_1.2.5_MacOS_universal.dmg` et
`QIDISlicer_1.2.5_Win64.zip`.

> **Suite** : les conclusions de ce document ont été mises en œuvre — voir [`README.md`](./README.md)
> (patches iOS sur les sources officielles, ABI C, app SwiftUI, CI macOS). Les blocages du §6.2 sont
> traités ou explicitement reportés dans [`docs/risks.md`](./docs/risks.md).

Outils REA (MCP) utilisés, **plus** une inspection directe des octets extraits.
La distinction est maintenue partout : *Evidence REA* ≠ *observation d'octets par mes propres scripts*.

---

## 1. Méthode, opérations REA, et limites rencontrées

| Opération REA | Cible | Résultat |
|---|---|---|
| `open_binary` | `QIDISlicer_1.2.5_MacOS_universal.dmg` | `format=dmg`, `kind=archive`, sha256 `d9820753…3bf7` |
| `inspect_artifact` | DMG | Evidence `ev_a8968dbe9ffd47b45a0045f5078ec8e7ab23b1fe4bd2b9fa1cebe292e867f0a9` — **1 nœud seulement** ; limite REA : *« DMG child inventory requires a native macOS adapter »* |
| `open_binary` / `inspect_artifact` | `QIDISlicer_1.2.5_Win64.zip` | `ev_16567243cd97f44e130c73ea40058c659de19ae67a39a6840129242489db1705` — 722 artefacts, 759 occurrences, 758 arêtes, **17 membres PE** |
| `extract_artifact` | ZIP Win64 | `ev_1b0c6d0d65ebe1bde0dbf0fb51475c5b400cd13c19e3ac67aa58bfd59e29a418` (manifeste d'extraction, 759 occurrences) |
| `open_binary` | `QIDISlicer.dll`, `QIDISlicer.exe`, `qidi-gcodeviewer.exe`, `OCCTWrapper.dll`, `WebView2Loader.dll` | tous `format=pe`, `architecture=x86_64`, avec sha256 |
| `inspect_pe_resources` | `QIDISlicer.dll` | `ev_0b7e4e28a4fb670498d0b3ecca9e3f950fc065b6c7b89a872f6ed88d01b37fea` (machine 34404 = `0x8664`, 3 répertoires de ressources) |
| `inspect_pe_resources` | `QIDISlicer.exe` | `ev_e93d3d253d0d0c15fd6ac28d5f17129ede8664569e41b173a04bf28870c09a74` (22 entrées, 9 ressources) |
| `inspect_pe_resources` | `qidi-gcodeviewer.exe` | `ev_741b5a537cdc80bac439d1fd83733d7a25aae965d586e3fd194b573271ec13bd` (22 entrées, 9 ressources) |
| `inspect_pe_resources` | `OCCTWrapper.dll` | `ev_33a0de82d8f0f1a42b9c68a2c469d506a3eb04777b4e592aebc39549e0b3449b` |
| `trace_dylib_resolution` | `QIDISlicer.app` (extrait) | `ev_2ddd834093868dffd63e694e0a00dafa5de7fd80adfefe2b9d4b7ca59f1def0d` — 2 racines (x86_64, arm64), 48 arêtes `LC_LOAD_DYLIB`, toutes hors cible |

**Capacités REA indisponibles sur cet hôte Linux** (`binary_session`) :

| Opération | Raison renvoyée |
|---|---|
| `inspect_macho`, `inspect_signature`, `inspect_plist`, `list_architectures`, `demangle_swift`, `inspect_native_dispatch_metadata`, `observe_native_calls`, `observe_native_ui`, `capture_native_ui_scenario` | `unsupported_host` : « Native macOS utilities require macOS » |
| `inspect_binary_layout` | `provider_unavailable` : `REA_PWNTOOLS_PYTHON` non défini |
| analyse native (décompilation) | aucun provider Ghidra/IDA configuré |

Conséquences assumées :

1. L'inventaire des enfants du DMG est impossible via REA ici (`ev_a8968dbe…`) ; le DMG a donc été
   **extrait hors REA** (7-Zip 23.01 récupéré via `apt-get download`, extrait sans root) — HFS+, 743 fichiers.
2. Toute analyse **au niveau chargeur/symbole/chaîne sur les tranches Mach-O** vient de mes propres
   scripts sur `Contents/MacOS/QIDISlicer` (sha256 `5639eab967f986af0dafabbb0ffa167367748ab4906418766f74c0eeb6061f98`,
   231 511 472 octets). Ce n'est **pas** de l'Evidence REA ; c'est de l'observation d'octets.
3. Il n'y a **pas** de décompilation : les affirmations « tel appel système est atteignable depuis
   telle fonctionnalité » restent des inférences (§6, §7).

---

## 2. Empreintes

| Artefact | SHA-256 / identité | Taille |
|---|---|---|
| `QIDISlicer_1.2.5_MacOS_universal.dmg` | `d982075306a63ffd27ef0d28e0e22e3ab8d3143ed09e38fb5cbd5f6050ab3bf7` (REA) | 174 684 165 |
| `QIDISlicer.app/Contents/MacOS/QIDISlicer` (universel) | `5639eab967f986af0dafabbb0ffa167367748ab4906418766f74c0eeb6061f98` (REA `trace_dylib_resolution`) | 231 511 472 |
| ├─ tranche `x86_64` (offset 16 384) | `789aa4024709952526cb421d72691d204e36f494c04cd53ef10d1eda22f75488` | 118 719 216 |
| └─ tranche `arm64` (offset 118 751 232) | `2343e57b5c78bfbdc03d368b87b719173515850adcb959b2744871acd844c061` | 112 760 240 |
| `QIDISlicer_1.2.5_Win64.zip` | `b95bd1a2811418d1baef886f919edf891043edd62077944eb5d89538973d76d5` (REA) | 249 724 534 |
| `QIDISlicer/QIDISlicer.dll` | `d30aff44507699e1d463ebddfd3e021c650a20251137ce1fc4cb635f089e1a0b` (REA) | 66 204 872 |
| `QIDISlicer/QIDISlicer.exe` | `f815a1cb6fcf5c10e71a1b730241df6cf4046ff1d3e0b71aa13cd8984e7caf5f` (REA) | 176 328 |
| `QIDISlicer/qidi-gcodeviewer.exe` | `38df4d117abc8265a82b447fd5542e022278ba440282092e1b26670670f36ff2` (REA) | 178 376 |
| `QIDISlicer/OCCTWrapper.dll` | `a8bf00a5ed83ed2e30709c5c730cba9894177e9d92be3aa359f56d385d4a4174` (REA) | 15 336 136 |
| `QIDISlicer/WebView2Loader.dll` | `0540c1f074cc585620366329ed94dab454a5b495e5ae6279e7fa57351175b410` (REA) | 141 512 |
| `QIDISlicer/mesa/opengl32.dll` | `ddc6a35e28…` (REA, inventaire ZIP) | 20 937 432 |
| `QIDISlicer/plugin/MicrosoftEdgeWebView2RuntimeInstallerX64.exe` | `2eaf8b40bb…` (REA, inventaire ZIP) | 115 254 560 |

---

## 3. Le build macOS : ce que montre le bundle

### 3.1 Structure

```
QIDISlicer.app/Contents/
├── Info.plist                     (4 510 o)
├── _CodeSignature/CodeResources
├── Frameworks/                    ← VIDE
├── MacOS/QIDISlicer               ← UN SEUL binaire universel de 231 Mo
└── Resources/                     (localisation .po/.mo, profils, ressources web)
```

`Frameworks/` vide + trace de résolution (`ev_2ddd8340…`, 48 arêtes, **toutes** `outside-target`) :
l'application ne dépend d'**aucun** dylib tiers embarqué. `rpath` présent uniquement :
`/Users/qidi/Desktop/QIDISlicer/deps/build/destdir/usr/local/lib` (chemin de la machine de build,
sans effet à l'exécution — les dylibs réellement chargés sont ceux du système).

### 3.2 Tranches et cibles de déploiement

| Tranche | `LC_BUILD_VERSION` | Symboles | Machine de build (rpath) |
|---|---|---|---|
| `arm64` | plateforme **macOS**, minos **14.0**, SDK **14.0** | 369 390 | `/Users/qidi/Desktop/QIDISlicer/…` |
| `x86_64` | plateforme **macOS**, minos **11.0**, SDK **11.1** | 288 502 | `/Users/qhl/Desktop/QIDISlicer-master/…` |

Le binaire est **non strippé** (noms de fichiers source inclus, ex.
`/Users/qidi/Desktop/QIDISlicer/src/slic3r/GUI/PrinterWebView.cpp`).

### 3.3 Signature et entitlements

| Élément | Valeur observée |
|---|---|
| CodeDirectory | `version=0x20500`, `flags=0x10000` (**CS_RUNTIME = hardened runtime**), `hash_size=32` (SHA-256), 27 312 pages de code |
| identifier | `com.qidi3d.slic3r/` (même identifiant mal formé que dans `Info.plist`) |
| Team ID | **`5J4Z7YXY79`** (équipe Apple Developer de QIDI) |
| Blobs | CodeDirectory `0xfade0c02`, *requirements* `0xfade0c01`, entitlements XML `0xfade7171`, entitlements DER `0xfade7172`, **signature CMS `0xfade0b01`** |
| `com.apple.security.app-sandbox` | **absent** → l'app n'est **pas** sandboxée sur macOS |

Entitlements demandés (XML, extrait du blob) :

```
com.apple.security.automation.apple-events                    = true
com.apple.security.cs.disable-executable-page-protection      = true
com.apple.security.cs.disable-library-validation              = true
com.apple.security.device.audio-input                         = true
com.apple.security.cs.allow-unsigned-executable-memory        = true
com.apple.security.temporary-exception.audio-unit-host        = true
com.apple.security.temporary-exception.mach-lookup.global-name= true
com.apple.security.temporary-exception.mach-register.global-name = true
com.apple.security.temporary-exception.files.home-relative-path.read-only  = true
com.apple.security.temporary-exception.files.home-relative-path.read-write = true
com.apple.security.temporary-exception.iokit-user-client-class= true
```

Lecture : modèle « app macOS classique signée Developer ID, durcie, **non sandboxée** ».
**Aucun de ces entitlements n'existe sous iPadOS** (voir §6.2).

### 3.4 Cœur embarqué (familles de symboles, tranche arm64)

| Famille | Symboles |
|---|---|
| `Slic3r::*` (cœur libslic3r) | 43 198 |
| `wx::*` (GUI) | 33 234 |
| OpenVDB | 16 690 |
| TBB | 11 673 |
| Boost | 8 536 |
| OpenCASCADE | 6 864 |
| CGAL | 4 130 |
| Eigen | 3 063 |
| GMP / MPFR | 1 857 / 94 |
| ImGui (GCodeViewer) | 1 219 |
| ClipperLib / Qhull / jsoncpp / admesh | 633 / 433 / 293 / présent |
| libcurl / OpenSSL | 81 / 24 |
| symboles ObjC (runtime/AppKit) | 907 |
| appels OpenGL (glad/GLEW) | 712 |

La chaîne de slicing est **présente et appelable en ligne de commande dans ce build macOS** :

- `Slic3r::CLI::run(int, char**)`, `Slic3r::CLI::setup(...)`, `Slic3r::CLI::print_help(...)` (122 symboles `Slic3r::CLI`)
- options : `export-gcode|gcode|g`, `datadir`, `query-printer-models`, `query-print-filament-profiles`,
  `--no-single-instance`, `--gcodeviewer`, `--load`
- GUI et CLI dans **le même exécutable** (20 878 symboles `Slic3r::GUI` + 122 `Slic3r::CLI`)

### 3.5 Interface, rendu, webview (surface plateforme)

| Couche | Preuve |
|---|---|
| GUI | wxWidgets **3.2** (`wx-3.2/wx/*.h` dans les chemins de debug), backend **wxOSX/wxCocoa** (260 + 210 symboles), `NSWindow`/`NSView`/`NSMenu`/`NSAlert`, `wxTheAppInitializer` |
| Rendu | `wxGLCanvas` (103) + `Slic3r::GUI::GLCanvas3D` + **OpenGL desktop** : loader `glad` (`_glad_glDrawArrays`, `_glad_glTexImage2D`…), `GLEW`, **GLU** (41) ; `OpenGL.framework` lié. **Aucun Metal** (les symboles « Metal » sont `Graphic3d_BSDF::CreateMetallic` d'OCCT) |
| Webview | `WebViewWebKit`, `WXWKWebView`, `WebViewUIDelegate`, `MyNavigationDelegate`, `webview_webkit.mm`, 18 symboles `WKWebView` → **WKWebView** via `wxWebView` ; pont JS `window.webkit.messageHandlers._qidiSlicer.postMessage` |
| Réseau cloud | `Slic3r::QIDIConnectNew` (169), `Slic3r::UserAccount`, `api(2).qidi3dprinter.com`, `connect.qidi3d.com`, OAuth2+PKCE (`code_challenge_method=S256`, `redirect_uri=…`, `login_%1%.qidi3dprinter.com`), `127.0.0.1`/`localhost` |
| Réseau LAN | `Slic3r::Moonraker` (209), `OctoPrint` (96), types d'hôte `qidilink, qidiconnect, octoprint, moonraker, moonraker2, duet, flashair, astrobox, mks` |
| Bibliothèques système liées | 24 `LC_LOAD_DYLIB` : Cocoa, AppKit, Carbon, CoreFoundation, CoreServices, CoreGraphics, CoreText, QuartzCore, ApplicationServices, ImageIO, Security, WebKit, **CoreWLAN**, **DiskArbitration**, **IOKit**, AudioToolbox, Foundation (+ CFNetwork sur la tranche x86_64), libc++/libobjc/libSystem/libiconv/libbz2/liblzma |

### 3.6 Interfaces système « à problème » pour iPadOS, observées

Symboles **importés** (non définis) dans la tranche arm64 :

```
_execve  _execvp  _fork  _popen  _system  _waitpid
_dlopen  _dlsym  _dlclose
_socket _bind _connect _listen _select _poll _sendto _recvfrom
__NSGetExecutablePath  _sysctl  _mkdtemp  _chdir  _putenv  _setenv
_LSOpenCFURLRef  _objc_msgSend  _pthread_create
```

Chaînes associées qui donnent le **contexte d'usage** :

| Chaîne | Interprétation |
|---|---|
| `/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I` + `Error executing airport command.` | l'app **exécute le binaire privé `airport`** pour lire le SSID Wi‑Fi |
| `-[WifiScannerMac wifiInterface]`, `Failed to scan wireless networks. Please fill SSID manually.`, `No password in the keychain for given SSID.`, `On some versions of MacOS, this only loads SSID of connected network.` | assistant de configuration Wi‑Fi côté GUI |
| `execve failed`, `fork() failed`, `waitpid(%d)`, `unexpected waitpid() return value` | machine `fork`/`exec`/`waitpid` (cohérent avec `wxExecute`/`wxShell` de wxWidgets) |
| `hdiutil` | montage de DMG (mise à jour / ouverture) |
| `--gcodeviewer` | relance de l'app en mode visionneuse (processus séparé sous Linux/Windows) |
| `wxExecute` (60), `wxProcess` (41), `wxShell` | API de lancement de processus de wxWidgets |

Inversement, **rien** de Linux/GTK/Mesa/WebView2 dans le build macOS, et **aucun** marqueur
`UIKit`, `iPhoneOS`, `apple-mobile`, `iOS` autre que des *User-Agent* web
(`Mozilla/5.0 (iPhone; … Mobile/15E148 Safari/604.1`).

---

## 4. Le build Windows : ce que montre le paquet

### 4.1 Inventaire REA (`ev_16567243…` : 722 artefacts, 759 occurrences, 758 arêtes)

17 membres PE x86_64, dont la répartition est **structurellement instructive** :

| Fichier | Taille | Rôle déduit |
|---|---|---|
| `QIDISlicer.dll` | 66,2 Mo | **tout le cœur + GUI** (libslic3r, wxWidgets, CGAL, TBB, ImGui, GCodeViewer) |
| `QIDISlicer.exe` | 176 Ko | **lanceur mince** : `LoadLibrary("QIDISlicer.dll")` + export **`slic3r_main`** |
| `qidi-gcodeviewer.exe` | 178 Ko | **lanceur mince** du même DLL, en mode visionneuse (`qidi-gcodeviewer.exe` dans ses chaînes) |
| `OCCTWrapper.dll` | 15,3 Mo | OCCT/STEP en **module séparé**, chargé dynamiquement (`Cannot load OCCTWrapper.dll`) |
| `WebView2Loader.dll` | 141 Ko | chargeur WebView2 (Chromium/Edge) |
| `plugin/MicrosoftEdgeWebView2RuntimeInstallerX64.exe` | 115,3 Mo | runtime Edge WebView2 **livré dans le paquet** |
| `mesa/opengl32.dll` | 20,9 Mo | **Mesa/llvmpipe** : OpenGL logiciel de secours |
| `libgmp-10.dll`, `libmpfr-4.dll` | 557 Ko / 450 Ko | GMP/MPFR **dynamiques** (statiques sur Linux/macOS) |
| `msvcp140*.dll`, `vcruntime140*.dll`, `api-ms-win-crt-*`, `plugin/vcredist2019_x64.exe` | — | chaîne **MSVC/UCRT** |
| `resources/stl_thumb/STLThumbWinShellExtension.dll`, `stl-thumb.exe` | — | extension Explorateur (spécifique Windows) |

Chaînes de build visibles : `D:\work\Projects\release\QIDISlicer\build\src\Release\qidi-s…`
(à comparer à `/home/wjy/work/projects/release/QIDISlicer` du build Linux → même arborescence produit).

### 4.2 Modèle d'exécution (preuves fortes)

Chaînes des lanceurs : `QIDISlicer.dll was not loaded`, `could not locate the function slic3r_main in QIDISlicer.dll`,
`Failed loading the system opengl32.dll` → les `.exe` sont des **stubs** qui chargent le DLL puis appellent
`slic3r_main`. Autrement dit, **le code est déjà séparé en « cœur exportable » + « coquille plateforme »**,
avec un point d'entrée unique (`slic3r_main`) qui sert GUI **et** visionneuse G-code.

### 4.3 Cœur partagé avec macOS/Linux (mêmes constantes métier)

Dans `QIDISlicer.dll` : `query-printer-models`, `query-print-filament-profiles`, `datadir`,
`export-gcode`, `export_sla`, `qidiconnect / octoprint / moonraker / moonraker2 / duet / flashair / astrobox / mks / qidiconnectnew`,
`QIDILink`, `QIDIConnect`, `Klipper (via QIDI)`, `Klipper (via Moonraker)`,
`https://api.qidi3dprinter.com/qidi`, `https://api2.qidi3dprinter.com/qidi`,
`Moonraker` (39), `libcurl` (9), `CGAL` (1 795), `TBB` (275), `ImGui` (154), `GLEW`, `glDrawArrays`,
`OpenGL 3`/`GL version`/`Core`/`Compatibility` (diagnostic d'installation OpenGL), `mesa`.
Webview : `WebView2` (185), `wxWebViewEdge` (28), `ICoreWebView2_10 is null`,
`WebView: Cannot register authentication request handler` — **WKWebView = 0**.

Chaîne de dépendances importées du DLL : `OPENGL32.dll`, `WS2_32.dll`, `CRYPT32/bcrypt`, `SETUPAPI`,
`UxTheme/COMCTL32/OLEACC/OLE32/OLEAUT32/COMDLG32`, `SHLWAPI`, `libmpfr-4`, `libgmp-10`, CRT MSVC.

---

## 5. Comparaison des trois builds

| Axe | Linux (AppImage, cf. `FEASIBILITY.md`) | macOS (DMG) | Windows (ZIP) |
|---|---|---|---|
| Cœur | libslic3r + Slic3r::CLI | **idem** | **idem** |
| GUI | wxWidgets 3.2 + **GTK‑3** | wxWidgets 3.2 + **Cocoa** | wxWidgets 3.2 + **MSW** |
| Rendu | OpenGL desktop (`libGL`) + Mesa probable | **OpenGL desktop** (glad/GLEW/GLU), OpenGL.framework | OpenGL desktop + **Mesa llvmpipe fourni** |
| Webview | WebKit2GTK 4.1 | **WKWebView** (`WXWKWebView`) | **WebView2/Edge** (+ runtime livré) |
| OCCT | `OCCTWrapper.so` (module) | **lié statiquement** | `OCCTWrapper.dll` (module) |
| GMP/MPFR | statiques | statiques | **DLL** |
| Sortie | AppImage (FUSE) | **app universelle x86_64+arm64** | DLL + 2 lanceurs |
| Lignage | fork Slic3r/PrusaSlicer | idem | idem |

**Conclusion structurelle** : un seul codebase, trois coquilles plateforme. La partie portable
(cœur de slicing, réseau, profils, formats) est celle que le portage iPadOS devrait réutiliser ;
la partie à refaire est la coquille — mais pour iPadOS, **il n'existe aucune coquille wxWidgets**
(cf. §6.2).

---

## 6. Ce que ces builds changent pour un portage iPadOS

### 6.1 Acquis (ce qui passe d'inférence à observation)

1. **Le cœur compile et linke pour arm64-Apple** : la tranche `arm64` existe, elle contient
   `Slic3r::*` (43 198), CGAL/OpenVDB/TBB/Boost/GMP/MPFR/OCCT/Eigen/Clipper/Qhull, **et** l'entrée
   CLI (`Slic3r::CLI::run`). L'hypothèse la plus forte de `FEASIBILITY.md` (§4, §8) est donc **confirmée
   au niveau du binaire** — pas prouvée pour `arm64-iphoneos` (SDK différent), mais plus crédible.
2. **Il existe déjà un point d'entrée unique non-GUI** : export `slic3r_main` côté Windows,
   `Slic3r::CLI::run(int, char**)` côté macOS/Linux. Un port « slicing in-process » n'a pas besoin de
   refactoriser le cœur pour avoir un point d'appel.
3. **La couche web de connexion est déjà, sur macOS, du WKWebView + pont `postMessage`**
   (`window.webkit.messageHandlers._qidiSlicer`). C'est exactement l'API disponible sous iPadOS
   (`WKWebView` + `WKScriptMessageHandler`) : cette brique est **réutilisable presque telle quelle**
   dans une app iOS, alors qu'elle est WebView2/WebKit2GTK ailleurs.
4. **La couche réseau est compatible sandbox** : sockets, boost::asio, libcurl/OpenSSL statiques,
   HTTP(S) vers Moonraker/QIDIConnect. Rien n'exige de privilège hors du conteneur applicatif.
5. **Les frontières modulaires existent déjà** : `slic3r_main` (dll/exe) et `OCCTWrapper` (.so/.dll)
   montrent que le projet sait isoler le cœur. Un port iOS peut reprendre cette découpe
   (libslic3r statique + coquille SwiftUI).

### 6.2 Blocages nommés (avec la preuve correspondante)

| # | Blocage iPadOS | Preuve dans les builds |
|---|---|---|
| 1 | **Pas de sous-processus** (`fork`/`execve`/`system`/`popen` inutilisables ; sandbox iOS) | symboles importés `_fork`, `_execve`, `_execvp`, `_popen`, `_system`, `_waitpid` + chaînes `fork() failed`, `execve failed`, `waitpid(%d)`, mécanique `wxExecute`/`wxProcess` |
| 2 | **Scan Wi‑Fi par binaire privé** impossible | `/System/Library/PrivateFrameworks/Apple80211.framework/…/airport -I` + `WifiScannerMac` + `Failed to scan wireless networks…` |
| 3 | **Frameworks macOS sans équivalent iPhoneOS** | `CoreWLAN`, `DiskArbitration`, `IOKit` (classes user-client), `Carbon`, `AppKit`, `ApplicationServices` liés en dur |
| 4 | **Pas de wxWidgets sous iOS** (aucun backend iOS en amont) | GUI = 33 234 symboles `wx::*` + 260 `wxOSX` + 210 `wxCocoa` ; `wxGLCanvas` pour le plateau |
| 5 | **OpenGL desktop + GLU** alors qu'iPadOS = OpenGL ES (déprécié) ou Metal | `OpenGL.framework`, loader glad, `GLEW`, `GLU` (41), ImGui backend GL ; GLU n'existe pas sous iOS |
| 6 | **Entitlements mac sans équivalent iOS** (runtime durci, mémoire exécutable non signée, exceptions mach/iokit/home) | XML d'entitlements du blob `0xfade7171` (§3.3), `flags=0x10000` (CS_RUNTIME) |
| 7 | **Bundle en lecture seule + conteneur** (pas de `~/Library`, pas de `hdiutil`, pas d'écriture dans le `.app`) | `hdiutil`, `wxStandardPaths::GetResourcesDir`, `resources_dir`/`set_resources_dir`, absence de `Contents/Resources` codé en dur |
| 8 | **Signature/déploiement** : produire un `.ipa` exige SDK iOS + Xcode ; sideload 7 j (compte gratuit) ou 99 $/an | Team Apple existant (`5J4Z7YXY79`) → QIDI *peut* signer ; le build macOS prouve l'outillage Apple, pas l'outillage iOS |
| 9 | **Libs scientifiques sans support iOS officiel** (TBB, CGAL, OpenVDB, GMP/MPFR) à valider sur `arm64-iphoneos` | présentes dans les 3 builds ; leur portabilité iOS n'est **pas** établie par ces artefacts (inconnue) |
| 10 | **Ressources/thermique** : slab de 112 Mo de code + calcul CGAL/OpenVDB sur iPad mini | taille du binaire et familles de symboles ; limite mémoire/thermique non mesurée (inconnue) |

### 6.2 bis Confirmation externe : les ports iOS existants

Le document [`PORTAGES_IOS_EXISTANTS.md`](./PORTAGES_IOS_EXISTANTS.md) recense les ports déjà publiés sur
GitHub. Ils confirment point par point les blocages §6.2 : tous partent de `libslic3r` **sans la GUI**
(l'ADR E-01 de SlicerMobile : `src/libslic3r` = 190k LOC sans include wxWidgets, `src/slic3r` = 166k LOC
« completely bound to wxWidgets », `wxOSX/iPhone` = stub), remplacent OpenGL desktop + GLU par un
viewport **OpenGL ES** (`CAEAGLLayer`) ou SceneKit, exposent le cœur par une **ABI C appelée
in-process** (donc sans `fork`/`exec`), et se distribuent en `.ipa` non signée via SideStore ou en
TestFlight. Les recettes de cross-compilation des dépendances (GMP `--disable-assembly`, triples
autoconf, `CMAKE_MACOSX_BUNDLE=OFF`, sysroot OpenSSL, `CMAKE_FIND_ROOT_PATH`, JPEG oublié par le
superbuild) y sont documentées : elles s'appliquent aussi à l'arbre PrusaSlicer de QIDISlicer.

### 6.3 Verdict actualisé

- **« Repackager le build macOS sur iPad » : impossible** — même raison que pour l'AppImage
  (binaire Mach-O macOS, frameworks macOS, sandbox, signature) ; s'y ajoutent les sous-processus
  (§6.2 #1, #2) que le build macOS **utilise effectivement**.
- **« Porter le cœur de slicing sur iPadOS » : devient le scénario le plus crédible** — le cœur
  compile pour arm64-Apple et possède un point d'entrée CLI non-GUI. Le chantier n'est plus
  « est-ce que ça compile ? » mais « quelles fonctions du cœur appellent `fork/exec` ? ».
- **Ce qui reste à réécrire dans tous les cas** : GUI (wxWidgets→UIKit/SwiftUI), rendu (GL desktop→GLES/Metal),
  helpers système (Wi‑Fi, montage DMG, ouverture de dossiers, relance `--gcodeviewer` en process),
  chemins de données (`wxStandardPaths`→conteneur app), webview (WKWebView : la partie déjà écrite
  pour macOS est la meilleure base).
- **Recommandation** (elle prolonge `FEASIBILITY.md` §7) :
  1. Court terme : Fluidd + Kiri:Moto dans Safari (inchangé).
  2. Cible intermédiaire : client SwiftUI + slicing côté serveur (inchangé) — d'autant plus justifié
     que le slicing serveur peut tourner sur **le binaire macOS arm64 existant** (`Slic3r::CLI::run`,
     option `export-gcode`).
  3. **Nouvelle étape 0, recommandée avant tout travail GUI** : POC « libslic3r in-process sur iOS » —
     compiler libslic3r en `arm64-iphoneos` (statique), appeler `Slic3r::CLI::run()` avec `export-gcode`
     depuis une app de test, et vérifier que **le chemin de slicing n'a besoin ni de `fork`/`exec` ni de
     `dlopen`**. C'est l'expérience décisive, de faible ampleur, que ces artefacts rendent légitime.

---

## 7. Prochaines probes REA (pour trancher, non réalisables sur cet hôte Linux)

| Question ouverte | Opération REA | Où / prérequis |
|---|---|---|
| Quels sites d'appel utilisent `fork/execve/popen/system` (GUI seul, ou aussi le slicing) ? | analyse native + `procedure_callers`, `xrefs`, `trace_native_values` sur la tranche arm64 | provider Ghidra ou IDA (`GHIDRA_INSTALL_DIR`) |
| Les tranches/entitlements/signature exacts vus par les outils Apple | `inspect_macho`, `inspect_signature`, `list_architectures`, `inspect_plist`, `inspect_asset_catalog` | hôte macOS (ou runner `macos-*` GitHub Actions) |
| Inventaire complet du DMG par REA (au lieu de mon extraction 7-Zip) | `inspect_artifact` sur le DMG | hôte macOS (montage lecture seule) |
| Le chemin `resources_dir`/écriture de profils est-il dans le bundle ou dans le conteneur ? | analyse native de `Slic3r::resources_dir`, `AppConfig::load` | provider natif |
| `Deep:` comparaison de comportement entre builds (1.2.5 macOS vs Windows vs Linux) | `compare_artifacts` / `compare_bundles` / `find_changed_behavior` | après inventaires complets ; ici `compare_artifacts` n'a de sens qu'entre inventaires ZIP/app |

---

## 8. Réserves méthodologiques

1. **Deux niveaux de preuve** dans ce document : *Evidence REA* (identifiants `ev_…` cités §1) et
   **observations d'octets produites par mes scripts** sur le DMG extrait hors REA et sur le ZIP
   extrait par REA. Les secondes ne sont pas des Evidence REA ; elles sont reproductibles à partir des
   sha256 de §2.
2. **Aucune décompilation, aucune exécution** : les appels système sont observés au niveau
   *import* (table de symboles/section d'import) et *chaînes* ; l'affirmation « la fonctionnalité X
   appelle `fork` » est une **inférence** fondée sur la cohérence chaîne↔import (ex. `airport -I`
   ↔ `wxExecute`/`_system`/`_popen`), pas une observation dynamique.
3. Les symboles « Metal », « GLES », « EGL » trouvés sont des **faux positifs** d'OCCT/GLEW
   (ex. `Graphic3d_BSDF::CreateMetallic`, tables GLEW) : **aucun** backend Metal n'est présent.
4. `trace_dylib_resolution` renvoie `resolution.status = undetermined` pour les 48 arêtes : les cibles
   dyld sont hors de la racine analysée (limite documentée de l'opération). L'observation utile —
   **aucune dépendance embarquée dans le bundle** — reste valide (dossier `Frameworks/` vide,
   aucune arête `inside-target`).
5. La conclusion « le cœur compilerait pour `arm64-iphoneos` » reste une **inférence appuyée** :
   observé pour `arm64-apple-macos14` (SDK 14), non observé pour le SDK iOS. Les libs
   TBB/CGAL/OpenVDB/GMP/MPFR n'ont pas de support iOS officiel avéré.
