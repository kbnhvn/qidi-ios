//
//  SliceOverrides.swift
//  Réglages de l'utilisateur appliqués *par-dessus* le preset QIDI choisi.
//
//  Modèle : un dictionnaire « clé .ini → valeur forcée ». Une clé absente veut dire
//  « garder la valeur du preset » — il n'y a plus d'interrupteur global qui écrase
//  des valeurs que l'utilisateur n'a pas touchées. Les réglages rapides (supports,
//  bordure/radeau, remplissage…) ne sont que des vues typées sur ce dictionnaire ;
//  l'écran complet des options écrit dans le même.
//
//  Pur Foundation : testé sous Linux (ios/QSlicerKit).
//

import Foundation

struct SliceOverrides: Codable, Equatable {
    /// Valeurs forcées (clé de configuration → valeur au format .ini).
    private(set) var values: [String: String] = [:]
    /// Décalage ajouté à toutes les températures de buse du filament (°C).
    var nozzleDelta: Int = 0

    init() {}

    private enum CodingKeys: String, CodingKey { case values, nozzleDelta }

    /// Tolérant : un état enregistré par une ancienne version (ou illisible) donne
    /// simplement « aucun réglage forcé ».
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        nozzleDelta = try c.decodeIfPresent(Int.self, forKey: .nozzleDelta) ?? 0
    }

    var isEmpty: Bool { values.isEmpty && nozzleDelta == 0 }
    var modifiedKeys: [String] { values.keys.sorted() }

    // MARK: Accès générique

    /// Valeur effective : celle de l'utilisateur, sinon celle du preset.
    func value(_ key: String, base: [String: String]) -> String? {
        values[key] ?? base[key]
    }

    func isModified(_ key: String) -> Bool { values[key] != nil }

    /// Force `key`. Si la valeur égale celle du preset, le réglage n'est pas retenu
    /// (il n'y a alors rien à signaler comme « modifié »).
    mutating func set(_ key: String, _ value: String, base: [String: String]) {
        if let preset = base[key], Self.equivalent(preset, value) {
            values[key] = nil
        } else {
            values[key] = value
        }
    }

    mutating func reset(_ key: String) { values[key] = nil }
    mutating func resetAll() { values.removeAll(); nozzleDelta = 0 }

    /// « 15% » et « 15 % », « 0.20 » et « 0.2 » : mêmes valeurs.
    private static func equivalent(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func number(_ s: String) -> Double? {
            Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
        if a.hasSuffix("%") != b.hasSuffix("%") { return false }
        if let x = number(a), let y = number(b) { return abs(x - y) < 1e-9 }
        return false
    }

    // MARK: Fusion avec le preset

    /// Entrées .ini à ajouter à la configuration résolue du preset.
    func configEntries(basedOn base: [String: String]) -> [String: String] {
        var out = values
        if nozzleDelta != 0 {
            for key in ["temperature", "first_layer_temperature"] {
                guard let source = values[key] ?? base[key],
                      let shifted = Self.shift(source, by: nozzleDelta) else { continue }
                out[key] = shifted
            }
        }
        return out
    }

    /// Décale une température, éventuellement par extrudeur (« 220,225 »).
    static func shift(_ value: String, by delta: Int) -> String? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var shifted: [String] = []
        for part in parts {
            guard let number = Double(part) else { return nil }
            shifted.append(String(Int(number.rounded()) + delta))
        }
        return shifted.joined(separator: ",")
    }

    // MARK: Supports (mêmes quatre choix que le bureau)

    enum SupportMode: String, CaseIterable, Identifiable {
        case none, buildPlateOnly, enforcersOnly, everywhere
        var id: String { rawValue }
    }

    func supportMode(base: [String: String]) -> SupportMode {
        guard Self.bool(value("support_material", base: base)) else { return .none }
        if !Self.bool(value("support_material_auto", base: base)) { return .enforcersOnly }
        return Self.bool(value("support_material_buildplate_only", base: base)) ? .buildPlateOnly : .everywhere
    }

    mutating func setSupportMode(_ mode: SupportMode, base: [String: String]) {
        switch mode {
        case .none:
            set("support_material", "0", base: base)
        case .buildPlateOnly:
            set("support_material", "1", base: base)
            set("support_material_buildplate_only", "1", base: base)
            set("support_material_auto", "1", base: base)
        case .enforcersOnly:
            set("support_material", "1", base: base)
            set("support_material_buildplate_only", "0", base: base)
            set("support_material_auto", "0", base: base)
        case .everywhere:
            set("support_material", "1", base: base)
            set("support_material_buildplate_only", "0", base: base)
            set("support_material_auto", "1", base: base)
        }
    }

    // MARK: Adhérence

    enum Adhesion: String, CaseIterable, Identifiable {
        case none, brim, raft
        var id: String { rawValue }
    }

    func adhesion(base: [String: String]) -> Adhesion {
        if (Int(value("raft_layers", base: base) ?? "0") ?? 0) > 0 { return .raft }
        if (Double(value("brim_width", base: base) ?? "0") ?? 0) > 0 { return .brim }
        return .none
    }

    mutating func setAdhesion(_ kind: Adhesion, base: [String: String]) {
        switch kind {
        case .none:
            set("brim_width", "0", base: base)
            set("raft_layers", "0", base: base)
        case .brim:
            let current = Double(value("brim_width", base: base) ?? "0") ?? 0
            set("brim_width", current > 0 ? Self.format(current) : "5", base: base)
            set("raft_layers", "0", base: base)
        case .raft:
            let current = Int(value("raft_layers", base: base) ?? "0") ?? 0
            set("brim_width", "0", base: base)
            set("raft_layers", String(current > 0 ? current : 3), base: base)
        }
    }

    // MARK: Réglages numériques courants

    func infillPercent(base: [String: String]) -> Int {
        let raw = value("fill_density", base: base) ?? "0"
        return Int(Double(raw.replacingOccurrences(of: "%", with: "")) ?? 0)
    }
    mutating func setInfillPercent(_ percent: Int, base: [String: String]) {
        set("fill_density", "\(min(max(percent, 0), 100))%", base: base)
    }

    func layerHeight(base: [String: String]) -> Double {
        Double(value("layer_height", base: base) ?? "") ?? 0.2
    }
    mutating func setLayerHeight(_ height: Double, base: [String: String]) {
        set("layer_height", Self.format(height), base: base)
    }

    func perimeters(base: [String: String]) -> Int {
        Int(value("perimeters", base: base) ?? "") ?? 2
    }
    mutating func setPerimeters(_ count: Int, base: [String: String]) {
        set("perimeters", String(count), base: base)
    }

    // MARK: Limites physiques

    /// Diamètre de buse du preset (premier extrudeur).
    static func nozzleDiameter(base: [String: String]) -> Double {
        let raw = base["nozzle_diameter"] ?? "0.4"
        return Double(raw.split(separator: ",").first.map(String.init) ?? "") ?? 0.4
    }

    /// Hauteurs de couche proposées : au plus 75 % du diamètre de buse (au-delà le
    /// moteur refuse ou imprime mal), plus la valeur du preset si elle sort de la liste.
    static func layerHeightChoices(base: [String: String]) -> [Double] {
        let nozzle = nozzleDiameter(base: base)
        var choices = [0.05, 0.08, 0.1, 0.12, 0.15, 0.16, 0.2, 0.24, 0.28, 0.3, 0.36, 0.4, 0.45, 0.5, 0.6]
            .filter { $0 <= nozzle * 0.75 + 1e-9 }
        if let preset = Double(base["layer_height"] ?? ""), !choices.contains(where: { abs($0 - preset) < 1e-9 }) {
            choices.append(preset)
            choices.sort()
        }
        return choices
    }

    // MARK: Résumé lisible

    /// Phrase courte pour l'écran principal ; nil si rien n'est forcé.
    func summary(base: [String: String]) -> String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if isModified("support_material") || isModified("support_material_auto")
            || isModified("support_material_buildplate_only") {
            parts.append(supportMode(base: base) == .none ? "sans supports" : "supports")
        }
        if isModified("brim_width") || isModified("raft_layers") {
            switch adhesion(base: base) {
            case .none: parts.append("sans bordure")
            case .brim: parts.append("brim \(Self.format(Double(value("brim_width", base: base) ?? "0") ?? 0)) mm")
            case .raft: parts.append("raft \(value("raft_layers", base: base) ?? "") couches")
            }
        }
        if isModified("fill_density") { parts.append("remplissage \(infillPercent(base: base)) %") }
        if isModified("layer_height") { parts.append("couche \(Self.format(layerHeight(base: base))) mm") }
        if isModified("perimeters") { parts.append("\(perimeters(base: base)) périmètres") }
        if nozzleDelta != 0 { parts.append("buse \(nozzleDelta > 0 ? "+" : "")\(nozzleDelta) °C") }
        let others = values.keys.filter { !Self.quickKeys.contains($0) }.count
        if others > 0 { parts.append("\(others) autre\(others > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    private static let quickKeys: Set<String> = [
        "support_material", "support_material_auto", "support_material_buildplate_only",
        "brim_width", "raft_layers", "fill_density", "layer_height", "perimeters",
    ]

    // MARK: Aides

    private static func bool(_ raw: String?) -> Bool { raw == "1" }

    /// 0.2 → « 0.2 », 5.0 → « 5 » (format .ini sans zéros superflus).
    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%g", number)
    }
}
