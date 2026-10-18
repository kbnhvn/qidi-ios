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
        "Licence": "License"
    ]
}
