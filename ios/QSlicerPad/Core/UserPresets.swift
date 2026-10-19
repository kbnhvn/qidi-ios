//
//  UserPresets.swift
//  Préréglages de l'utilisateur : un jeu de réglages nommé qui *hérite* de presets système
//  (imprimante, impression, filament), comme un preset « utilisateur » de QIDISlicer desktop
//  qui dérive d'un preset système. L'appliquer rétablit les presets parents puis les réglages.
//  Pur Foundation : testé sous Linux.
//

import Foundation

struct UserPreset: Codable, Equatable, Identifiable {
    var name: String
    /// Presets système dont il hérite (vides = s'applique au-dessus de la sélection courante).
    var printer: String = ""
    var print: String = ""
    var filament: String = ""
    var overrides: SliceOverrides

    var id: String { name }
    var hasParents: Bool { !printer.isEmpty || !print.isEmpty || !filament.isEmpty }

    /// « 0.20mm Standard » (sans le suffixe « @imprimante »).
    var parentLabel: String? {
        guard hasParents else { return nil }
        let short = print.components(separatedBy: " @").first ?? print
        return short.isEmpty ? printer : short
    }
}

enum UserPresetStore {
    /// Relit les préréglages enregistrés. Tolère l'ancien format (`[nom: SliceOverrides]`, sans
    /// parents) pour ne pas perdre les préréglages d'une version précédente.
    static func decode(_ data: Data) -> [String: UserPreset] {
        let decoder = JSONDecoder()
        if let current = try? decoder.decode([String: UserPreset].self, from: data) { return current }
        if let legacy = try? decoder.decode([String: SliceOverrides].self, from: data) {
            return legacy.reduce(into: [:]) { $0[$1.key] = UserPreset(name: $1.key, overrides: $1.value) }
        }
        return [:]
    }

    static func encode(_ presets: [String: UserPreset]) -> Data? { try? JSONEncoder().encode(presets) }

    /// Nom libre : « Mon essai » → « Mon essai 2 » s'il existe déjà (enregistrer sous…).
    static func uniqueName(_ wanted: String, existing: Set<String>) -> String {
        let clean = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        guard existing.contains(clean) else { return clean }
        var n = 2
        while existing.contains("\(clean) \(n)") { n += 1 }
        return "\(clean) \(n)"
    }
}
