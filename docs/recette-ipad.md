# Recette sur iPad

À faire après avoir installé `QSlicerPad-unsigned.ipa` (voir `docs/sideloading.md`). Chaque ligne se
termine par **vu ✅ / cassé ✗** — ce retour pilote la correction suivante, il n'y a pas de Mac dans la boucle.

Version testée : `Réglages → À propos` (ligne « Moteur » de l'inspecteur). Note-la ici : ..............

> Ce que la recette doit surtout établir : **les vues SwiftUI/SceneKit n'ont jamais tourné** (le moteur,
> lui, est vérifié sous Linux par `scripts/linux-engine.sh gate`). Les lignes marquées ★ sont les plus
> susceptibles de casser.

## 1. Démarrage

- [ ] L'app s'ouvre sans écran blanc ni fermeture immédiate.
- [ ] ★ Après quelques secondes, le plateau 3D apparaît (surface grise, quadrillage, volume d'impression en
      fil de fer, socle sombre sous le plateau, repère rouge/vert à l'origine).
- [ ] L'inspecteur (à droite en paysage ; bouton « Réglages » en bas en portrait / Split View étroite) propose
      imprimante, réglages d'impression et filament ; **une buse 0,4 mm est présélectionnée**.
- [ ] Changer d'imprimante (ex. X-Plus 3 0.6) : le plateau change de taille ; le preset d'impression et le
      filament proposés correspondent à la buse (« … @X-Plus 3 0.6 nozzle »).
- [ ] Fermer et relancer l'app : imprimante, preset et filament sont retrouvés (B5).

## 2. Import

- [ ] « + » (ou ⌘O) ouvre Fichiers (STL, 3MF, OBJ, AMF) ; le modèle apparaît **posé sur le plateau**, sélectionné (vert).
- [ ] Importer un second modèle : il se place à côté, sans chevaucher le premier ni le déplacer.
- [ ] Glisser-déposer un STL depuis Fichiers (Split View) : même résultat. Un `.ini` exporté du bureau déposé
      sur l'app : « Profil importé » apparaît dans l'inspecteur.
- [ ] « Ouvrir dans QSlicerPad » depuis Fichiers importe le fichier (B9).
- [ ] Un STL en pouces (ex. un cube de 0,8) déclenche le bandeau « semble être en pouces » avec « Convertir ».

## 3. Plateau : gestes ★

- [ ] **Un doigt dans le vide** : la caméra tourne. **Deux doigts** : panoramique. **Pincement** : zoom.
      **Double toucher** : recadre sur le plateau.
- [ ] **Un doigt sur un objet** : il se déplace en suivant le doigt (pas de saut) ; relâché, il reste là.
- [ ] Pousser un objet hors du plateau : il devient **rouge** et une vibration signale la sortie ; le bandeau
      « Un objet sort du plateau » propose « Organiser ».
- [ ] **Rotation à deux doigts** sur l'objet sélectionné : il tourne autour de Z et s'aimante tous les 15°.
- [ ] Toucher un objet le sélectionne ; toucher le vide désélectionne.
- [ ] Les quatre boutons de vue (Recadrer / Dessus / Face / Isométrique) changent réellement la vue.
- [ ] Barre d'actions : Dupliquer, Poser sur une face (toucher une face incline l'objet pour qu'elle repose
      sur le plateau), Poser sur le plateau, Centrer, Orientation d'origine, Organiser, Supprimer.
- [ ] Annuler / Rétablir (⌘Z / ⇧⌘Z) défont un déplacement et une rotation (un geste sur plusieurs objets = un seul pas).
- [ ] Clavier : ⌥+flèches = 1 mm, ⌥⇧+flèches = 10 mm, ⌘D copie, ⇧⌘A organise, **⌘A sélectionne tout**, Échap désélectionne.
- [ ] ★ **Appui long** (ou clic droit avec une souris) sur un objet : menu contextuel — Dupliquer, Poser sur une
      face, Poser sur le plateau, Orientation d'origine, Couper…, Simplifier le maillage…, Réglages de l'objet…,
      Tout sélectionner, Organiser, Supprimer. L'objet touché devient la sélection (sauf s'il fait déjà partie d'un groupe).
- [ ] ★ **Sélection multiple** : bouton « Sélection multiple » de la barre d'actions (ou ⌘/⇧ + toucher avec un clavier) —
      chaque toucher ajoute / retire un objet ; la barre annonce « N objets sélectionnés » ; **glisser un objet du
      groupe déplace tout le groupe**, Dupliquer / Poser / Orientation / Supprimer s'appliquent à tous, les flèches
      aussi ; un seul « Annuler » ramène tout le groupe.

