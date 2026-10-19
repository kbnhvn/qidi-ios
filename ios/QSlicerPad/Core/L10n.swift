//
//  L10n.swift
//  Localisation FR/EN sans dépendre du mécanisme .lproj : les textes français
//  restent lisibles dans le code et servent de clés ; un dictionnaire fournit
//  l'anglais. Choix assumé : déterministe et vérifiable, sans fichier de
//  ressources à faire reconnaître par Xcode.
//

import Foundation

enum L10n {
    /// "system" | "fr" | "en"
    static var language: String {
        get { UserDefaults.standard.string(forKey: "qsid.lang") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "qsid.lang") }
    }

    static var isEnglish: Bool {
        switch language {
        case "en": return true
        case "fr": return false
        default:
            let preferred = Locale.preferredLanguages.first ?? "fr"
            return !preferred.hasPrefix("fr")
        }
    }

    /// Traduit un texte français (clé) vers la langue active.
    static func t(_ fr: String) -> String {
        isEnglish ? (english[fr] ?? fr) : fr
    }

    private static let english: [String: String] = [
        // Général
        "QIDI Slice": "QIDI Slice",
        "Réglages": "Settings",
        "Terminé": "Done",
        "Annuler": "Cancel",
        "—": "—",

        // Moteur
        "Moteur": "Engine",
        "Cœur libslic3r de QIDISlicer, compilé pour arm64-iOS et exécuté dans le processus. Le slicing est local ; seule l'imprimante que vous configurez est contactée.":
            "QIDISlicer's libslic3r core, built for arm64-iOS and running in-process. Slicing is local; only the printer you configure is contacted.",

        // Profils
        "Profil d'impression": "Print profile",
        "Imprimante": "Printer",
        "Réglages d'impression": "Print settings",
        "Filament": "Filament",
        "Profil actif": "Active profile",
        "Importer un profil QIDISlicer (.ini)…": "Import a QIDISlicer profile (.ini)…",
        "Revenir aux profils embarqués": "Back to embedded profiles",
        "Les profils QIDI sont embarqués : choisissez imprimante, réglages et filament. Un .ini exporté de QIDISlicer desktop reste possible (il a alors priorité) — c'est le même moteur, donc le même G-code.":
            "QIDI profiles are embedded: pick printer, print settings and filament. A .ini exported from desktop QIDISlicer still works (it takes precedence) — same engine, same G-code.",

        // Modèle
        "Modèle": "Model",
        "Fichier": "File",
        "Voir en 3D": "View in 3D",
        "Importer un modèle…": "Import a model…",
        "Changer de modèle…": "Change model…",

        // Slicing
        "Slicer": "Slice",
        "Slicing…": "Slicing…",
        "Préparation…": "Preparing…",
        "Le slicing se fait sur l'iPad, dans le processus de l'app : progression et annulation comprises.":
            "Slicing runs on the iPad, inside the app process: progress and cancellation included.",

        // Résultat
        "Résultat": "Result",
        "Lignes": "Lines",
        "Couches": "Layers",
        "Taille": "Size",
        "Durée": "Duration",
        "Aperçu G-code": "G-code preview",
        "Partager / exporter le G-code": "Share / export G-code",
        "Couche": "Layer",

        // Imprimante
        "Adresse": "Address",
        "non configurée": "not configured",
        "Envoyer et lancer l'impression": "Send and start printing",
        "Actualiser l'état": "Refresh status",
        "Imprimante (Moonraker)": "Printer (Moonraker)",
        "Hôte": "Host",
        "Port": "Port",
        "Clé API (facultatif)": "API key (optional)",
        "Tester la connexion": "Test connection",
        "Aucune imprimante configurée (Réglages → Imprimante).": "No printer configured (Settings → Printer).",
        "Ex. 192.168.1.42 ou qidi.local": "e.g. 192.168.1.42 or qidi.local",
        "L'app contacte directement l'imprimante sur le réseau local (Moonraker). Rien ne transite par un serveur.":
            "The app talks directly to the printer on the local network (Moonraker). Nothing goes through a server.",

        // À propos
        "À propos": "About",
        "Langue": "Language",
        "Système": "System",
        "Français": "French",
        "English": "English",
        "QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet.":
            "QSlicerPad is an unofficial iPadOS port of QIDISlicer's engine, released under AGPL-3.0 — like QIDISlicer, from which it derives. The source code ships with the project archive.",
        "Version du moteur": "Engine version",
        "Licence": "License",
        "Réglages de slicing": "Slicing settings",
        "Options de slicing…": "Slicing options…",
        "Supports": "Supports",
        "Adhérence": "Bed adhesion",
        "Type": "Type",
        "Aucune": "None",
        "Bordure (brim)": "Brim",
        "Radeau (raft)": "Raft",
        "Largeur du brim": "Brim width",
        "Couches de raft": "Raft layers",
        "Remplissage": "Infill",
        "Densité": "Density",
        "Qualité": "Quality",
        "Hauteur de couche": "Layer height",
        "Périmètres": "Perimeters",
        "Température": "Temperature",
        "Buse": "Nozzle",
        "Le décalage s'ajoute à la température du filament du profil (utile pour un filament qui coule ou qui sous-extrude).":
            "The offset is added to the profile's filament temperature (handy for a filament that drools or under-extrudes).",
        "options perso": "custom options",
        "Aucun modèle": "No model",
        "Aucun profil embarqué": "No embedded profile",
        "Importez un STL, 3MF, OBJ ou AMF — ou déposez le fichier dans l'app.":
            "Import an STL, 3MF, OBJ or AMF — or drop the file onto the app.",
        "Importez un profil .ini exporté depuis QIDISlicer desktop.":
            "Import a .ini profile exported from desktop QIDISlicer.",
        "Vue": "View",
        "Dessus": "Top",
        "Face": "Front",
        "Isométrique": "Isometric",
        "Recadrer": "Frame",
        "Couche précédente": "Previous layer",
        "Couche suivante": "Next layer",

        // Réglages fréquents
        "Aucun preset résolu : les valeurs du profil ne sont pas affichées.":
            "No preset resolved: profile values are not shown.",
        "Aucun": "None",
        "Sur le plateau uniquement": "Support on build plate only",
        "Renforts uniquement": "For support enforcers only",
        "Partout": "Everywhere",
        "Modifié — revenir à la valeur du profil": "Modified — back to profile value",
        "Tout remettre aux valeurs du profil": "Reset everything to profile values",
        "Seuls les réglages que vous modifiez sont appliqués ; tout le reste vient du profil QIDI choisi.":
            "Only the settings you change are applied; everything else comes from the chosen QIDI profile.",
        "Un doigt : orbite · deux doigts : déplacer · pincement : zoom · double-tap : recadrer":
            "One finger: orbit · two fingers: pan · pinch: zoom · double-tap: frame",

        // Plateau, aperçu, réglages complets
        "Aide": "Help",
        "Aperçu": "Preview",
        "Aperçu obsolète : le plateau ou les réglages ont changé.": "Preview out of date: the plate or the settings changed.",
        "Aucun résultat : slicez le plateau.": "No result: slice the plate.",
        "Ce fichier semble composé de plusieurs pièces.": "This file seems to be made of several parts.",
        "Ce modèle semble être en mètres.": "This model looks like it was saved in meters.",
        "Ce modèle semble être en pouces.": "This model looks like it was saved in inches.",
        "Centrer": "Center",
        "Chargement des profils…": "Loading profiles…",
        "Chargement des réglages…": "Loading settings…",
        "Convertir (×1000)": "Convert (×1000)",
        "Convertir (×25,4)": "Convert (×25.4)",
        "Convertir les unités": "Convert units",
        "Copies": "Copies",
        "Couleur": "Color",
        "Coût": "Cost",
        "Des objets vides ont été ignorés.": "Empty objects were ignored.",
        "Dupliquer": "Duplicate",
        "Durée estimée": "Estimated time",
        "Déplacements à vide": "Travel moves",
        "Fermer": "Close",
        "Fichier très volumineux : les remplissages internes ne sont pas dessinés dans l'aperçu (le G-code est complet).": "Very large file: internal infill is not drawn in the preview (the G-code is complete).",
        "Le plateau ou les réglages ont changé : re-slicez pour mettre à jour.": "The plate or the settings changed: slice again to update.",
        "Les valeurs modifiées s'appliquent par-dessus le profil choisi ; le point orange les signale.": "Modified values apply on top of the chosen profile; the orange dot marks them.",
        "Légende": "Legend",
        "Millimètres → pouces (×1/25,4)": "Millimeters → inches (×1/25.4)",
        "Mode": "Mode",
        "Mode silencieux": "Silent mode",
        "Mètres → mm (×1000)": "Meters → mm (×1000)",
        "Niveau": "Level",
        "Objet": "Object",
        "Objets": "Objects",
        "Onglet": "Tab",
        "Organiser": "Arrange",
        "Orientation d'origine": "Original orientation",
        "Paramètres fréquents": "Frequently changed settings",
        "Plus de réglages rapides…": "More quick settings…",
        "Poser sur le plateau": "Drop to bed",
        "Poser sur une face": "Lay on face",
        "Position (mm)": "Position (mm)",
        "Pouces → mm (×25,4)": "Inches → mm (×25.4)",
        "Profil importé :": "Imported profile:",
        "Proportions verrouillées": "Lock proportions",
        "Préparer": "Prepare",
        "Re-slicer": "Slice again",
        "Rechercher un filament": "Search a filament",
        "Rechercher un réglage": "Search a setting",
        "Rotation (°)": "Rotation (°)",
        "Résultats": "Results",
        "Rétablir": "Redo",
        "Slicing annulé.": "Slicing canceled.",
        "Supprimer": "Delete",
        "Taille (mm)": "Size (mm)",
        "Touchez la face qui doit reposer sur le plateau.": "Tap the face that should rest on the bed.",
        "Tous les réglages": "All settings",
        "Tous les réglages…": "All settings…",
        "Tout réinitialiser": "Reset all",
        "Un objet sort du plateau.": "An object is outside the bed.",
        "Valeur du profil : ": "Profile value: ",
        "Vider le plateau": "Clear the plate",
        "non": "no",
        "oui": "yes",
        "Échelle (%)": "Scale (%)",
        "Simple": "Simple",
        "Avancé": "Advanced",
        "Expert": "Expert",
        "Vitesse": "Speed",
        "Largeur": "Width",
        "Ventilateur": "Fan",
        "Débit volumique": "Volumetric flow",
        "Périmètre": "Perimeter",
        "Périmètre externe": "External perimeter",
        "Périmètre en surplomb": "Overhang perimeter",
        "Remplissage interne": "Internal infill",
        "Remplissage plein": "Solid infill",
        "Remplissage plein supérieur": "Top solid infill",
        "Lissage": "Ironing",
        "Pont": "Bridge infill",
        "Comblement": "Gap fill",
        "Jupe / bordure": "Skirt / brim",
        "Interface de supports": "Support interface",
        "Tour d'essuyage": "Wipe tower",
        "G-code personnalisé": "Custom G-code"
    ]
}
