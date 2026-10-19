//
//  SettingsCatalog.swift
//  Écran « tous les réglages » : fusionne le schéma des options (moteur,
//  qsid_config_schema), la disposition des onglets (extraite de Tab.cpp, voir
//  scripts/gen-config-ui.py) et les traductions françaises (QIDISlicer_fr.po).
//  Pur Foundation : testé sous Linux contre les ressources réelles.
//

import Foundation

enum ConfigMode: String, Decodable, CaseIterable, Identifiable, Comparable {
    case simple, advanced, expert
    var id: String { rawValue }
    private var rank: Int { self == .simple ? 0 : (self == .advanced ? 1 : 2) }
    static func < (a: ConfigMode, b: ConfigMode) -> Bool { a.rank < b.rank }

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .advanced: return "Avancé"
        case .expert: return "Expert"
        }
    }
}

/// Définition d'une option, telle que décrite par le moteur.
struct ConfigOption: Decodable, Identifiable, Equatable {
    let key: String
    let type: String
    let label: String
    let fullLabel: String
    let tooltip: String
    let category: String
    let sidetext: String
    let mode: ConfigMode
    let nullable: Bool
    let multiline: Bool
    let readonly: Bool
    let min: Double?
    let max: Double?
    let enumValues: [String]?
    let enumLabels: [String]?
    let `default`: String?

    var id: String { key }

    var isVector: Bool {
        ["floats", "ints", "strings", "percents", "floats_or_percents", "points", "enums", "bools"].contains(type)
    }
}

struct SettingsLayout: Decodable {
    struct Line: Decodable { let label: String; let keys: [String] }
    struct Group: Decodable { let title: String; let lines: [Line] }
    struct Page: Decodable, Identifiable {
        let title: String
        let groups: [Group]
        var id: String { title }
    }
    struct Tab: Decodable, Identifiable {
        let id: String
        let title: String
        let pages: [Page]
    }
    let tabs: [Tab]
}

final class SettingsCatalog {
    let options: [String: ConfigOption]
    let layout: SettingsLayout
    private let french: [String: String]
    /// Langue des libellés : vrai = français (traductions du bureau), faux = anglais d'origine.
    var useFrench: Bool

    init(schemaJSON: String, layoutJSON: Data, frenchJSON: Data?, useFrench: Bool = true) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode([ConfigOption].self, from: Data(schemaJSON.utf8))
        options = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        layout = try JSONDecoder().decode(SettingsLayout.self, from: layoutJSON)
        french = (try? frenchJSON.map { try JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        self.useFrench = useFrench
    }

    /// Traduit un texte du moteur ou de la GUI (clé = msgid anglais).
    func tr(_ text: String) -> String {
        guard useFrench, !text.isEmpty else { return text }
        return french[text] ?? text
    }

    func label(_ option: ConfigOption) -> String { tr(option.label) }
    func tooltip(_ option: ConfigOption) -> String { tr(option.tooltip) }

    /// Libellé d'une valeur d'énumération.
    func enumLabel(_ option: ConfigOption, value: String) -> String {
        guard let values = option.enumValues, let i = values.firstIndex(of: value) else { return value }
        let labels = option.enumLabels ?? values
        return tr(i < labels.count ? labels[i] : value)
    }

    /// Options d'une ligne (clés absentes du schéma ignorées).
    func options(of line: SettingsLayout.Line) -> [ConfigOption] { line.keys.compactMap { options[$0] } }

    /// Options visibles d'une page dans le mode donné.
    func visibleGroups(of page: SettingsLayout.Page, mode: ConfigMode) -> [(group: SettingsLayout.Group, lines: [SettingsLayout.Line])] {
        page.groups.compactMap { group in
            let lines = group.lines.filter { line in
                options(of: line).contains { $0.mode <= mode }
            }
            return lines.isEmpty ? nil : (group, lines)
        }
    }

    struct Hit: Identifiable, Equatable {
        let option: ConfigOption
        let tab: String
        let page: String
        let group: String
        var id: String { option.key }
    }

    /// Recherche plein texte (libellé, clé, aide) dans les options placées dans les onglets.
    func search(_ query: String, mode: ConfigMode, limit: Int = 60) -> [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [(score: Int, hit: Hit)] = []
        for tab in layout.tabs {
            for page in tab.pages {
                for group in page.groups {
                    for line in group.lines {
                        for option in options(of: line) where option.mode <= mode {
                            let label = self.label(option).lowercased()
                            let haystack = label + " " + option.key + " " + tooltip(option).lowercased()
                            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
                            var score = 0
                            if label.contains(words.joined(separator: " ")) { score += 10 }
                            if label.hasPrefix(words[0]) { score += 5 }
                            if option.mode == .simple { score += 2 }
                            hits.append((score, Hit(option: option, tab: tab.title, page: tr(page.title), group: tr(group.title))))
                        }
                    }
                }
            }
        }
        var seen = Set<String>()
        return hits.sorted { $0.score > $1.score }.map(\.hit).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
}

// MARK: - Édition des valeurs

/// Conversion entre le texte .ini d'une option et ce que manipule l'interface.
enum OptionValue {
    /// Éléments d'une valeur vectorielle (« 220,220 » → ["220","220"]).
    static func components(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Première composante (un seul extrudeur : c'est la valeur affichée).
    static func first(_ raw: String) -> String { components(raw).first ?? raw }

    /// Reconstruit une valeur vectorielle en remplaçant la première composante et en
    /// conservant la longueur de l'original (imprimante à un seul extrudeur : 1).
    static func replacingFirst(of raw: String, with value: String) -> String {
        let parts = components(raw)
        guard parts.count > 1 else { return value }
        return ([value] + parts.dropFirst().map { _ in value }).joined(separator: ",")
    }

    /// « 15% » → (15, true) ; « 0.2 » → (0.2, false).
    static func numberAndPercent(_ raw: String) -> (Double, Bool)? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let isPercent = t.hasSuffix("%")
        guard let n = Double(isPercent ? String(t.dropLast()) : t) else { return nil }
        return (n, isPercent)
    }

    static func format(_ number: Double, percent: Bool = false) -> String {
        let text = number == number.rounded() && abs(number) < 1e9 ? String(Int(number)) : String(format: "%g", number)
        return percent ? text + "%" : text
    }

    static func isTrue(_ raw: String) -> Bool { raw == "1" || raw.lowercased() == "true" }
}