## 4. Inspecteur : manipulation d'objet

- [ ] Position X/Y/Z, rotation, échelle (%) et taille (mm) reflètent l'objet et **le déplacent** quand on les édite.
- [ ] « Proportions verrouillées » : changer la taille X change aussi Y et Z.
- [ ] « Copies » (+/−) ajoute/retire des instances décalées.
- [ ] Après une échelle ou une rotation, l'objet reste posé sur le plateau.

### 4 bis. Outils d'objet : coupe, simplification, réglages par objet

- [ ] ★ **Couper** (barre d'actions, inspecteur ou menu contextuel) : un plan translucide traverse l'objet ; choisir
      l'axe (Z horizontal, X ou Y vertical), faire glisser le curseur : le plan suit, la taille des deux moitiés
      s'affiche ; « Garder » (les deux / un côté) ; « Poser la face coupée à plat » ; « Couper » donne deux objets
      posés sur le plateau, sans chevauchement, tous deux sélectionnés ; « Annuler » ferme l'outil sans rien couper.
- [ ] **Simplifier le maillage** : un STL très dense (scan) perd des triangles (bandeau « N → M triangles »), la forme
      reste reconnaissable et se slice plus vite.
- [ ] ★ **Réglages de l'objet** : « Ajouter un réglage » (liste courte + recherche dans les ~150 options applicables
      à un objet) ; la valeur modifiée s'affiche avec le point orange et « Valeur du profil » la retire. Un petit
      point orange apparaît dans la liste des objets. Après slicing, l'objet concerné se comporte différemment
      (ex. remplissage 100 % = plus de filament que les autres).
- [ ] **Modificateurs** : boîte / cylindre / sphère ajoutés au centre de l'objet, visibles en bleu translucide ;
      position et taille modifiables ; leurs réglages ne s'appliquent que dans leur volume. « Bloqueur de supports »
      (rouge) et « Forceur de supports » (vert) fonctionnent de même.
- [ ] **Plages de hauteurs** : « Ajouter une plage », bornes Z modifiables, réglages propres (ex. couches plus fines) ;
      deux plages qui se chevauchent sont refusées avec un message.

## 5. Réglages

- [ ] « Paramètres fréquents » : Supports (4 choix), Remplissage (±5 %), Bordure — le résumé orange apparaît.
- [ ] « Plus de réglages rapides… » : adhérence, hauteur de couche (bornée par la buse), périmètres, température.
- [ ] ★ « Mes préréglages » → « Enregistrer sous… » : le préréglage retient **l'imprimante, le preset d'impression et le
      filament de départ** (« Basé sur … ») ; changer un réglage ou le preset affiche « modifié » avec « Mettre à jour » ;
      rappeler le préréglage rétablit les presets parents puis les réglages ; un second « Enregistrer sous » avec le même nom
      ajoute un numéro au lieu d'écraser.
- [ ] ★ « Tous les réglages… » : onglets Impression / Filament / Imprimante, pages, groupes ; niveau
      Simple/Avancé/Expert ; recherche (« remplissage », « infill ») ; l'aide (?) s'affiche ; un point orange
      signale une valeur modifiée et « Valeur du profil » la restaure.
- [ ] Une valeur invalide (texte dans un champ numérique) est refusée sans planter.
- [ ] « Mes préréglages » enregistre et rappelle un jeu de réglages ; « Préparer l'export .ini » produit un
      fichier partageable.
- [ ] Les réglages survivent à un redémarrage.
- [ ] Filament : « Filament » ouvre une liste groupée par matière (PLA, PETG, ABS…) avec recherche.

## 6. Slicing

- [ ] « Slicer » (⌘↩) : la progression avance (pas figée à 0 %), l'écran ne s'éteint pas.
- [ ] « Annuler » arrête vraiment ; l'app reste utilisable ; un nouveau slicing fonctionne ensuite.
- [ ] À la fin, l'app passe en mode **Aperçu**.
- [ ] Mettre l'app en arrière-plan pendant un slicing : il continue ou est suspendu **sans** planter au retour.
- [ ] Changer un réglage puis « Re-slicer » est nettement plus rapide que le premier slicing (Print conservé).

## 7. Aperçu G-code ★

- [ ] Les trajectoires apparaissent en rubans colorés (périmètres jaune/orange, remplissage rouge sombre…) ;
      **aucun trou** dans les parois (B1).
