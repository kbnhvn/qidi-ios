//
//  QIDIProfiles.swift
//  Lecture du bundle de profils vendor embarqué (resources/profiles/QIDITechnology.ini)
//  et résolution des héritages (`inherits = ...`).
//
//  Pourquoi ici et pas dans le moteur : le bundle est un ensemble de sections
//  `[printer:…]`, `[print:…]`, `[filament:…]` qui s'héritent les unes des autres.
//  Résoudre la chaîne est un simple merge ; le faire côté Swift nous évite de
//  dépendre de PresetBundle (installation de bundle, AppConfig) et rend la
//  génération de configuration explicite et testable.
//

import Foundation

struct QIDIProfileCatalog {
    /// Sections du bundle, par clé complète (ex. "printer:Q2 0.4 nozzle").
    private let sections: [String: [String: String]]
    let vendorName: String?

    /// Initialiseur explicite : `sections` est privé, donc l'init memberwise
    /// implicite serait lui aussi privé (et inutilisable depuis les autres fichiers).
    init(sections: [String: [String: String]], vendorName: String?) {
        self.sections = sections
        self.vendorName = vendorName
    }

    // MARK: Chargement

    static func load(bundle: Bundle = .main) -> QIDIProfileCatalog {
        guard let url = bundle.url(forResource: "QIDITechnology", withExtension: "ini",
                                   subdirectory: "qidi/profiles"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return QIDIProfileCatalog(sections: [:], vendorName: nil)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> QIDIProfileCatalog {
        var sections: [String: [String: String]] = [:]
        var vendor: String?
        var current: String?
        var isVendorSection = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                isVendorSection = (header == "vendor")
                // On ne garde que printer/print/filament : le reste (presets,
                // printer_model, vendor) n'entre pas dans une configuration.
                if header.hasPrefix("printer:") || header.hasPrefix("print:") || header.hasPrefix("filament:") {
                    current = header
                    sections[header, default: [:]] = [:]
                } else if header.hasPrefix("printer_model:") || header.hasPrefix("printer_variant:") {
                    current = header   // utile plus tard (modèles/variantes) ; pas une config
                    sections[header, default: [:]] = [:]
                } else {
                    current = nil
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if isVendorSection, key == "name", vendor == nil {
                vendor = value
                continue
            }
            if let current {
                sections[current, default: [:]][key] = value
            }
        }
        return QIDIProfileCatalog(sections: sections, vendorName: vendor)
    }

    // MARK: Listes proposées à l'utilisateur

    /// Imprimantes concrètes (les sections `*common*` sont abstraites).
    var printers: [String] { names(kind: "printer") }
    var printPresets: [String] { names(kind: "print") }
    var filamentPresets: [String] { names(kind: "filament") }

    private func names(kind: String) -> [String] {
        sections.keys
            .filter { $0.hasPrefix(kind + ":") }
            .map { String($0.dropFirst(kind.count + 1)) }
            .filter { !$0.hasPrefix("*") }
            .sorted()
    }

    /// Modèles d'imprimante (« Q2 », « X-Plus 4 »…) déduits des presets.
    var printerModels: [String] {
        var models: [String] = []
        for (key, values) in sections where key.hasPrefix("printer:") {
            guard !key.contains("*") else { continue }
            if let model = values["printer_model"], !model.isEmpty, !models.contains(model) {
                models.append(model)
            }
        }
        return models.sorted()
    }

    /// Presets d'impression qui « vont avec » une imprimante, sinon tous.
    ///
    /// Dans le bundle QIDI, les presets concrets sont suffixés par la variante
    /// d'imprimante : `0.08mm Extra High @Q2 0.2 nozzle`. On filtre donc sur ce
    /// suffixe, puis on complète avec les noms qui mentionnent le modèle.
    func printPresets(for printer: String) -> [String] {
        presets(printPresets, for: printer)
    }

    /// Filaments qui « vont avec » une imprimante, sinon tous.
    func filamentPresets(for printer: String) -> [String] {
        presets(filamentPresets, for: printer)
    }

    private func presets(_ all: [String], for printer: String) -> [String] {
        guard !printer.isEmpty else { return all }
        let suffix = "@" + printer
        let exact = all.filter { $0.hasSuffix(suffix) }
        if !exact.isEmpty {
            return exact + all.filter { !exact.contains($0) && $0.localizedCaseInsensitiveContains(printer) }
        }
        if let model = sections["printer:" + printer]?["printer_model"], !model.isEmpty {
            let byModel = all.filter { $0.localizedCaseInsensitiveContains("@") && $0.localizedCaseInsensitiveContains(model) }
            if !byModel.isEmpty { return byModel + all.filter { !byModel.contains($0) } }
        }
        return all
    }

    // MARK: Résolution des héritages

    /// Fusionne la chaîne d'héritage d'une section, parents d'abord.
    /// Renvoie nil si la section n'existe pas.
    func resolved(_ fullKey: String) -> [String: String]? {
        var merged: [String: String] = [:]
        var visited = Set<String>()

        func merge(_ key: String, depth: Int) {
            guard depth < 32, !visited.contains(key) else { return }   // garde-fou anti-cycle
            visited.insert(key)
            guard let values = sections[key] else { return }
            for parent in parents(of: values["inherits"]) {
                // Un parent peut être relatif (`*common*`) ou absolu (`printer:...`).
                let parentKeys = parentKeys(for: parent, like: key)
                for pk in parentKeys { merge(pk, depth: depth + 1) }
            }
            for (k, v) in values where k != "inherits" {
                merged[k] = v
            }
        }

        merge(fullKey, depth: 0)
        return merged.isEmpty ? nil : merged
    }

    private func parents(of inherits: String?) -> [String] {
        guard let inherits, !inherits.isEmpty else { return [] }
        // Le bundle utilise « ; » pour l'héritage multiple (`*Q2*; *0.08mm Extra High*`)
        // et, plus rarement, la virgule : on accepte les deux.
        return inherits
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func parentKeys(for parent: String, like childKey: String) -> [String] {
        if parent.contains(":") { return [parent] }                    // déjà qualifié
        let kind = childKey.split(separator: ":").first.map(String.init) ?? "printer"
        return [kind + ":" + parent]
    }

    /// Configuration complète (printer + print + filament) prête pour le moteur.
    func resolvedConfig(printer: String, print: String, filament: String?) -> [String: String] {
        var config: [String: String] = [:]
        for key in ["printer:" + printer, "print:" + print] + (filament.map { ["filament:" + $0] } ?? []) {
            if let values = resolved(key) {
                config.merge(values) { _, new in new }   // le plus spécifique gagne
            }
        }
        // QIDISlicer attend un profil FFF ; ce flag n'est pas dans les bundles.
        config["printer_technology"] = config["printer_technology"] ?? "FFF"
        return config
    }

    /// Lit un .ini plat (export de QIDISlicer desktop : `clé = valeur`, `#` commentaires).
    static func iniDictionary(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Sérialise une configuration en .ini (clés triées : sortie déterministe).
    static func iniText(_ config: [String: String]) -> String {
        config.keys.sorted().map { "\($0) = \(config[$0]!)" }.joined(separator: "\n") + "\n"
    }

    /// Écrit la configuration résolue dans un fichier .ini temporaire.
    /// `overrides` (réglages utilisateur) a la priorité sur le preset.
    func writeConfig(printer: String, print: String, filament: String?,
                     overrides: SliceOverrides = SliceOverrides(), to url: URL) throws {
        var config = resolvedConfig(printer: printer, print: print, filament: filament)
        for (key, value) in overrides.configEntries(basedOn: config) {
            config[key] = value
        }
        guard !config.isEmpty else {
            throw NSError(domain: "QSlicerPad", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Profil introuvable dans le bundle embarqué."
            ])
        }
        try Self.iniText(config).write(to: url, atomically: true, encoding: .utf8)
    }
}
