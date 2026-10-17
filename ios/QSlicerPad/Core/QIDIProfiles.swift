//
//  QIDIProfiles.swift
//  Lecture du bundle de profils vendor embarqué (resources/profiles/QIDITechnology.ini).
//
//  On n'installe pas (encore) le bundle dans le conteneur : pour lister les
//  modèles d'imprimante, une lecture du fichier suffit. Une imprimante se choisit
//  ensuite par son profil exporté depuis QIDISlicer desktop — c'est ce profil qui
//  garantit un G-code identique au bureau.
//

import Foundation

struct QIDIProfileCatalog {
    /// Modèles d'imprimante du bundle vendor, dans l'ordre du fichier.
    let printerModels: [String]
    /// Nom du vendor (« QIDI Technology »).
    let vendorName: String?

    /// Charge le catalogue depuis le bundle de l'app.
    static func load(bundle: Bundle = .main) -> QIDIProfileCatalog {
        guard let url = bundle.url(forResource: "QIDITechnology", withExtension: "ini", subdirectory: "qidi/profiles"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return QIDIProfileCatalog(printerModels: [], vendorName: nil)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> QIDIProfileCatalog {
        var models: [String] = []
        var vendor: String?
        var inVendorSection = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inVendorSection = (line == "[vendor]")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if inVendorSection, key == "name", vendor == nil {
                vendor = value
            } else if key == "printer_model", !value.isEmpty, !models.contains(value) {
                // Les profils « *common* » laissent la valeur vide : ils sont ignorés.
                models.append(value)
            }
        }
        return QIDIProfileCatalog(printerModels: models, vendorName: vendor)
    }
}