- [ ] La légende liste les types avec durée et pourcentage ; toucher un type le masque.
- [ ] Menu « Couleur » : vitesse, hauteur, largeur, ventilateur, température, débit — un dégradé s'affiche.
- [ ] « Déplacements à vide » affiche/masque les déplacements.
- [ ] Double curseur de couches (à droite) : la plage visible change ; le curseur « Mouvements » dessine le
      début de la couche du haut ; ▶ rejoue couche par couche.
- [ ] Durée estimée, filament (g, m) et nombre de couches sont plausibles (cube de 20 mm : ≈ 17 min, 100 couches).
- [ ] Modifier le plateau marque l'aperçu « obsolète ».
- [ ] « Partager / exporter le G-code » : le fichier part vers Fichiers ou une autre app ; ouvert dans
      QIDISlicer desktop, il montre la même chose.

## 8. Imprimante

- [ ] ★ `Réglages` → « Rechercher mon imprimante » : iOS demande l'autorisation « réseau local » ; la liste montre les
      imprimantes Moonraker du Wi-Fi (nom d'hôte, adresse, version) en quelques secondes ; en toucher une remplit
      l'adresse et teste la connexion. Si rien n'apparaît, le message explique quoi vérifier.
- [ ] `Réglages` : adresse Moonraker + port enregistrés ; « Tester la connexion » affiche l'état.
- [ ] La section « Imprimante » montre état, fichier, progression et températures (rafraîchis toutes les 5 s).
- [ ] « Envoyer et lancer l'impression » : barre de progression d'envoi, puis le job démarre.
- [ ] Sur l'écran de l'imprimante, **l'aperçu du fichier (vignette)** s'affiche (B8).

## 9. Calibration

- [ ] Menu « Calibration » → « Pressure Advance (tour) » : un bandeau « réglages temporaires » apparaît, une
      tour est posée ; le G-code contient `M900 K…` par marche de 5 mm.
- [ ] « Quitter » restaure les réglages d'origine et vide le plateau.
- [ ] « Débit — calibration grossière » charge le 3MF de 10 pièces, impression séquentielle (`M221`).
- [ ] ★ « Pressure Advance (ligne) » et « (motif) » : une base d'une couche est posée ; après slicing le G-code se
      termine par une série de lignes / chevrons avec un `M900 K…` par valeur ; le panneau « Lecture du résultat »
      liste les valeurs **dans l'ordre d'impression** (les étiquettes numériques du bureau ne sont pas reproduites).
      Imprimer et vérifier que les lignes sont bien dans cet ordre sur la plaque.
- [ ] ★ « Débit volumétrique maximal » : un mur d'un périmètre de 0,32 mm de haut par couche ; la vitesse du
      périmètre externe augmente à chaque couche ; le panneau donne la formule débit = début + pas × (hauteur / 0,32).

## 9 bis. Multi-filament et QIDI Box

- [ ] ★ Section « Multi-filament » de l'inspecteur : `Filaments` 1 → 16. Avec 3, trois lignes T1/T2/T3 (couleur,
      filament). Le choix survit à un changement d'imprimante et au redémarrage.
- [ ] Dans « Réglages de l'objet », le sélecteur « Filament » affecte l'objet à T1/T2/T3 ; après slicing, le
      G-code contient `T1`, le résumé compte des changements d'outil et le mode de couleur « Filament (outil) » de
      l'aperçu montre chaque pièce dans la couleur de son filament.
- [ ] ★ **Avec un vrai QIDI Box** : activer « Utiliser le QIDI Box », régler l'emplacement (1A…4D) de chaque
      outil, « Envoyer et lancer l'impression » : l'imprimante reçoit `SAVE_VARIABLE enable_box` et
      `value_t0…` (mêmes commandes que QIDISlicer desktop) puis démarre. **À vérifier absolument** : que T1 prend bien
      la bobine annoncée. Les numéros d'emplacement suivent l'ordre 1A, 1B, 1C, 1D, 2A… (0…15) du bureau ; cette
      correspondance n'a **pas** pu être confirmée sans matériel. « Lire l'association dans l'imprimante » relit les variables.

## 10. Ce qu'il ne faut pas attendre

- STEP/OCCT, connexion QIDI Cloud, TestFlight : non implémentés (voir `roadmap.md`).
- Lecture automatique de la couleur / matière des bobines du QIDI Box : le module réseau du bureau qui la fait est
  fermé et absent des sources ; ici les emplacements et les couleurs se règlent à la main.

## Retour utile

Pour chaque ✗ : l'écran concerné, ce que tu fais, ce qui se passe (ou pas), et si possible une capture. Une
capture d'écran suffit à localiser la plupart des problèmes de disposition.
