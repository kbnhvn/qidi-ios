# Recette sur iPad

À faire après avoir installé `QSlicerPad-unsigned.ipa` (voir `docs/sideloading.md`).
Chaque ligne se termine par **vu ✅ / cassé ✗** — c'est ce retour qui pilote la
correction suivante, il n'y a pas de Mac dans la boucle.

Version testée : `Réglages → À propos` (ou la ligne « Moteur » de l'écran
principal). Note-la ici : ..............................

## 1. Démarrage et disposition

- [ ] L'app s'ouvre sans écran blanc ni fermeture immédiate (pas de crash au lancement).
- [ ] En **paysage**, deux colonnes : profils à gauche, modèle/slicing à droite.
- [ ] En **portrait**, la colonne de gauche se replie ; le bouton « II » en haut à
      gauche la réaffiche.
- [ ] Le sélecteur **Imprimante / Réglages d'impression / Filament** propose les
      profils QIDI (X-Max 3, X-Plus 3, X-Smart 3…) — c'est la preuve que les
      profils embarqués sont bien lus.
- [ ] Basculer en **Split View** (autre app à côté) et redimensionner : la
      disposition suit, rien n'est coupé.

## 2. Import

- [ ] « Importer un modèle… » ouvre le sélecteur de Fichiers (STL, 3MF, OBJ, AMF).
- [ ] **Glisser-déposer** un STL depuis Fichiers (app en Split View) : le modèle
      apparaît sans passer par le bouton.
- [ ] Glisser un `.ini` exporté de QIDISlicer desktop sur l'app : le profil actif
      change (« Revenir aux profils embarqués » apparaît).

## 3. Visualiseur

- [ ] « Voir en 3D » ouvre une **feuille** avec un bouton « Terminé » bien visible.
- [ ] « Terminé » referme et rend l'écran principal (on ne reste pas coincé).
- [ ] **Un doigt** : orbite ; **pincement** : zoom ; **double-tap** : recadre.
- [ ] Les quatre boutons du bas (Recadrer / Dessus / Face / Isométrique) changent
      réellement la vue — c'est le point qui ne répondait pas.
- [ ] Pas-à-pas de couche (−/+) et curseur : l'aperçu G-code se dessine couche par
      couche, l'indice Z suit.

## 4. Options de slicing

- [ ] « Options de slicing… » s'ouvre depuis la barre latérale **et** depuis la
      barre d'outils du détail (utile si la barre latérale est masquée).
- [ ] Activer « Utiliser ces options » puis cocher **Supports** : le récapitulatif
      apparaît sur l'écran principal (« supports · remplissage 15 % »).
- [ ] Les réglages survivent à un redémarrage de l'app (ils sont mémorisés).

## 5. Slicing (le cœur)

- [ ] Un modèle importé + « Slicer » : la progression avance (pas figée à 0 %).
- [ ] L'écran ne s'éteint pas pendant le slicing.
- [ ] « Annuler » arrête vraiment et l'app reste utilisable.
- [ ] Le résultat affiche lignes / couches / taille / durée.
- [ ] « Aperçu G-code » : le modèle est centré sur le plateau (ses coordonnées
      doivent rester X=110, Y=110 mm).
- [ ] Mettre l'app en arrière-plan pendant un slicing : soit il continue (tâche
      d'arrière-plan), soit il est suspendu **sans** faire planter l'app au retour.
- [ ] « Partager / exporter le G-code » : le G-code part bien vers Fichiers ou une
      autre app.

## 6. Impression

- [ ] `Réglages` : adresse Moonraker + port enregistrés, bouton de test.
- [ ] « Actualiser l'état » renvoie l'état de l'imprimante (si elle est allumée).
- [ ] « Envoyer et lancer l'impression » envoie le G-code puis démarre le job.

## 7. Ce qu'il ne faut pas attendre

- STEP/OCCT, connexion QIDI Cloud, TestFlight : non implémentés (voir
  `docs/risks.md` et la feuille de route).

## Retour utile

Pour chaque ✗ : l'écran concerné, ce que tu fais, ce qui se passe (ou pas), et si
possible une capture. Une capture d'écran suffit à localiser la plupart des
problèmes de disposition.
