# Installer sur l'iPad (SideStore, gratuit)

La CI produit `QSlicerPad-unsigned.ipa` : une archive **non signée**. Elle s'installe via un outil qui
re-signe localement avec votre identifiant Apple gratuit.

## Pourquoi non signée

- Un compte Apple **gratuit** ne permet pas de distribuer par TestFlight (réservé au programme
  développeur à 99 $/an). En revanche il autorise la signature locale de son propre appareil.
- L'alternative pour un build signé et durable est le programme développeur → voir la fin de cette page.

## Limites à connaître avant de commencer

| Contrainte | Valeur (compte gratuit) |
|---|---|
| Durée de validité du certificat | **7 jours** → re-signature hebdomadaire |
| Applications actives simultanées | **3** (dont l'app de gestion elle-même) |
| Compte | identifiant Apple, double authentification |
| Données de l'app à la re-signature | conservées si la re-signature se fait par-dessus |

C'est la réalité de tout portage iOS non officiel, y compris `slicepad` et `SlicerMobile`
(voir [`../PORTAGES_IOS_EXISTANTS.md`](../PORTAGES_IOS_EXISTANTS.md)) — le second se distribue par
TestFlight, donc avec un compte payant.

## SideStore

1. Installer SideStore une fois (nécessite un ordinateur pour générer un *pairing file* de l'appareil,
   ou une source déjà configurée). La procédure officielle change de temps en temps : suivre
   <https://sidestore.io> plutôt que des copies de tutoriels.
2. Récupérer `QSlicerPad-unsigned.ipa` depuis les artefacts du workflow GitHub (onglet **Actions** du
   dépôt → dernière exécution → *Artifacts*).
3. Transférer le `.ipa` sur l'appareil (AirDrop, Fichiers, ou « Open in SideStore ») et l'installer :
   SideStore le re-signe avec votre certificat gratuit.
4. Si le projet est publié sur un dépôt public, on peut aussi ajouter une **source SideStore**
   (fichier JSON décrivant l'app et l'URL de l'IPA) — c'est ce que fait `slicepad` avec son
   `sidestore.json`. À ajouter au dépôt quand la première IPA sera vérifiée.

## Alternatives

| Outil | Principe | Remarque |
|---|---|---|
| **AltStore** | AltServer tourne sur un ordinateur (Windows/macOS), pousse la re-signature | nécessite un ordinateur joignable |
| **Sideloadly** | outil de bureau, signature + installation | plus manuel, pas de re-signature automatique |
| **TestFlight** | builds signés, 1 an, 10 000 testeurs | nécessite le programme développeur (99 $/an) |

## « Ouvrir avec » et types de fichiers

L'app déclare les modèles 3D et les profils dans son `Info.plist` : un `.stl`, `.3mf`, `.obj` ou un
`.ini` exporté de QIDISlicer desktop peut donc être ouvert **depuis Fichiers / AirDrop / le partage**.
Le G-code produit est écrit dans `Documents/Exports` — visible dans Fichiers car l'app active le
partage de fichiers, et partageable par AirDrop.

## Vérifier ce qu'on installe

Pour contrôler une IPA avant de l'installer :

```bash
unzip -o QSlicerPad-unsigned.ipa -d /tmp/qsid-ipa
lipo -archs /tmp/qsid-ipa/Payload/QSlicerPad.app/QSlicerPad     # attendu : arm64
vtool -show-build /tmp/qsid-ipa/Payload/QSlicerPad.app/QSlicerPad | grep -i platform
ls /tmp/qsid-ipa/Payload/QSlicerPad.app/Resources/qidi/profiles # profils QIDI embarqués
```
