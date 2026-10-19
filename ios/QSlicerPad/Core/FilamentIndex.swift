//
//  FilamentIndex.swift
//  Recherche et regroupement des filaments : le bundle QIDI en contient 43
//  distincts par imprimante (« QIDI PLA Rapido », « Generic PETG »…), un menu plat
//  est pénible au doigt. Regroupés par matière, avec recherche.
//

import Foundation

/// « 0.20mm Standard @Q2 0.4 nozzle » → « 0.20mm Standard » (nom d'un preset sans la variante d'imprimante).
func presetDisplayName(_ name: String) -> String { name.components(separatedBy: " @").first ?? name }

struct FilamentEntry: Identifiable, Hashable {
    /// Nom complet du preset (« QIDI PLA Rapido @Q2 0.4 nozzle »).
    let id: String
    /// Nom sans suffixe d'imprimante.
    let display: String
    let vendor: String
    let material: String
}

enum FilamentIndex {
    /// Ordre d'affichage des familles ; le reste suit par ordre alphabétique.
    static let materialOrder = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PET", "PPS", "Support"]

    static func entries(_ presets: [String]) -> [FilamentEntry] {
        presets.map { name in
            let display = name.components(separatedBy: " @").first ?? name
            return FilamentEntry(id: name, display: display,
                                 vendor: display.split(separator: " ").first.map(String.init) ?? "",
                                 material: material(of: display))
        }
    }

    /// Famille de matière d'un nom de filament.
    static func material(of display: String) -> String {
        let name = display.uppercased()
        let tokens = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if name.contains("SUPPORT") { return "Support" }
        if name.contains("PC/ABS") { return "PC" }
        if name.contains("PETG") { return "PETG" }
        if tokens.contains("PET") { return "PET" }
        if name.contains("PLA") || name.contains("WOOD") { return "PLA" }
        if name.contains("ABS") { return "ABS" }
        if name.contains("ASA") { return "ASA" }
        if name.contains("TPU") { return "TPU" }
        if name.contains("PAHT") || name.contains("PA12") || name.contains("ULTRAPA") || tokens.contains("PA") { return "PA" }
        if tokens.contains("PC") { return "PC" }
        if name.contains("PPS") { return "PPS" }
        return "Autre"
    }

    /// Le moteur liste les filaments compatibles avec le *modèle* d'imprimante, toutes
    /// variantes de buse confondues (« … @Q2 0.2 nozzle », « … @Q2 0.4 nozzle »…) : on ne
    /// garde que ceux de l'imprimante choisie (repli : tous, si aucun ne porte ce suffixe).
    static func forPrinter(_ presets: [String], printer: String) -> [String] {
        guard !printer.isEmpty else { return presets }
        let same = presets.filter { $0.hasSuffix("@" + printer) }
        return same.isEmpty ? presets : same
    }

    /// Filament proposé à la première utilisation : un PLA QIDI, à défaut un PLA générique.
    static func preferredDefault(_ presets: [String]) -> String? {
        for prefix in ["QIDI PLA", "Generic PLA"] {
            if let match = presets.first(where: { $0.hasPrefix(prefix) }) { return match }
        }
        return presets.first
    }

    static func search(_ entries: [FilamentEntry], query: String) -> [FilamentEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        let words = q.lowercased().split(separator: " ").map(String.init)
        return entries.filter { entry in
            let haystack = (entry.display + " " + entry.material).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func grouped(_ entries: [FilamentEntry]) -> [(material: String, items: [FilamentEntry])] {
        let byMaterial = Dictionary(grouping: entries, by: \.material)
        func rank(_ m: String) -> Int { materialOrder.firstIndex(of: m) ?? materialOrder.count }
        return byMaterial.keys
            .sorted { (rank($0), $0) < (rank($1), $1) }
            .map { key in (key, byMaterial[key]!.sorted { $0.display < $1.display }) }
    }
}
